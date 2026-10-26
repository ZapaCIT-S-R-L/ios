import Foundation
import Testing
@testable import ZapaKidKit

/// A fake API that records the calls and answers what the test says.
actor FakeAuthAPI: AuthAPI {
    var nonceResult: Result<SignInNonceGrant, AuthAPIError> = .success(
        SignInNonceGrant(nonce: "nonce-1", expiresAt: Date().addingTimeInterval(600))
    )
    var signInResult: Result<Session, AuthAPIError> = .failure(.network)
    var meResult: Result<ParentProfile, AuthAPIError> = .failure(.network)
    var logoutError: AuthAPIError?
    private(set) var nonceCalls = 0
    private(set) var signInCalls: [SignInRequest] = []
    private(set) var meCalls: [String] = []
    private(set) var logoutCalls: [String] = []

    func set(nonce: Result<SignInNonceGrant, AuthAPIError>) {
        nonceResult = nonce
    }

    func set(signIn: Result<Session, AuthAPIError>) {
        signInResult = signIn
    }

    func set(me: Result<ParentProfile, AuthAPIError>) {
        meResult = me
    }

    func set(logoutError: AuthAPIError?) {
        self.logoutError = logoutError
    }

    func signInNonce() async throws -> SignInNonceGrant {
        nonceCalls += 1
        return try nonceResult.get()
    }

    func signIn(_ request: SignInRequest) async throws -> Session {
        signInCalls.append(request)
        return try signInResult.get()
    }

    func me(token: String) async throws -> ParentProfile {
        meCalls.append(token)
        return try meResult.get()
    }

    func logout(token: String) async throws {
        logoutCalls.append(token)
        if let logoutError {
            throw logoutError
        }
    }
}

@MainActor
struct AuthModelTests {
    let parent = ParentProfile(id: "p_1", email: nil, displayName: "TEST Parent")
    var session: Session {
        Session(token: "zks_1", expiresAt: Date().addingTimeInterval(86400), parent: parent)
    }

    let adult = AgeRange.shared(lower: 18, upper: nil, platformStatus: "sharing")
    let api = FakeAuthAPI()
    let store = InMemorySessionStore()
    let agreement = InMemoryAgreementStore()

    func model() -> AuthModel {
        AuthModel(api: api, store: store, agreement: agreement)
    }

    /// Agreement accepted, on the sign-in screen with a nonce from the API.
    func signInScreen() async -> AuthModel {
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()
        await auth.start()
        await auth.prepareNonce()
        return auth
    }

    func signIn(_ auth: AuthModel, age: AgeRange? = nil, provider: SignInProvider = .apple) async {
        await auth.signIn(provider: provider, idToken: "jwt", ageRange: age ?? adult, displayName: nil)
    }

    // MARK: First launch

    @Test func firstLaunchAsksForTheParentalAgreement() async {
        let auth = model()
        await auth.start()
        #expect(auth.state == .needsAgreement)
    }

    @Test func acceptingTheAgreementShowsSignIn() async {
        let auth = model()
        await auth.start()

        await auth.acceptAgreement()

        #expect(auth.state == .signedOut)
        #expect(agreement.acceptedVersion == ParentalAgreement.currentVersion)
    }

    @Test func agreementAcceptedBeforeSkipsIt() async {
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()
        await auth.start()
        #expect(auth.state == .signedOut)
    }

    // MARK: Nonce

    @Test func signInScreenGetsANonceFromTheAPI() async {
        let auth = await signInScreen()

        #expect(auth.nonce?.nonce == "nonce-1")
        #expect(auth.providerNonce == SignInNonce(raw: "nonce-1").hashed, "the provider gets SHA-256(nonce)")
        #expect(await api.nonceCalls == 1)
    }

    @Test func validNonceIsReused() async {
        let auth = await signInScreen()

        await auth.prepareNonce()

        #expect(await api.nonceCalls == 1)
    }

    @Test func nonceAboutToExpireIsReplaced() async {
        await api.set(nonce: .success(SignInNonceGrant(nonce: "old", expiresAt: Date().addingTimeInterval(30))))
        let auth = await signInScreen()
        await api.set(nonce: .success(SignInNonceGrant(nonce: "new", expiresAt: Date().addingTimeInterval(600))))

        await auth.prepareNonce()

        #expect(auth.nonce?.nonce == "new")
    }

    @Test func signInSendsTheRawNonceAndGetsANewOneAfterwards() async {
        await api.set(signIn: .failure(.network))
        let auth = await signInScreen()
        await api.set(nonce: .success(SignInNonceGrant(nonce: "nonce-2", expiresAt: Date().addingTimeInterval(600))))

        await signIn(auth)

        #expect(await api.signInCalls.first?.nonce == "nonce-1")
        #expect(auth.nonce?.nonce == "nonce-2", "each nonce works once")
    }

    @Test func signInWithoutANonceFetchesOneFirst() async {
        await api.set(signIn: .success(session))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()
        await auth.start()

        await signIn(auth, provider: .google)

        #expect(await api.signInCalls.first?.nonce == "nonce-1")
        #expect(auth.state == .signedIn(parent))
    }

    @Test func noNonceMeansNoSignIn() async {
        await api.set(nonce: .failure(.network))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(await api.signInCalls.isEmpty)
        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
    }

    @Test func invalidNonceAsksToTryAgain() async {
        await api.set(signIn: .failure(.invalidNonce))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
        #expect(await api.nonceCalls == 2, "a fresh nonce for the retry")
    }

    // MARK: Sign in

