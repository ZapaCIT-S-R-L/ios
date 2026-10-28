import Foundation

/// A peer's identity key as this account knows it, and whether a change still waits for the parent's OK.
struct PeerIdentity: Codable, Equatable {
    var key: Data
    var needsAcknowledgement: Bool
}

/// The peers this account trusts, kept with the account (security review 2026-10-27, M1): a synced Keychain item
/// next to the identity, so the parent's other phones and a reinstall know the same keys. Without it a reinstall
/// would trust every peer on first use again, and a server could swap a key unnoticed.
/// Public keys only (no secret), but synced and readable when unlocked like the identity, and scoped to one account.
struct PeerTrustStore {
    /// The stored list belongs to another account: never use it.
    struct WrongAccount: Error {}

    let accountId: String
    let keychain: KeychainData

    private struct Stored: Codable {
        var accountId: String
        var peers: [String: PeerIdentity]
    }

    func load() throws -> [String: PeerIdentity] {
        guard let data = try keychain.load() else { return [:] }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.accountId == accountId else { throw WrongAccount() }
        return stored.peers
    }

    func save(_ peers: [String: PeerIdentity]) throws {
        try keychain.save(JSONEncoder().encode(Stored(accountId: accountId, peers: peers)))
    }
}
