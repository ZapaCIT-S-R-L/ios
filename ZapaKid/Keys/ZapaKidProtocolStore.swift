import Foundation
import LibSignalClient

/// The stores libsignal reads and writes: this phone's identity (Keychain), peers' identity keys, prekeys, signed
/// prekeys, Kyber prekeys and sessions (Data-Protection-Complete files). libsignal does all the cryptography.
///
/// Peer identity keys are never trusted silently: when a peer's key changes, sending to that peer is refused until
/// the parent acknowledges the change (after comparing safety numbers); receiving still works so the app can show the
/// warning. libsignal's in-memory store accepts the new key at once; this one doesn't.
final class ZapaKidProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore,
    LibSignalClient.SessionStore
{
    private let identity: LocalIdentity
    private let files: ProtectedFileStore
    private var peers: [String: PeerIdentity]

    private struct PeerIdentity: Codable {
        var key: Data
        var needsAcknowledgement: Bool
    }

    private static let peersFile = "identities.json"

    init(identity: LocalIdentity, files: ProtectedFileStore) throws {
        self.identity = identity
        self.files = files
        peers = try files.read(Self.peersFile).map { try JSONDecoder().decode([String: PeerIdentity].self, from: $0) }
            ?? [:]
    }

    /// Peers (account IDs) whose identity key changed and who can't be sent to until the parent acknowledges it.
    var identityChangesToAcknowledge: [String] {
        peers.filter(\.value.needsAcknowledgement).map(\.key).sorted()
    }

    func acknowledgeIdentityChange(for peer: String) throws {
        peers[peer]?.needsAcknowledgement = false
        try savePeers()
    }

    // MARK: IdentityKeyStore

    func identityKeyPair(context _: StoreContext) throws -> IdentityKeyPair {
        identity.keyPair
    }

    func localRegistrationId(context _: StoreContext) throws -> UInt32 {
        identity.registrationId
    }

    func saveIdentity(
        _ key: IdentityKey,
        for address: ProtocolAddress,
        context _: StoreContext
    ) throws -> IdentityChange {
        let new = key.serialize()
        guard let known = peers[address.name] else {
            peers[address.name] = PeerIdentity(key: new, needsAcknowledgement: false)
            try savePeers()
            return .newOrUnchanged
        }
        if known.key == new {
            return .newOrUnchanged
        }
        peers[address.name] = PeerIdentity(key: new, needsAcknowledgement: true)
        try savePeers()
        return .replacedExisting
    }

    func isTrustedIdentity(
        _ key: IdentityKey, for address: ProtocolAddress, direction: Direction, context _: StoreContext
    ) throws -> Bool {
        guard let known = peers[address.name] else { return true } // first contact; verified later by safety numbers
        switch direction {
        case .receiving:
            return true
        case .sending:
            return known.key == key.serialize() && !known.needsAcknowledgement
        }
    }

    func identity(for address: ProtocolAddress, context _: StoreContext) throws -> IdentityKey? {
        try peers[address.name].map { try IdentityKey(bytes: $0.key) }
    }

    // MARK: Prekeys

    func loadPreKey(id: UInt32, context _: StoreContext) throws -> PreKeyRecord {
        try PreKeyRecord(bytes: record("prekey-\(id)"))
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context _: StoreContext) throws {
        try files.write(record.serialize(), to: "prekey-\(id)")
    }

    func removePreKey(id: UInt32, context _: StoreContext) throws {
        try files.delete("prekey-\(id)")
    }

    func loadSignedPreKey(id: UInt32, context _: StoreContext) throws -> SignedPreKeyRecord {
        try SignedPreKeyRecord(bytes: record("signed-prekey-\(id)"))
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context _: StoreContext) throws {
        try files.write(record.serialize(), to: "signed-prekey-\(id)")
    }

    func loadKyberPreKey(id: UInt32, context _: StoreContext) throws -> KyberPreKeyRecord {
        try KyberPreKeyRecord(bytes: record("kyber-prekey-\(id)"))
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context _: StoreContext) throws {
        try files.write(record.serialize(), to: "kyber-prekey-\(id)")
    }

    /// One-time Kyber prekeys are used once; the last-resort one stays (it is replaced when the signed prekeys rotate).
    func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId _: UInt32,
        baseKey _: PublicKey,
        context _: StoreContext
    ) throws {
        if try files.read("kyber-last-resort-\(id)") == nil {
            try files.delete("kyber-prekey-\(id)")
        }
    }

    /// Marks a stored Kyber prekey as the last-resort one, so using it doesn't delete it.
    func markKyberPreKeyLastResort(id: UInt32) throws {
        try files.write(Data(), to: "kyber-last-resort-\(id)")
    }

    // MARK: Sessions

    func loadSession(for address: ProtocolAddress, context _: StoreContext) throws -> SessionRecord? {
        try files.read(sessionFile(address)).map { try SessionRecord(bytes: $0) }
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let session = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound("no session for \(address)")
            }
            return session
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context _: StoreContext) throws {
        try files.write(record.serialize(), to: sessionFile(address))
    }

    // MARK: Files

    private func record(_ name: String) throws -> Data {
        guard let data = try files.read(name) else { throw SignalError.invalidKeyIdentifier("no record \(name)") }
        return data
    }

    /// Account IDs are UUIDs from the API; hex-encode anyway so a name can never be a path.
    private func sessionFile(_ address: ProtocolAddress) -> String {
        "session-\(Data(address.name.utf8).map { String(format: "%02x", $0) }.joined())-\(address.deviceId)"
    }

    private func savePeers() throws {
        try files.write(JSONEncoder().encode(peers), to: Self.peersFile)
    }
}
