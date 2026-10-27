import Foundation
import LibSignalClient
import Security
import Testing
@testable import ZapaKid

/// Security review 2026-10-27, M1: the peers this account already trusts are kept with the account (a synced
/// Keychain item next to the identity), so a reinstall or a new phone doesn't start trusting on first use again
/// and silently accept a swapped key.
@Suite(.serialized)
@MainActor
struct PeerTrustTests {
    let accountId = "6f1c0e2a-0000-4000-8000-00000000000a"
    let peersService = "ro.zapakid.app.tests.peers.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peers-\(UUID().uuidString)")
    let identity = LocalIdentity(keyPair: IdentityKeyPair.generate(), registrationId: 7)
    let context = NullContext()

    func peers(_ account: String? = nil) -> PeerTrustStore {
        let account = account ?? accountId
        return PeerTrustStore(accountId: account, keychain: .syncedPeers(service: peersService, accountId: account))
    }

    /// A fresh install: new, empty key files; the synced Keychain items are still there.
    func freshInstall() throws -> ZapaKidProtocolStore {
        try? FileManager.default.removeItem(at: directory)
        return try ZapaKidProtocolStore(
            identity: identity,
            files: ProtectedFileStore(directory: directory),
            peers: peers()
        )
    }

    func cleanUp() {
        try? KeychainData.syncedPeers(service: peersService, accountId: accountId).clear()
        try? KeychainData.syncedPeers(service: peersService, accountId: "other").clear()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func swappedKeyAfterAReinstallIsNotTrusted() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "kid", deviceId: 1)
        let real = IdentityKeyPair.generate().identityKey
        let swapped = IdentityKeyPair.generate().identityKey
        _ = try freshInstall().saveIdentity(real, for: peer, context: context)

        let reinstalled = try freshInstall()

        #expect(try reinstalled.isTrustedIdentity(real, for: peer, direction: .sending, context: context))
        #expect(
            try !reinstalled.isTrustedIdentity(swapped, for: peer, direction: .sending, context: context),
            "not first contact again: the server can't swap the key"
        )
        #expect(try reinstalled.saveIdentity(swapped, for: peer, context: context) == .replacedExisting)
        #expect(reinstalled.identityChangesToAcknowledge == ["kid"])
    }

    @Test func pendingKeyChangeSurvivesAReinstall() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "kid", deviceId: 1)
        let store = try freshInstall()
        _ = try store.saveIdentity(IdentityKeyPair.generate().identityKey, for: peer, context: context)
        let new = IdentityKeyPair.generate().identityKey
        _ = try store.saveIdentity(new, for: peer, context: context)

        let reinstalled = try freshInstall()

        #expect(reinstalled.identityChangesToAcknowledge == ["kid"])
        #expect(try !reinstalled.isTrustedIdentity(new, for: peer, direction: .sending, context: context))
    }

    @Test func peerTrustIsASyncedItemOfThisAccountOnly() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "kid", deviceId: 1)
        _ = try freshInstall().saveIdentity(IdentityKeyPair.generate().identityKey, for: peer, context: context)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: peersService,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrAccount as String] as? String == "peers.\(accountId)")
        #expect((items.first?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == true)
        #expect(items.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(try peers("other").load().isEmpty, "another account sees none of these")
    }

    @Test func peerListFromAnotherAccountIsRefused() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "kid", deviceId: 1)
        _ = try freshInstall().saveIdentity(IdentityKeyPair.generate().identityKey, for: peer, context: context)
        let data = try #require(try KeychainData.syncedPeers(service: peersService, accountId: accountId).load())
        try KeychainData.syncedPeers(service: peersService, accountId: "other").save(data)

        #expect(throws: PeerTrustStore.WrongAccount.self) { try peers("other").load() }
    }

    @Test func peersAreNotInTheLocalKeyFiles() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "kid", deviceId: 1)
        _ = try freshInstall().saveIdentity(IdentityKeyPair.generate().identityKey, for: peer, context: context)

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(!names.contains("identities.json"))
    }
}
