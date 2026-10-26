import Foundation
import LibSignalClient

/// This phone's libsignal identity: the identity key pair and the registration ID.
struct LocalIdentity {
    let keyPair: IdentityKeyPair
    let registrationId: UInt32
}

/// Keeps the identity in the Keychain, this device only, created on first use with libsignal.
/// TODO (later PR): sharing one identity across a parent's phones and the history backup item (iCloud Keychain,
/// the one deliberately synchronizable item) are decided separately; signing in alone never restores keys.
struct LocalIdentityStore {
    var keychain = KeychainData(service: "ro.zapakid.app.identity", account: "identity")

    private struct Stored: Codable {
        var keyPair: Data
        var registrationId: UInt32
    }

    func loadOrCreate() throws -> LocalIdentity {
        if let data = try keychain.load() {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            return try LocalIdentity(
                keyPair: IdentityKeyPair(bytes: stored.keyPair),
                registrationId: stored.registrationId
            )
        }
        // libsignal registration IDs are 14 bits and never 0; SystemRandomNumberGenerator is the system CSPRNG.
        var random = SystemRandomNumberGenerator()
        let identity = LocalIdentity(
            keyPair: IdentityKeyPair.generate(), registrationId: UInt32.random(in: 1 ... 16380, using: &random)
        )
        try keychain.save(JSONEncoder().encode(Stored(
            keyPair: identity.keyPair.serialize(), registrationId: identity.registrationId
        )))
        return identity
    }
}
