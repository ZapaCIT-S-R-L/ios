import Foundation

/// The Sign-in and Account client for the ZapaKid API (Cloudflare Workers), per `openapi.yaml` in
/// ZapaCIT-S-R-L/zapakid-api (stable tags `Sign-in` and `Account`):
/// - `POST /v1/auth/nonce` → `{nonce, expiresAt}`, one use, 10 minutes
/// - `POST /v1/auth/apple` `{nonce, identityToken, ageRange, displayName?}`,
///   `POST /v1/auth/google` `{nonce, idToken, ageRange}` → `{session: {token, expiresAt}, parent, newAccount}`
/// - `GET /v1/me` → `Parent`;  `POST /v1/auth/logout` → 204 (both with `Authorization: Bearer <token>`)
/// - errors `{"error": {"code", "message"}}`; the app branches on `code` only and never logs bodies or tokens.
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

    public func signInNonce() async throws -> SignInNonceGrant {
        try await send("POST", "v1/auth/nonce")
    }

    public func signIn(_ request: SignInRequest) async throws -> Session {
        let body: Data = switch request.provider {
        case .apple:
            try Self.encoder.encode(AppleBody(
                nonce: request.nonce, identityToken: request.idToken,
                ageRange: request.ageRange, displayName: request.displayName
            ))
        case .google:
            try Self.encoder.encode(GoogleBody(
                nonce: request.nonce, idToken: request.idToken, ageRange: request.ageRange
            ))
        }
        let reply: SignInReply = try await send("POST", "v1/auth/\(request.provider.rawValue)", body: body)
        return Session(token: reply.session.token, expiresAt: reply.session.expiresAt, parent: reply.parent)
    }

    public func me(token: String) async throws -> ParentProfile {
        try await send("GET", "v1/me", token: token)
    }

    public func logout(token: String) async throws {
        _ = try await data("POST", "v1/auth/logout", token: token, body: nil)
    }

    // MARK: - Bodies

    private struct AppleBody: Encodable {
        var nonce: String
        var identityToken: String
        var ageRange: AgeRange
        var displayName: String?
    }

    private struct GoogleBody: Encodable {
        var nonce: String
        var idToken: String
        var ageRange: AgeRange
    }

    private struct SignInReply: Decodable {
        struct Token: Decodable {
            var token: String
            var expiresAt: Date
        }

        var session: Token
        var parent: ParentProfile
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            var code: String?
        }

        var error: Detail?
    }

    // MARK: - HTTP

    static let encoder = JSONEncoder()

    /// RFC 3339 dates, with or without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date"))
        }
        return decoder
    }()

    private func send<Reply: Decodable>(
        _ method: String, _ path: String, token: String? = nil, body: Data? = nil
    ) async throws -> Reply {
        let data = try await data(method, path, token: token, body: body)
        do {
            return try Self.decoder.decode(Reply.self, from: data)
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
        if (200 ..< 300).contains(http.statusCode) {
            return data
        }
        let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error?.code
        throw Self.error(status: http.statusCode, code: code, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    private static func error(status: Int, code: String?, retryAfter: String?) -> AuthAPIError {
        switch (status, code) {
        case (401, "invalid_token"): .invalidToken
        case (401, "invalid_nonce"): .invalidNonce
        case (401, _): .unauthorized
        case (403, "minor_not_allowed"): .minorNotAllowed
        case (403, "age_declined"): .ageDeclined
        case (403, "attestation_failed"): .attestationFailed
        case (429, _): .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        case (503, "provider_unavailable"): .providerUnavailable
        default: .server(status: status, code: code)
        }
    }
}
