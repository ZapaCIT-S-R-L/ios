import CryptoKit
import Foundation

/// The server's one-time sign-in nonce, as Apple and Google need it: they get `hashed` (lowercase hex SHA-256) and
/// put it in the ID token's `nonce` claim; the API gets `raw` with the token and checks the two match, once.
/// This is OAuth plumbing with the system's SHA-256, not chat encryption (that is libsignal only).
public struct SignInNonce: Sendable, Equatable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