    @Test func signInStoresTheSessionAndShowsTheParent() async throws {
        await api.set(signIn: .success(session))
        let auth = await signInScreen()

        await auth.signIn(provider: .apple, idToken: "jwt", ageRange: adult, displayName: "TEST Parent")

        #expect(auth.state == .signedIn(parent))
        #expect(try store.load() == session)
        let calls = await api.signInCalls
        #expect(calls == [SignInRequest(
            provider: .apple, idToken: "jwt", nonce: "nonce-1", ageRange: adult, displayName: "TEST Parent"
        )])
    }

    @Test func unavailableAgeIsSentAndAllowed() async {
        await api.set(signIn: .success(session))
        let auth = await signInScreen()

        await signIn(auth, age: .unavailable)

        #expect(await api.signInCalls.first?.ageRange == .unavailable)
        #expect(auth.state == .signedIn(parent))
    }

    @Test func knownMinorIsBlockedWithoutContactingTheAPI() async throws {
        await api.set(signIn: .success(session))
        let auth = await signInScreen()

        await signIn(auth, age: .shared(lower: 13, upper: 17, platformStatus: "sharing"))

        #expect(auth.state == .blockedMinor)
        #expect(await api.signInCalls.isEmpty, "a minor's sign-in token is never sent")
        #expect(try store.load() == nil)
    }

    @Test func minorRejectedByTheAPIIsBlocked() async throws {
        await api.set(signIn: .failure(.minorNotAllowed))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .blockedMinor)
        #expect(try store.load() == nil)
    }

    @Test func declinedAgeShowsTheDeclinedScreenWithoutContactingTheAPI() async {
        let auth = await signInScreen()

        await signIn(auth, age: .declined(platformStatus: "declinedSharing"))

        #expect(auth.state == .ageDeclined)
        #expect(await api.signInCalls.isEmpty)
    }

    @Test func declinedAgeFromTheAPIShowsTheDeclinedScreen() async {
        await api.set(signIn: .failure(.ageDeclined))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .ageDeclined)
    }

    @Test func afterDecliningTheParentCanTryAgain() async {
        let auth = await signInScreen()
        await signIn(auth, age: .declined(platformStatus: nil))

        await auth.tryAgain()

        #expect(auth.state == .signedOut)
        #expect(auth.nonce != nil)
    }

    @Test func rateLimitSaysWhenToTryAgain() async {
        await api.set(signIn: .failure(.rateLimited(retryAfter: 30)))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage?.contains("30") == true)
    }

    @Test func failedSignInStaysSignedOutWithAMessage() async throws {
        await api.set(signIn: .failure(.network))
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
        #expect(try store.load() == nil)
    }

    @Test func errorMessageClearsOnTheNextSignIn() async {
        await api.set(signIn: .failure(.network))
        let auth = await signInScreen()
        await signIn(auth)
        await api.set(signIn: .success(session))

        await signIn(auth)

        #expect(auth.errorMessage == nil)
    }

    @Test func sessionThatCantBeSavedIsNotSignedIn() async {
        await api.set(signIn: .success(session))
        store.failSaves = true
        let auth = await signInScreen()

        await signIn(auth)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
    }

    // MARK: Next launch

    @Test func storedSessionIsCheckedWithTheAPI() async throws {
        try store.save(session)
        let renamed = ParentProfile(id: "p_1", email: nil, displayName: "TEST Renamed")
        await api.set(me: .success(renamed))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()

        await auth.start()

        #expect(auth.state == .signedIn(renamed))
        #expect(await api.meCalls == ["zks_1"])
        #expect(try store.load()?.parent == renamed)
    }

    @Test func expiredSessionIsClearedAtLaunch() async throws {
        try store.save(session)
        await api.set(me: .failure(.unauthorized))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()

        await auth.start()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test func sessionPastExpiresAtIsClearedWithoutAsking() async throws {
        try store.save(Session(token: "zks_old", expiresAt: Date().addingTimeInterval(-60), parent: parent))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()

        await auth.start()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
        #expect(await api.meCalls.isEmpty)
    }

    @Test func offlineLaunchKeepsTheStoredSession() async throws {
        try store.save(session)
        await api.set(me: .failure(.network))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()

        await auth.start()

        #expect(auth.state == .signedIn(parent))
        #expect(try store.load() == session)
    }

    // MARK: Logout

    @Test func logoutClearsTheSessionAndTellsTheAPI() async throws {
        try store.save(session)
        await api.set(me: .success(parent))
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()
        await auth.start()

        await auth.logout()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
        #expect(await api.logoutCalls == ["zks_1"])
    }

    @Test func logoutClearsTheSessionEvenWhenTheAPIFails() async throws {
        try store.save(session)
        await api.set(me: .success(parent))
        await api.set(logoutError: .network)
        agreement.accept(version: ParentalAgreement.currentVersion)
        let auth = model()
        await auth.start()

        await auth.logout()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
    }
}

struct AgeRangeTests {
    @Test(arguments: [
        (AgeRange.shared(lower: 18, upper: nil, platformStatus: nil), false),
        (AgeRange.shared(lower: nil, upper: 17, platformStatus: nil), true),
        (AgeRange.shared(lower: 13, upper: 15, platformStatus: nil), true),
        (AgeRange.shared(lower: 16, upper: nil, platformStatus: nil), true), // "16 and up" doesn't show 18+
        (AgeRange.shared(lower: 18, upper: 18, platformStatus: nil), false),
        (AgeRange.declined(platformStatus: nil), false),
        (AgeRange.unavailable, false),
    ])
    func notAnAdultOnlyWhenASharedRangeDoesNotShow18Plus(range: AgeRange, notAdult: Bool) {
        #expect(range.isMinor == notAdult)
    }
}

struct SignInNonceTests {
    @Test func hashIsLowercaseHexSHA256OfTheRawNonce() {
        #expect(SignInNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
