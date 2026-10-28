import Foundation
import LibSignalClient
import Testing
@testable import ZapaKid
@testable import ZapaKidKit

/// A kid's phone sets up its keys with the kid session (`zkk_…`): its own identity on this phone only (no iCloud
/// copy), `POST /v1/devices`, and `PUT /v1/keys/identity` when the account already has another identity, but only
/// within 10 minutes of pairing (else: ask a parent to pair again). Mirrors android #52.
@Suite(.serialized)
@MainActor
struct KidKeySetupTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kid-\(UUID().uuidString)")
    let keychainService = "ro.zapakid.app.tests.kid.\(UUID().uuidString)"
    let kidId = "6f1c0e2a-0000-4000-8000-0000000000aa"

    func keys() throws -> AccountKeys {
        try AccountKeys(accountId: kidId, root: directory, keychainService: keychainService, synced: false)
    }

    func registration(_ api: FakeDeviceAPI) -> DeviceRegistration {
        DeviceRegistration(
            api: api,
            keyspace: { [directory, keychainService] accountId in
                try AccountKeys(accountId: accountId, root: directory, keychainService: keychainService, synced: false)
            },
            reshare: NoReshare(), oneTimeCount: 3
        )
    }

    func run(_ api: FakeDeviceAPI, pairedAgo seconds: TimeInterval = 30) async -> DeviceSetupResult {
        await registration(api).runKid(
            accountId: kidId, token: "zkk_TEST", pairedAt: Date().addingTimeInterval(-seconds)
        )
    }

    func cleanUp() {
        try? keys().wipe()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func aNewKidMakesItsOwnIdentityOnThisPhoneOnlyAndRegisters() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)

        let result = await run(api)

        #expect(result == .ready(deviceId: 3))
        let identity = try #require(try keys().identity.load())
        #expect(try keys().identity.keychain.synchronizable == false, "no iCloud copy for a kid")
        #expect(await api.uploads.first?.identityKey == identity.keyPair.identityKey.serialize().base64EncodedString())
        #expect(await api.identityChanges.isEmpty)
    }

    @Test func aReplacedKidPhoneTakesOverTheIdentityRightAfterPairing() async throws {
        defer { cleanUp() }
        let old = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
        let api = FakeDeviceAPI(identity: old)
        await api.set(changeResult: .success(1))

        let result = await run(api, pairedAgo: 60)

        #expect(result == .ready(deviceId: 1))
        let change = try #require(await api.identityChanges.first)
        let identity = try #require(try keys().identity.load())
        #expect(change.identityKey == identity.keyPair.identityKey.serialize().base64EncodedString())
        #expect(change.identityKey != old)
        #expect(await api.uploads.isEmpty, "PUT /v1/keys/identity registers this phone")
    }

    @Test func afterTenMinutesTheKidMustBePairedAgain() async throws {
        defer { cleanUp() }
        let old = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
        let api = FakeDeviceAPI(identity: old)

        let result = await run(api, pairedAgo: 11 * 60)

        #expect(result == .needsPairing)
        #expect(await api.identityChanges.isEmpty)
        #expect(await api.uploads.isEmpty)
    }

    @Test func aMismatchFromTheServerAlsoLeadsToTheIdentityChange() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil) // the directory looked empty, then another phone registered first
        await api.set(registerResult: .failure(.identityMismatch))
        await api.set(changeResult: .success(2))

        let result = await run(api)

        #expect(result == .ready(deviceId: 2))
        #expect(await api.identityChanges.count == 1)
    }

    @Test func theServerSayingThePairingIsTooOldMeansPairAgain() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: IdentityKeyPair.generate().identityKey.serialize().base64EncodedString())
        await api.set(changeResult: .failure(.reauthenticationRequired))

        #expect(await run(api) == .needsPairing)
    }

    @Test func anExpiredKidSessionSignsOut() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)
        await api.set(registerResult: .failure(.unauthorized))

        #expect(await run(api) == .signedOut)
    }

    @Test func wipingRemovesTheKidsKeysFromThisPhone() async throws {
        defer { cleanUp() }
        _ = await run(FakeDeviceAPI(identity: nil))
        #expect(try keys().identity.load() != nil)

        try keys().wipe()

        #expect(try keys().identity.load() == nil)
        #expect(try keys().files.read("device.json") == nil)
    }
}
