import Foundation
import Testing
@testable import ZapaKidKit

/// A fake API that records the calls and answers what the test says.
actor FakeAuthAPI: AuthAPI {
    var signInResult: Result<Session, AuthAPIError> = .failure(.network)
    var meResult: Result<ParentProfile, AuthAPIError> = .failure(.network)
    var logoutError: AuthAPIError?
    private(set) var signInCalls: [SignInRequest] = []
    private(set) var meCalls: [String] = []
    private(set) var logoutCalls: [String] = []

    func set(signIn: Result<Session, AuthAPIError>) { signInResult = signIn }
    func set(me: Result<ParentProfile, AuthAPIError>) { meResult = me }
    func set(logoutError: AuthAPIError?) { self.logoutError = logoutError }

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
        if let logoutError { throw logoutError }
    }
}

@MainActor
struct AuthModelTests {
    let parent = ParentProfile(id: "p_1", name: "TEST Parent", email: nil)
    var session: Session { Session(token: "tok_1", parent: parent) }
    let adult = AgeRange(lower: 18, upper: nil, declined: false)
    let api = FakeAuthAPI()
    let store = InMemorySessionStore()
    let agreement = InMemoryAgreementStore()

    func model() -> AuthModel { AuthModel(api: api, store: store, agreement: agreement) }

    func acceptedModel() -> AuthModel {
        agreement.accept(version: ParentalAgreement.currentVersion)
        return model()
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
        let auth = acceptedModel()
        await auth.start()
        #expect(auth.state == .signedOut)
    }

    // MARK: Sign in

    @Test func signInStoresTheSessionAndShowsTheParent() async throws {
        await api.set(signIn: .success(session))
        let auth = acceptedModel()
        await auth.start()

        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)

        #expect(auth.state == .signedIn(parent))
        #expect(try store.load() == session)
        let calls = await api.signInCalls
        #expect(calls == [SignInRequest(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)])
    }

    @Test func knownMinorIsBlockedWithoutContactingTheAPI() async throws {
        await api.set(signIn: .success(session))
        let auth = acceptedModel()
        await auth.start()

        await auth.signIn(
            provider: .google, idToken: "id", nonce: "n",
            ageRange: AgeRange(lower: 13, upper: 17, declined: false)
        )

        #expect(auth.state == .blockedMinor)
        #expect(await api.signInCalls.isEmpty, "a minor's sign-in token is never sent")
        #expect(try store.load() == nil)
    }

    @Test func minorRejectedByTheAPIIsBlocked() async throws {
        await api.set(signIn: .failure(.minor))
        let auth = acceptedModel()
        await auth.start()

        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: nil)

        #expect(auth.state == .blockedMinor)
        #expect(try store.load() == nil)
    }

    @Test func failedSignInStaysSignedOutWithAMessage() async throws {
        await api.set(signIn: .failure(.network))
        let auth = acceptedModel()
        await auth.start()

        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
        #expect(try store.load() == nil)
    }

    @Test func errorMessageClearsOnTheNextSignIn() async {
        await api.set(signIn: .failure(.network))
        let auth = acceptedModel()
        await auth.start()
        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)
        await api.set(signIn: .success(session))

        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)

        #expect(auth.errorMessage == nil)
    }

    @Test func sessionThatCantBeSavedIsNotSignedIn() async {
        await api.set(signIn: .success(session))
        store.failSaves = true
        let auth = acceptedModel()
        await auth.start()

        await auth.signIn(provider: .apple, idToken: "id", nonce: "n", ageRange: adult)

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage != nil)
    }

    // MARK: Next launch

    @Test func storedSessionIsCheckedWithTheAPI() async throws {
        try store.save(session)
        let renamed = ParentProfile(id: "p_1", name: "TEST Renamed", email: nil)
        await api.set(me: .success(renamed))
        let auth = acceptedModel()

        await auth.start()

        #expect(auth.state == .signedIn(renamed))
        #expect(await api.meCalls == ["tok_1"])
        #expect(try store.load()?.parent == renamed)
    }

    @Test func expiredSessionIsClearedAtLaunch() async throws {
        try store.save(session)
        await api.set(me: .failure(.unauthorized))
        let auth = acceptedModel()

        await auth.start()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test func offlineLaunchKeepsTheStoredSession() async throws {
        try store.save(session)
        await api.set(me: .failure(.network))
        let auth = acceptedModel()

        await auth.start()

        #expect(auth.state == .signedIn(parent))
        #expect(try store.load() == session)
    }

    // MARK: Logout

    @Test func logoutClearsTheSessionAndTellsTheAPI() async throws {
        try store.save(session)
        await api.set(me: .success(parent))
        let auth = acceptedModel()
        await auth.start()

        await auth.logout()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
        #expect(await api.logoutCalls == ["tok_1"])
    }

    @Test func logoutClearsTheSessionEvenWhenTheAPIFails() async throws {
        try store.save(session)
        await api.set(me: .success(parent))
        await api.set(logoutError: .network)
        let auth = acceptedModel()
        await auth.start()

        await auth.logout()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
    }
}

struct AgeRangeTests {
    @Test(arguments: [
        (AgeRange(lower: 18, upper: nil, declined: false), false),
        (AgeRange(lower: nil, upper: 17, declined: false), true),
        (AgeRange(lower: 13, upper: 15, declined: false), true),
        (AgeRange(lower: nil, upper: nil, declined: true), false),
        (AgeRange(lower: 18, upper: 18, declined: false), false),
    ])
    func minorOnlyWhenTheUpperBoundIsUnder18(range: AgeRange, minor: Bool) {
        #expect(range.isMinor == minor)
    }
}

struct SignInNonceTests {
    @Test func noncesAreRandomAndHashedForTheProvider() {
        let first = SignInNonce()
        let second = SignInNonce()
        #expect(first.raw != second.raw)
        #expect(first.raw.count >= 43, "at least 32 random bytes, base64url")
        #expect(first.hashed.count == 64, "SHA-256 as lowercase hex")
        #expect(first.hashed == first.hashed.lowercased())
        #expect(first.hashed != first.raw)
    }

    @Test func hashIsSHA256OfTheRawNonce() {
        #expect(SignInNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
