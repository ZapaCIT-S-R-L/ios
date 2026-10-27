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
    /// The iOS OAuth client of ro.zapakid.app (Google Cloud, team 9572LYGZ7S). Not a secret: it ships in every copy
    /// of the app. The ID token's audience is this client, so the API must list it as an allowed audience.
    /// While the OAuth consent screen is in Testing mode, only Google accounts added as test users can sign in.
    static let clientID = "64042746735-lgdmtj9vvd3kiu7g9qc2elu22la6o1id.apps.googleusercontent.com"

    static var isConfigured: Bool {
        !clientID.isEmpty
    }

    private var session: ASWebAuthenticationSession?

    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc" (the scheme registered for the
    /// iOS client; ASWebAuthenticationSession receives the callback, no Info.plist URL type needed).
    static var scheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static var redirect: String {
        "\(scheme):/oauth2redirect"
    }

    static func authorizationURL(nonce: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "nonce", value: nonce),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        return components?.url
    }

    /// The authorization code, only when the callback belongs to this sign-in (same `state`).
    static func code(from callback: URL, state: String) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    func idToken(nonce: String) async throws -> String {
        guard Self.isConfigured else { throw GoogleSignInError.notConfigured }
        let verifier = try Self.randomBase64URL()
        let state = try Self.randomBase64URL()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        guard let url = Self.authorizationURL(nonce: nonce, challenge: challenge, state: state) else {
            throw GoogleSignInError.notConfigured
        }
        let callback = try await authorize(url)
        guard let code = Self.code(from: callback, state: state) else {
            throw ASWebAuthenticationSessionError(.canceledLogin)
        }
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

    /// 32 random bytes from the system generator, base64url: 43 characters (a valid PKCE code verifier, RFC 7636,
    /// and an unguessable OAuth state).
    private static func randomBase64URL() throws -> String {
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
