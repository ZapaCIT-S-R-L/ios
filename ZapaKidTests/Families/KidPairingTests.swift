import Foundation
import Testing
@testable import ZapaKidKit

/// The kid's phone: scan the parent's QR, redeem it, keep the kid session; the app opens in kid mode next time.
@MainActor
struct KidPairingTests {
    let api = FakeFamiliesAPI()
    let code = "zkp_" + String(repeating: "P", count: 43)

    func auth(kidStore: KidSessionStore) -> AuthModel {
        AuthModel(
            api: NoAuthAPI(), store: InMemorySessionStore(),
            agreement: InMemoryAgreementStore(acceptedVersion: ParentalAgreement.currentVersion), kidStore: kidStore
        )
    }

    @Test func redeemingAScannedCodeSignsTheKidIn() async throws {
        let store = InMemoryKidSessionStore()
        let auth = auth(kidStore: store)
        let pairing = KidPairingModel(api: api, auth: auth)

        await pairing.redeem(scanned: "zapakid://pair?code=\(code)&fp=\(String(repeating: "cd", count: 32))")

        guard case let .kid(session) = auth.state else { Issue.record("not in kid mode: \(auth.state)"); return }
        #expect(session.kid.nickname == "Ana")
        #expect(try store.load()?.token == "zkk_t")
        #expect(try store.load()?.parentFingerprint == String(repeating: "cd", count: 32))
    }

    @Test func aKidSessionOpensInKidModeAtLaunch() async throws {
        let store = InMemoryKidSessionStore()
        try store.save(KidSession(
            token: "zkk_t", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
            familyId: "f1", familyName: nil
        ))
        let auth = auth(kidStore: store)

        await auth.start()

        #expect(auth.state.isKid)
    }

    @Test func aWrongQRSaysSoWithoutCallingTheAPI() async {
        let pairing = KidPairingModel(api: api, auth: auth(kidStore: InMemoryKidSessionStore()))

        await pairing.redeem(scanned: "https://example.invalid")

        #expect(pairing.errorMessage != nil)
        #expect(api.calls.isEmpty)
    }

    @Test func anExpiredCodeAsksForANewQR() async {
        api.failure = .codeInvalid
        let pairing = KidPairingModel(api: api, auth: auth(kidStore: InMemoryKidSessionStore()))

        await pairing.redeem(scanned: code)

        #expect(pairing.errorMessage != nil)
        #expect(api.calls == ["redeem"])
    }
}

struct NoAuthAPI: AuthAPI {
    func signInNonce() async throws -> SignInNonceGrant {
        throw AuthAPIError.network
    }

    func signIn(_: SignInRequest) async throws -> Session {
        throw AuthAPIError.network
    }

    func me(token _: String) async throws -> ParentProfile {
        throw AuthAPIError.network
    }

    func logout(token _: String) async throws {}
}
