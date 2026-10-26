import Foundation
import LibSignalClient
import Security
import Testing
@testable import ZapaKid

/// Key setup, PR 1: this phone's libsignal keys and the stores libsignal uses, no network yet.
/// The private keys never leave the phone: the Keychain (this device only) and Data-Protection-Complete files.
@Suite(.serialized)
@MainActor
struct KeySetupTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
    let keychainService = "ro.zapakid.app.tests.identity.\(UUID().uuidString)"
    let context = NullContext()

    func files() throws -> ProtectedFileStore {
        try ProtectedFileStore(directory: directory)
    }

    func identityStore() -> LocalIdentityStore {
        LocalIdentityStore(keychain: KeychainData(service: keychainService, account: "identity"))
    }

    func protocolStore() throws -> ZapaKidProtocolStore {
        try ZapaKidProtocolStore(identity: identityStore().loadOrCreate(), files: files())
    }

    func cleanUp() {
        try? KeychainData(service: keychainService, account: "identity").clear()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Local identity

    @Test func identityIsCreatedOnceAndKept() throws {
        defer { cleanUp() }
        let first = try identityStore().loadOrCreate()

        let again = try identityStore().loadOrCreate()

        #expect(again.keyPair.publicKey.serialize() == first.keyPair.publicKey.serialize())
        #expect(again.registrationId == first.registrationId)
        #expect((1 ... 16380).contains(first.registrationId), "libsignal registration IDs are 14-bit, not 0")
    }

    @Test func identityIsInTheKeychainThisDeviceOnly() throws {
        defer { cleanUp() }
        _ = try identityStore().loadOrCreate()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let item = try #require(result as? [String: Any])
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
    }

    // MARK: Device keys

    @Test func deviceKeysAreSignedByTheIdentity() throws {
        defer { cleanUp() }
        let store = try protocolStore()

        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 5)

        let identity = try store.identityKeyPair(context: context)
        let signed = try PublicKey(#require(Data(base64Encoded: keys.signedPreKey.publicKey)))
        let signature = try #require(Data(base64Encoded: keys.signedPreKey.signature))
        #expect(try identity.publicKey.verifySignature(message: signed.serialize(), signature: signature))
        let kyber = try #require(Data(base64Encoded: keys.pqLastResortPreKey.publicKey))
        let kyberSignature = try #require(Data(base64Encoded: keys.pqLastResortPreKey.signature))
        #expect(try identity.publicKey.verifySignature(message: kyber, signature: kyberSignature))
        for pq in keys.pqPreKeys {
            let key = try #require(Data(base64Encoded: pq.publicKey))
            let sig = try #require(Data(base64Encoded: pq.signature))
            #expect(try identity.publicKey.verifySignature(message: key, signature: sig))
        }
    }

    @Test func deviceKeysMatchTheContract() throws {
        defer { cleanUp() }
        let store = try protocolStore()

        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 5)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(keys)) as? [String: Any])

        #expect(Set(json.keys) == [
            "registrationId", "identityKey", "signedPreKey", "pqLastResortPreKey", "preKeys", "pqPreKeys",
        ])
        #expect(json["registrationId"] as? try Int == Int(store.localRegistrationId(context: context)))
        #expect(json["identityKey"] as? try String == (store.identityKeyPair(context: context)).identityKey
            .serialize().base64EncodedString())
        #expect(keys.preKeys.count == 5)
        #expect(keys.pqPreKeys.count == 5)
        let ids = keys.preKeys.map(\.keyId) + [keys.signedPreKey.keyId]
        #expect(ids.allSatisfy { (0 ... 16_777_215).contains($0) }, "24-bit key IDs")
        #expect(Set(keys.preKeys.map(\.keyId)).count == 5, "one-time key IDs are unique")
    }

    @Test func onlyPublicKeysLeaveThePhone() throws {
        defer { cleanUp() }
        let store = try protocolStore()

        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 3)
        let payload = try JSONEncoder().encode(keys)

        let text = try #require(String(data: payload, encoding: .utf8))
        let identity = try store.identityKeyPair(context: context)
        #expect(!text.contains(identity.privateKey.serialize().base64EncodedString()))
        for preKey in keys.preKeys {
            let record = try store.loadPreKey(id: preKey.keyId, context: context)
            #expect(try !text.contains(record.privateKey().serialize().base64EncodedString()))
        }
    }

    @Test func storedPrivateKeysMatchThePublishedOnes() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 3)

        let reopened = try protocolStore()

        let signed = try reopened.loadSignedPreKey(id: keys.signedPreKey.keyId, context: context)
        #expect(try signed.publicKey().serialize().base64EncodedString() == keys.signedPreKey.publicKey)
        let kyber = try reopened.loadKyberPreKey(id: keys.pqLastResortPreKey.keyId, context: context)
        #expect(try kyber.publicKey().serialize().base64EncodedString() == keys.pqLastResortPreKey.publicKey)
        for preKey in keys.preKeys {
            let record = try reopened.loadPreKey(id: preKey.keyId, context: context)
            #expect(try record.publicKey().serialize().base64EncodedString() == preKey.publicKey)
        }
    }

    @Test func usedOneTimePreKeyIsGone() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 1)
        let id = try #require(keys.preKeys.first?.keyId)

        try store.removePreKey(id: id, context: context)

        #expect(throws: (any Error).self) { try store.loadPreKey(id: id, context: context) }
    }

    @Test func keyFilesUseCompleteDataProtection() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        _ = try DeviceKeyGenerator(store: store).generate(oneTimeCount: 1)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.isEmpty)
        for name in names {
            let attributes = try FileManager.default
                .attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete, "\(name)")
            let values = try directory.appendingPathComponent(name).resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(name) is not in iCloud or Finder backups")
        }
    }

    // MARK: Peer identities: never trusted silently

    @Test func firstContactIsTrustedAndKept() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)
        let key = IdentityKeyPair.generate().identityKey

        #expect(try store.isTrustedIdentity(key, for: peer, direction: .sending, context: context))
        #expect(try store.saveIdentity(key, for: peer, context: context) == .newOrUnchanged)
        #expect(try store.identity(for: peer, context: context) == key)
        #expect(try store.saveIdentity(key, for: peer, context: context) == .newOrUnchanged)
    }

    @Test func changedPeerKeyIsNotTrustedForSendingUntilAcknowledged() throws {
        defer { cleanUp() }
        let store = try protocolStore()
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)
        let old = IdentityKeyPair.generate().identityKey
        let new = IdentityKeyPair.generate().identityKey
        _ = try store.saveIdentity(old, for: peer, context: context)

        #expect(try !store.isTrustedIdentity(new, for: peer, direction: .sending, context: context))
        #expect(try store.saveIdentity(new, for: peer, context: context) == .replacedExisting)

        #expect(store.identityChangesToAcknowledge == [peer.name])
        #expect(
            try !store.isTrustedIdentity(new, for: peer, direction: .sending, context: context),
            "a changed key needs the parent's OK before anything is sent"
        )
        #expect(
            try store.isTrustedIdentity(new, for: peer, direction: .receiving, context: context),
            "messages can still arrive, so the app can show the warning"
        )

        try store.acknowledgeIdentityChange(for: peer.name)

        #expect(store.identityChangesToAcknowledge.isEmpty)
        #expect(try store.isTrustedIdentity(new, for: peer, direction: .sending, context: context))
    }

    @Test func unacknowledgedChangeSurvivesARestart() throws {
        defer { cleanUp() }
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)
        let store = try protocolStore()
        _ = try store.saveIdentity(IdentityKeyPair.generate().identityKey, for: peer, context: context)
        let new = IdentityKeyPair.generate().identityKey
        _ = try store.saveIdentity(new, for: peer, context: context)

        let reopened = try protocolStore()

        #expect(reopened.identityChangesToAcknowledge == [peer.name])
        #expect(try !reopened.isTrustedIdentity(new, for: peer, direction: .sending, context: context))
    }

    // MARK: End to end with libsignal

    @Test func twoPhonesExchangeAMessageThroughTheseStores() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        defer {
            cleanUp()
            try? FileManager.default.removeItem(at: other)
        }
        let alice = try protocolStore()
        let bob = try ZapaKidProtocolStore(
            identity: LocalIdentity(keyPair: IdentityKeyPair.generate(), registrationId: 42),
            files: ProtectedFileStore(directory: other)
        )
        let bobKeys = try DeviceKeyGenerator(store: bob).generate(oneTimeCount: 1)
        let aliceAddress = try ProtocolAddress(name: "alice", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob", deviceId: 1)
        let bundle = try PreKeyBundle(
            registrationId: bob.localRegistrationId(context: context),
            deviceId: 1,
            prekeyId: bobKeys.preKeys[0].keyId,
            prekey: PublicKey(#require(Data(base64Encoded: bobKeys.preKeys[0].publicKey))),
            signedPrekeyId: bobKeys.signedPreKey.keyId,
            signedPrekey: PublicKey(#require(Data(base64Encoded: bobKeys.signedPreKey.publicKey))),
            signedPrekeySignature: #require(Data(base64Encoded: bobKeys.signedPreKey.signature)),
            identity: bob.identityKeyPair(context: context).identityKey,
            kyberPrekeyId: bobKeys.pqLastResortPreKey.keyId,
            kyberPrekey: KEMPublicKey(#require(Data(base64Encoded: bobKeys.pqLastResortPreKey.publicKey))),
            kyberPrekeySignature: #require(Data(base64Encoded: bobKeys.pqLastResortPreKey.signature))
        )

        try processPreKeyBundle(
            bundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: context
        )
        let ciphertext = try signalEncrypt(
            message: Data("TEST hello".utf8), for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: context
        )
        let plaintext = try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: ciphertext.serialize()),
            from: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, preKeyStore: bob, signedPreKeyStore: bob,
            kyberPreKeyStore: bob, context: context
        )

        #expect(plaintext == Data("TEST hello".utf8))
        #expect(try alice.loadSession(for: bobAddress, context: context) != nil, "the session is stored")
        #expect(throws: (any Error).self, "the one-time prekey was used up") {
            try bob.loadPreKey(id: bobKeys.preKeys[0].keyId, context: context)
        }
    }
}
