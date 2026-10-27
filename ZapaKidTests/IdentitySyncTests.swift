import Foundation
import LibSignalClient
import Security
import Testing
@testable import ZapaKid

/// Records requests to re-share the identity from another family phone.
final class RecordingReshare: IdentityReshare {
    private(set) var requests = 0

    func requestReshare() {
        requests += 1
    }
}

struct NoReshare: IdentityReshare {
    func requestReshare() {}
}

/// One identity per account: the identity key pair is the one iCloud Keychain item. It survives a reinstall; a phone
/// without it waits for a re-share and never makes a new identity for an account that has one.
@Suite(.serialized)
@MainActor
struct IdentitySyncTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
    let keychainService = "ro.zapakid.app.tests.identity.\(UUID().uuidString)"
    let accountId = "6f1c0e2a-0000-4000-8000-000000000001"

    func identityStore() -> LocalIdentityStore {
        LocalIdentityStore(
            accountId: accountId,
            keychain: .syncedIdentity(service: keychainService, accountId: accountId)
        )
    }

    func newAccountIdentity() throws -> LocalIdentity {
        guard case let .ready(identity) = try identityStore().resolve(accountHasIdentity: false, reshare: NoReshare())
        else { throw CancellationError() }
        return identity
    }

    func protocolStore() throws -> ZapaKidProtocolStore {
        try ZapaKidProtocolStore(identity: newAccountIdentity(), files: ProtectedFileStore(directory: directory))
    }

    func cleanUp() {
        try? KeychainData.syncedIdentity(service: keychainService, accountId: accountId).clear()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func identityIsTheOneSyncedItemReadableWhenUnlocked() throws {
        defer { cleanUp() }
        _ = try newAccountIdentity()

        let item = try #require(keychainAttributes(service: keychainService))
        #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == true, "iCloud Keychain")
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
    }

    @Test func identitySurvivesAReinstallWhenTheSyncedItemExists() throws {
        defer { cleanUp() }
        let original = try newAccountIdentity()
        try? FileManager.default.removeItem(at: directory) // a reinstall loses the app's files, not iCloud Keychain
        let reshare = RecordingReshare()

        let state = try identityStore().resolve(accountHasIdentity: true, reshare: reshare)

        guard case let .ready(restored) = state else {
            Issue.record("expected the synced identity, got \(state)")
            return
        }
        #expect(restored.keyPair.serialize() == original.keyPair.serialize())
        #expect(restored.registrationId == original.registrationId)
        #expect(reshare.requests == 0)
    }

    @Test func missingSyncedIdentityWaitsForAnotherFamilyPhone() throws {
        defer { cleanUp() }
        let reshare = RecordingReshare()

        let state = try identityStore().resolve(accountHasIdentity: true, reshare: reshare)

        #expect(
            state == .waitingForReshare,
            "never a new identity for an account that has one: peers would see a change"
        )
        #expect(reshare.requests == 1)
        #expect(try identityStore().load() == nil)
    }

    @Test func prekeysAndSessionsStayOnThisPhone() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        _ = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 1)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("prekey-") })
        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true, "files, not the synced Keychain item, and never in backups")
    }

    func keychainAttributes(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
