import Foundation
import Testing
@testable import ZapaKidKit

/// The family screen's model: the family is created on first open, kids are added, phones paired by QR.
@MainActor
struct FamilyModelTests {
    let api = FakeFamiliesAPI()

    func model() -> FamilyModel {
        FamilyModel(api: api, token: { "zks_t" }, fingerprint: { String(repeating: "ab", count: 32) })
    }

    @Test func openingTheFamilyCreatesItOnce() async {
        let family = model()

        await family.load()
        await family.load()

        #expect(family.family?.name == nil)
        #expect(api.calls == ["create", "create"], "POST /v1/families is idempotent: 201 then 200")
    }

    @Test func addingAKidShowsItInTheList() async {
        let family = model()
        await family.load()

        let added = await family.addKid(nickname: "  Ana  ", avatar: "robot-4", grade: 2)

        #expect(added)
        #expect(family.family?.kids.map(\.nickname) == ["Ana"])
        #expect(api.calls.last == "addKid Ana robot-4 2")
    }

    @Test func emptyNicknamesAreRefusedBeforeTheAPI() async {
        let family = model()
        await family.load()

        let added = await family.addKid(nickname: "   ", avatar: "robot-4", grade: nil)

        #expect(!added)
        #expect(api.calls == ["create"])
    }

    @Test func pairingAKidGivesAQRWithTheParentFingerprint() async throws {
        let family = model()
        await family.load()
        _ = await family.addKid(nickname: "Ana", avatar: "robot-4", grade: 2)
        let kid = try #require(family.family?.kids.first)

        let pairing = try #require(await family.pairing(for: kid))

        #expect(pairing.link.code == api.pairingCode)
        #expect(pairing.link.fingerprint == String(repeating: "ab", count: 32))
        #expect(pairing.link.url.absoluteString.hasPrefix("zapakid://pair?code=zkp_"))
    }

    @Test func invitingAParentGivesAShareableLink() async throws {
        let family = model()
        await family.load()

        let invite = try #require(await family.inviteParent())

        #expect(invite.url.absoluteString == "https://zapakid.ro/join#\(api.inviteCode)")
    }

    @Test func errorsBecomeFriendlyMessages() async {
        api.failure = .tooManyKids
        let family = model()
        await family.load()

        #expect(family.errorMessage != nil)
    }
}

final class FakeFamiliesAPI: FamiliesAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var kids: [Kid] = []
    var failure: FamiliesAPIError?
    let pairingCode = "zkp_" + String(repeating: "P", count: 43)
    let inviteCode = "zki_" + String(repeating: "I", count: 43)

    var calls: [String] {
        lock.withLock { log }
    }

    private func record(_ line: String) throws {
        lock.withLock { log.append(line) }
        if let failure {
            throw failure
        }
    }

    private var family: Family {
        Family(id: "f1", name: nil, parents: [FamilyParent(id: "p1", displayName: "Mama")], kids: lock.withLock { kids })
    }

    func createFamily(name _: String?, token _: String) async throws -> Family {
        try record("create")
        return family
    }

    func myFamily(token _: String) async throws -> Family? {
        try record("list")
        return family
    }

    func inviteParent(familyId _: String, token _: String) async throws -> CodeGrant {
        try record("invite")
        return CodeGrant(code: inviteCode, expiresAt: Date().addingTimeInterval(72 * 3600))
    }

    func join(code _: String, token _: String) async throws -> Family {
        try record("join")
        return family
    }

    func addKid(familyId _: String, nickname: String, avatar: String, grade: Int?, token _: String) async throws -> Kid {
        try record("addKid \(nickname) \(avatar) \(grade.map(String.init) ?? "nil")")
        let kid = Kid(id: "k\(calls.count)", nickname: nickname, avatar: avatar, grade: grade)
        lock.withLock { kids.append(kid) }
        return kid
    }

    func createPairing(familyId _: String, kidId: String, token _: String) async throws -> PairingGrant {
        try record("pair \(kidId)")
        let kid = lock.withLock { kids.first { $0.id == kidId } } ?? Kid(id: kidId, nickname: "", avatar: "robot-1")
        return PairingGrant(code: pairingCode, expiresAt: Date().addingTimeInterval(300), kid: kid)
    }

    func redeemPairing(code _: String) async throws -> KidSession {
        try record("redeem")
        return KidSession(
            token: "zkk_t", expiresAt: Date().addingTimeInterval(86400), kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
            familyId: "f1", familyName: nil
        )
    }
}
