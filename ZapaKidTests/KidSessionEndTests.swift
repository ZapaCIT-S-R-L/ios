import Foundation
import Testing
@testable import ZapaKidKit

/// A kid session the API refuses (401) ends kid mode: the session is gone and the phone goes back to pairing.
@MainActor
struct KidSessionEndTests {
    @Test func anEndedKidSessionGoesBackToPairing() async throws {
        let store = InMemoryKidSessionStore(session: KidSession(
            token: "zkk_t", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
            familyId: "f1", familyName: nil, pairedAt: Date()
        ))
        let auth = AuthModel(
            api: NoAuthAPI(), store: InMemorySessionStore(),
            agreement: InMemoryAgreementStore(acceptedVersion: ParentalAgreement.currentVersion), kidStore: store
        )
        await auth.start()
        #expect(auth.state.isKid)

        auth.kidSessionEnded()

        #expect(auth.state == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test func pairingRecordsWhenItHappened() async throws {
        let store = InMemoryKidSessionStore()
        let auth = AuthModel(
            api: NoAuthAPI(), store: InMemorySessionStore(),
            agreement: InMemoryAgreementStore(acceptedVersion: ParentalAgreement.currentVersion), kidStore: store
        )
        let before = Date()

        await KidPairingModel(api: FakeFamiliesAPI(), auth: auth).redeem(scanned: "zkp_" + String(
            repeating: "P",
            count: 43
        ))

        let pairedAt = try #require(try store.load()?.pairedAt)
        #expect(pairedAt >= before)
    }
}
