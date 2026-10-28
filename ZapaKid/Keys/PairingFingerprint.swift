import Foundation
import ZapaKidKit

/// This account's identity key fingerprint for the kid pairing QR (`fp`). Only reads the identity: a phone without
/// one waits for a re-share (identity-sync) and its QR has no `fp`.
enum PairingFingerprint {
    static func current(_ store: LocalIdentityStore) -> String? {
        guard let identity = try? store.load() else { return nil }
        return IdentityFingerprint.hex(Data(identity.keyPair.publicKey.serialize()))
    }
}
