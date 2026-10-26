import Foundation

/// The sign-in client for the ZapaKid API (Cloudflare Workers).
///
/// Contract (to be replaced by the generated client once `ZapaCIT-S-R-L/api` publishes `openapi.yaml`):
/// - `POST /v1/auth/apple`, `POST /v1/auth/google`
///   body `{"idToken": "...", "nonce": "<raw nonce>", "ageRange": {"lower": 18, "declined": false} | null}`
///   → 200 `{"token": "...", "parent": {"id": "...", "name": "...", "email": "..."}}`
///   → 403 `{"error": {"code": "minor", ...}}` for a parent under 18
/// - `GET /v1/me` with `Authorization: Bearer <token>` → 200 `{"parent": {...}}`, 401 when the session is gone
/// - `POST /v1/auth/logout` with `Authorization: Bearer <token>` → 204
/// - errors: `{"error": {"code": "...", "message": "..."}}`
///
/// The ID token carries SHA-256(nonce) as hex in its `nonce` claim (Apple and Google), so the API can check that the
/// token was issued for this sign-in and can't be replayed.
public struct HTTPAuthAPI: AuthAPI {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = URLSession(configuration: HTTPAuthAPI.secureConfiguration())) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The staging API with the secure session.
    public static var staging: HTTPAuthAPI {
        // swiftlint:disable:next force_unwrapping
        HTTPAuthAPI(baseURL: URL(string: ZapaKidKit.apiBaseURL)!)
    }

    /// TLS 1.3 or newer, nothing written to disk: no cookies, no response cache.
    public static func secureConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return config
    }

    public func signIn(_ request: SignInRequest) async throws -> Session {
        let body = SignInBody(idToken: request.idToken, nonce: request.nonce, ageRange: request.ageRange)
        return try await send("POST", "v1/auth/\(request.provider.rawValue)", body: body)
    }

    public func me(token: String) async throws -> ParentProfile {
        let reply: MeReply = try await send("GET", "v1/me", token: token)
        return reply.parent
    }

    public func logout(token: String) async throws {
        _ = try await data("POST", "v1/auth/logout", token: token, body: nil)
    }

    // MARK: - HTTP

    private struct SignInBody: Encodable {
        var idToken: String
        var nonce: String
        var ageRange: AgeRange?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(idToken, forKey: .idToken)
            try container.encode(nonce, forKey: .nonce)
            try container.encode(ageRange, forKey: .ageRange) // null when unknown, so the API sees it was asked
        }

        enum CodingKeys: String, CodingKey { case idToken, nonce, ageRange }
    }

    private struct MeReply: Decodable { var parent: ParentProfile }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable { var code: String? }
        var error: Detail?
    }

    private func send<Reply: Decodable>(
        _ method: String, _ path: String, token: String? = nil, body: (some Encodable)? = String?.none
    ) async throws -> Reply {
        let json = try body.map { try JSONEncoder().encode($0) }
        let data = try await data(method, path, token: token, body: json)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw AuthAPIError.invalidResponse
        }
    }

    private func data(_ method: String, _ path: String, token: String?, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw AuthAPIError.unauthorized
        default:
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error?.code
            if http.statusCode == 403, code == "minor" {
                throw AuthAPIError.minor
            }
            throw AuthAPIError.server(status: http.statusCode, code: code)
        }
    }
}
