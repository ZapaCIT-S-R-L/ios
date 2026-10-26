import AuthenticationServices
import CryptoKit
import UIKit
import ZapaKidKit

/// Returns a Google ID token whose `nonce` claim is the given (hashed) nonce.
@MainActor
protocol GoogleSignInProviding {
    func idToken(nonce: String) async throws -> String
}

enum GoogleSignInError: LocalizedError {
    case notConfigured
    case noToken

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Google sign-in isn't set up yet.")
        case .noToken: String(localized: "Google didn't return a sign-in token.")
        }
    }
}

/// Sign in with Google without an SDK: OAuth 2.0 authorization code + PKCE in an ASWebAuthenticationSession, then
/// the code is exchanged for an ID token, which the API verifies (signature, audience, nonce).
@MainActor
final class GoogleSignIn: NSObject, GoogleSignInProviding, ASWebAuthenticationPresentationContextProviding {
    /// The iOS OAuth client ID from Google Cloud Console (type iOS, bundle ID com.zapacit.cuzaai).
    /// Not a secret (it ships in every copy of the app); the API lists the same ID as an allowed audience.
    /// TODO: set once Stefan creates the client.
    static let clientID = ""

    private var session: ASWebAuthenticationSession?

    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc".
    private static var scheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static var redirect: String {
        "\(scheme):/oauth2redirect"
    }

    func idToken(nonce: String) async throws -> String {
        guard !Self.clientID.isEmpty else { throw GoogleSignInError.notConfigured }
        let verifier = try Self.pkceVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "nonce", value: nonce),
            .init(name: "prompt", value: "select_account"),
        ]
        guard let url = components?.url else { throw GoogleSignInError.notConfigured }
        let callback = try await authorize(url)
        let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        guard let code else { throw ASWebAuthenticationSessionError(.canceledLogin) }
        return try await exchange(code: code, verifier: verifier)
    }

    private func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
    }

    /// iOS clients have no client secret; PKCE proves the code came back to this app.
    private func exchange(code: String, verifier: String) async throws -> String {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { throw GoogleSignInError.noToken }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession(configuration: HTTPAuthAPI.secureConfiguration()).data(for: request)
        struct Token: Decodable {
            var idToken: String?
            enum CodingKeys: String, CodingKey { case idToken = "id_token" }
        }
        guard let idToken = try JSONDecoder().decode(Token.self, from: data).idToken else {
            throw GoogleSignInError.noToken
        }
        return idToken
    }

    /// 32 random bytes from the system generator, base64url: 43 characters, a valid PKCE code verifier (RFC 7636).
    private static func pkceVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleSignInError.noToken
        }
        return Data(bytes).base64URL
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
