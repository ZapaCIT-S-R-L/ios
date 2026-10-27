import Foundation
import LibSignalClient
import Security
import Testing
@testable import ZapaKid
@testable import ZapaKidKit

/// Security review 2026-10-27, H1: everything this phone keeps for an account (identity, prekeys, sessions, device
/// ID) is keyed by the ZapaKid account ID. A shared phone never reuses another account's identity or device, and
/// signing out of one account exposes nothing to the next.
@Suite(.serialized)
@MainActor
struct AccountKeysTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
    let keychainService = "ro.zapakid.app.tests.identity.\(UUID().uuidString)"
    let alice = "6f1c0e2a-0000-4000-8000-00000000000a"
    let bob = "6f1c0e2a-0000-4000-8000-00000000000b"

    func session(_ accountId: String) -> Session {
        Session(
            token: "zks_TEST_\(accountId)", expiresAt: .distantFuture,
            parent: ParentProfile(id: accountId, email: nil, displayName: "TEST")
        )
    }

    func keys(_ accountId: String) throws -> AccountKeys {
        try AccountKeys(accountId: accountId, root: directory, keychainService: keychainService)
    }

    func registration(_ api: FakeDeviceAPI) -> DeviceRegistration {
        DeviceRegistration(
            api: api,
            keyspace: { [directory, keychainService] accountId in
                try AccountKeys(accountId: accountId, root: directory, keychainService: keychainService)
            },
            reshare: NoReshare(), oneTimeCount: 2
        )
    }

    func cleanUp() {
        for account in [alice, bob] {
            try? KeychainData.syncedIdentity(service: keychainService, accountId: account).clear()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func secondAccountOnTheSamePhoneGetsItsOwnIdentityAndDevice() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)
        #expect(await registration(api).run(session: session(alice)) == .ready(deviceId: 3))
        // Alice signs out; Bob signs in on the same phone. The directory knows no identity for Bob.
        await api.set(registerResult: .success(7))

        let result = await registration(api).run(session: session(bob))

        #expect(result == .ready(deviceId: 7), "Bob registers his own device, not Alice's cached one")
        let uploads = await api.uploads
        #expect(uploads.count == 2)
        #expect(uploads[0].identityKey != uploads[1].identityKey, "never Alice's identity for Bob")
        #expect(await api.lookups == [alice, bob])
        let aliceIdentity = try #require(try keys(alice).identity.load())
        #expect(uploads[0].identityKey == aliceIdentity.keyPair.identityKey.serialize().base64EncodedString())
    }

    @Test func sameAccountAgainReusesItsDevice() async {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)
        _ = await registration(api).run(session: session(alice))
        _ = await registration(api).run(session: session(bob))

        let again = await registration(api).run(session: session(alice))

        #expect(again == .ready(deviceId: 3))
        #expect(await api.uploads.count == 2, "Alice's device is still hers; no third upload")
    }

    @Test func eachAccountHasItsOwnKeychainItemAndDirectory() throws {
        defer { cleanUp() }
        let aliceKeys = try keys(alice)
        let bobKeys = try keys(bob)

        #expect(aliceKeys.files.directory != bobKeys.files.directory)
        #expect(aliceKeys.files.directory.deletingLastPathComponent() == directory)
        #expect(aliceKeys.identity.keychain.account != bobKeys.identity.keychain.account)
        #expect(aliceKeys.identity.keychain.synchronizable)
    }

    @Test func accountIDCanNeverEscapeTheKeyDirectory() throws {
        defer { cleanUp() }
        let sneaky = try keys("../../etc")

        #expect(sneaky.files.directory.deletingLastPathComponent() == directory)
        #expect(!sneaky.files.directory.lastPathComponent.contains("."))
    }

    @Test func identityCopiedFromAnotherAccountIsRefused() throws {
        defer { cleanUp() }
        guard case .ready = try keys(alice).identity.resolve(accountHasIdentity: false, reshare: NoReshare()) else {
            throw CancellationError()
        }
        // Someone copies Alice's stored identity into Bob's Keychain slot.
        let aliceItem = KeychainData.syncedIdentity(service: keychainService, accountId: alice)
        let data = try #require(try aliceItem.load())
        try KeychainData.syncedIdentity(service: keychainService, accountId: bob).save(data)

        #expect(throws: LocalIdentityStore.WrongAccount.self) { try keys(bob).identity.load() }
        #expect(throws: LocalIdentityStore.WrongAccount.self) {
            try keys(bob).identity.resolve(accountHasIdentity: false, reshare: NoReshare())
        }
    }

    @Test func identityRefusedForAnotherAccountStopsRegistration() async throws {
        defer { cleanUp() }
        _ = try keys(alice).identity.resolve(accountHasIdentity: false, reshare: NoReshare())
        let data = try #require(try KeychainData.syncedIdentity(service: keychainService, accountId: alice).load())
        try KeychainData.syncedIdentity(service: keychainService, accountId: bob).save(data)
        let api = FakeDeviceAPI(identity: nil)

        let result = await registration(api).run(session: session(bob))

        #expect(result == .failed(.server))
        #expect(await api.uploads.isEmpty)
    }
}
