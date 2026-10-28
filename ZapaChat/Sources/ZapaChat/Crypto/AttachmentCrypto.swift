import CryptoKit
import Foundation

/// Photos and voice messages: a fresh AES-256-GCM key per file; only the ciphertext is uploaded. The key and the
/// ciphertext's SHA-256 travel inside the sealed message.
public enum AttachmentCrypto {
    public struct Sealed: Sendable {
        public let ciphertext: Data
        public let key: Data
        public let digest: Data
    }

    public static func encrypt(_ plaintext: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw ChatAPIError.invalidResponse
        }
        return Sealed(
            ciphertext: combined, key: key.withUnsafeBytes { Data($0) }, digest: Data(SHA256.hash(data: combined))
        )
    }

    public static func decrypt(_ ciphertext: Data, key: Data, digest: Data) throws -> Data {
        guard Data(SHA256.hash(data: ciphertext)) == digest else { throw ChatAPIError.invalidResponse }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: key))
    }
}
