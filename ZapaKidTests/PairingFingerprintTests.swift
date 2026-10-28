import Foundation
import LibSignalClient
import Testing
@testable import ZapaKid
import ZapaKidKit

/// The pairing QR's `fp` is this account's identity key fingerprint. Showing a QR must never create an identity
/// (identity-sync: a phone without it waits for a re-share); without one, the QR simply has no `fp`.
@Suite(.serialized)
struct PairingFingerprintTests {
    let keychainService = "ro.zapakid.app.tests.fp.\(UUID().uuidString)"

    func store() -> LocalIdentityStore {
        LocalIdentityStore(keychain: .syncedIdentity(service: keychainService))
    }

    @Test func noIdentityMeansNoFingerprintAndNoNewIdentity() throws {
        defer { try? store().keychain.clear() }

        #expect(PairingFingerprint.current(store()) == nil)
        #expect(try store().load() == nil)
    }

    @Test func theFingerprintIsTheIdentityKeysSHA256() throws {
        defer { try? store().keychain.clear() }
        guard case let .ready(identity) = try store().resolve(accountHasIdentity: false, reshare: NoReshare()) else {
            throw CancellationError()
        }

        #expect(PairingFingerprint.current(store()) ==
            IdentityFingerprint.hex(Data(identity.keyPair.publicKey.serialize())))
    }
}
