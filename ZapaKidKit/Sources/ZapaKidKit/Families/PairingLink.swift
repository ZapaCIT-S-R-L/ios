import CryptoKit
import Foundation

/// The kid pairing QR: `zapakid://pair?code=<zkp_ code>&fp=<parent identity key fingerprint, hex>`.
/// The kid's phone keeps `fp` to check the parent's key out of band instead of trusting it on first use.
public struct PairingLink: Equatable, Sendable {
    public let code: String
    public let fingerprint: String?

    public init(code: String, fingerprint: String?) {
        self.code = code
        self.fingerprint = fingerprint
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "zapakid"
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "code", value: code)] +
            (fingerprint.map { [URLQueryItem(name: "fp", value: $0)] } ?? [])
        // swiftlint:disable:next force_unwrapping
        return parts.url!
    }

    /// From a scanned QR or a typed/pasted code. Anything else is nil.
    public init?(scanned text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isCode(text) {
            self.init(code: text, fingerprint: nil)
            return
        }
        guard let parts = URLComponents(string: text), parts.scheme == "zapakid", parts.host == "pair",
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, Self.isCode(code)
        else { return nil }
        let fingerprint = parts.queryItems?.first { $0.name == "fp" }?.value
        self.init(code: code, fingerprint: fingerprint.flatMap { Self.isFingerprint($0) ? $0 : nil })
    }

    static func isCode(_ text: String) -> Bool {
        text.wholeMatch(of: /zkp_[A-Za-z0-9_-]{43}/) != nil
    }

    static func isFingerprint(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9a-f]{64}/) != nil
    }
}

/// The co-parent invitation: `https://zapakid.ro/join#<zki_ code>` (the fragment never reaches a server log).
public enum InvitationLink {
    public static func url(code: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://zapakid.ro/join#\(code)")!
    }

    public static func code(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.hasPrefix("https://zapakid.ro/join#") ? String(text.dropFirst(24)) : text
        return candidate.wholeMatch(of: /zki_[A-Za-z0-9_-]{43}/) != nil ? candidate : nil
    }
}

/// A public key's fingerprint for QR codes: SHA-256, lowercase hex.
public enum IdentityFingerprint {
    public static func hex(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
}
