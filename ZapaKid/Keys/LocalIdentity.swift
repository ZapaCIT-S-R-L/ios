import Foundation
import LibSignalClient

/// This account's libsignal identity: the identity key pair and the registration ID.
struct LocalIdentity {
    let keyPair: IdentityKeyPair
    let registrationId: UInt32
}

/// Where this phone stands with the account's identity.
enum IdentityState: Equatable {
    case ready(LocalIdentity)
    /// The account has an identity, but this phone doesn't have it yet (no iCloud Keychain copy). Another family
    /// phone must re-share it; a new key here would look like a key change to every peer.
    case waitingForReshare

    static func == (lhs: IdentityState, rhs: IdentityState) -> Bool {
        switch (lhs, rhs) {
        case let (.ready(left), .ready(right)):
            left.keyPair.serialize() == right.keyPair.serialize() && left.registrationId == right.registrationId
        case (.waitingForReshare, .waitingForReshare):
            true
        default:
            false
        }
    }
}

/// Asks another phone of the family to re-share the identity. TODO (later PR): the re-share flow (QR or the
/// encrypted device-link channel); for now a stub.
protocol IdentityReshare {
    func requestReshare()
}

/// One identity per account (decided 2026-10-26): the identity key pair is the one deliberately synchronizable
/// Keychain item, so the parent's other phones and a reinstall get it through iCloud Keychain (end-to-end encrypted
/// by Apple, needs the device passcode). Signing in alone never restores it. Prekeys and sessions stay on this phone.
struct LocalIdentityStore {
    /// The stored identity belongs to another account (copied or restored into the wrong slot): never use it.
    struct WrongAccount: Error {}

    let accountId: String
    let keychain: KeychainData

    init(accountId: String, keychain: KeychainData) {
        self.accountId = accountId
        self.keychain = keychain
    }

    init(accountId: String) {
        self.init(accountId: accountId, keychain: .syncedIdentity(accountId: accountId))
    }

    /// The account ID is stored inside the item too, and checked on every load.
    private struct Stored: Codable {
        var accountId: String
        var keyPair: Data
        var registrationId: UInt32
    }

    func load() throws -> LocalIdentity? {
        guard let data = try keychain.load() else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.accountId == accountId else { throw WrongAccount() }
        return try LocalIdentity(keyPair: IdentityKeyPair(bytes: stored.keyPair), registrationId: stored.registrationId)
    }

    /// The identity when this phone has it; a new one only for an account that has none yet (`accountHasIdentity` is
    /// what the API's key directory says); otherwise wait for a re-share.
    func resolve(accountHasIdentity: Bool, reshare: IdentityReshare) throws -> IdentityState {
        if let identity = try load() {
            return .ready(identity)
        }
        guard !accountHasIdentity else {
            reshare.requestReshare()
            return .waitingForReshare
        }
        return try .ready(createNew())
    }

    /// A new identity for this account, stored (replacing any earlier one on this phone).
    func createNew() throws -> LocalIdentity {
        // libsignal registration IDs are 14 bits and never 0; SystemRandomNumberGenerator is the system CSPRNG.
        var random = SystemRandomNumberGenerator()
        let identity = LocalIdentity(
            keyPair: IdentityKeyPair.generate(), registrationId: UInt32.random(in: 1 ... 16380, using: &random)
        )
        try keychain.save(JSONEncoder().encode(Stored(
            accountId: accountId, keyPair: identity.keyPair.serialize(), registrationId: identity.registrationId
        )))
        return identity
    }
}
