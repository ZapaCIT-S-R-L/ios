import Foundation
import LibSignalClient
import Testing

/// libsignal (LibSignalClient, Signal's CocoaPod) is linked and works in the app: all chat cryptography is libsignal's.
struct LibSignalTests {
    @Test func identityKeyPairRoundTrips() throws {
        let pair = IdentityKeyPair.generate()

        let restored = try IdentityKeyPair(bytes: pair.serialize())

        #expect(restored.publicKey.serialize() == pair.publicKey.serialize())
        #expect(restored.privateKey.serialize() == pair.privateKey.serialize())
    }

    @Test func signaturesVerifyOnlyForTheSignedMessage() throws {
        let pair = IdentityKeyPair.generate()
        let message = Data("TEST message".utf8)

        let signature = pair.privateKey.generateSignature(message: message)

        #expect(try pair.publicKey.verifySignature(message: message, signature: signature))
        #expect(try !pair.publicKey.verifySignature(message: Data("other".utf8), signature: signature))
    }
}
