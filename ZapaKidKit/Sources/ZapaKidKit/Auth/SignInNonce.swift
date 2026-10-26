import CryptoKit
import Foundation

/// A one-time value for one sign-in. The provider (Apple or Google) gets `hashed` and puts it in the ID token's
/// `nonce` claim; the API gets `raw` and checks SHA-256(raw) == claim, so a stolen ID token can't be replayed.
/// This is OAuth plumbing with the system's SHA-256, not chat encryption (that is libsignal only).
public struct SignInNonce: Sendable {
    public let raw: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system random generator failed")
        raw = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init(raw: String) {
        self.raw = raw
    }

    /// SHA-256 of `raw`, lowercase hex.
    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
