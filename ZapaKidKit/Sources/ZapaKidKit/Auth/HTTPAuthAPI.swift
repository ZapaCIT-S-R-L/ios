import Foundation

/// The Sign-in and Account client for the ZapaKid API (Cloudflare Workers), per `openapi.yaml` in
/// ZapaCIT-S-R-L/zapakid-api (stable tags `Sign-in` and `Account`):
/// - `POST /v1/auth/nonce` → `{nonce, expiresAt}`, one use, 10 minutes
/// - `POST /v1/auth/apple` `{nonce, identityToken, ageRange, displayName?}`,
///   `POST /v1/auth/google` `{nonce, idToken, ageRange}` → `{session: {token, expiresAt}, parent, newAccount}`
/// - `GET /v1/me` → `Parent`;  `POST /v1/auth/logout` → 204 (both with `Authorization: Bearer <token>`)
/// - errors `{"error": {"code", "message"}}`; the app branches on `code` only and never logs bodies or tokens.
/// With an `attestor`, `POST /v1/devices` and `PUT /v1/keys/identity` carry the `ZapaKid-Attestation` header.
public struct HTTPAuthAPI: AuthAPI, DeviceAPI, DevicePushAPI, AppAttestAPI {
    public let baseURL: URL
    private let session: URLSession
    private let attestor: AppAttestor?

    public init(
        baseURL: URL,
        session: URLSession = URLSession(configuration: HTTPAuthAPI.secureConfiguration()),
        attestor: AppAttestor? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.attestor = attestor
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

    // MARK: - Devices and keys

    public func registerDevice(_ keys: DeviceKeys, token: String) async throws -> Int {
        struct Reply: Decodable {
            var deviceId: Int
        }
        let reply: Reply = try await attested("POST", "v1/devices", token: token, body: Self.encoder.encode(keys))
        guard (1 ... 127).contains(reply.deviceId) else { throw AuthAPIError.invalidResponse }
        return reply.deviceId
    }

    /// `PUT /v1/keys/identity`: this phone's keys with a new identity; it becomes the account's only device.
    public func changeIdentity(_ keys: DeviceKeys, token: String) async throws -> Int {
        struct Reply: Decodable {
            var deviceId: Int
        }
        let body = try Self.encoder.encode(keys)
        let reply: Reply = try await attested("PUT", "v1/keys/identity", token: token, body: body)
        guard (1 ... 127).contains(reply.deviceId) else { throw AuthAPIError.invalidResponse }
        return reply.deviceId
    }

    /// `PUT /v1/devices/{deviceId}/push`: nulls clear the target (JSONEncoder would drop them, so this is spelled out).
    public func setDevicePush(deviceId: Int, target: PushTarget?, token: String) async throws {
        try await putPushTarget("v1/devices/\(deviceId)/push", target: target, token: token)
    }

    /// `PUT /v1/devices/{deviceId}/alert-push`: the APNs token for chat notifications.
    public func setDeviceAlertPush(deviceId: Int, target: PushTarget?, token: String) async throws {
        try await putPushTarget("v1/devices/\(deviceId)/alert-push", target: target, token: token)
    }

    private func putPushTarget(_ path: String, target: PushTarget?, token: String) async throws {
        let fields: [String: Any] = target.map { ["provider": $0.provider.rawValue, "token": $0.token] }
            ?? ["provider": NSNull(), "token": NSNull()]
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await data("PUT", path, token: token, body: body)
    }

    public func accountIdentity(accountId: String, token: String) async throws -> String? {
        struct Reply: Decodable {
            var identityKey: String
        }
        // Escape the ID (account IDs are UUIDs, but a value from the network must never change the path).
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = accountId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw AuthAPIError.invalidResponse
        }
        do {
            let reply: Reply = try await send("GET", "v1/accounts/\(escaped)/identity", token: token)
            return reply.identityKey
        } catch AuthAPIError.server(status: 404, _) {
            return nil
        }
    }

    public func preKeyCount(token: String) async throws -> PreKeyCount {
        try await send("GET", "v1/keys/prekeys", token: token)
    }

    // MARK: - App attestation

    public func attestationChallenge() async throws -> String {
        struct Reply: Decodable {
            var challenge: String
        }
        let reply: Reply = try await send("POST", "v1/attestation/challenge")
        return reply.challenge
    }

    public func registerAppAttestKey(keyId: String, attestationObject: Data, challenge: String) async throws {
        struct Body: Encodable {
            var keyId: String
            var attestationObject: String
            var challenge: String
        }
        let body = try Self.encoder.encode(Body(
            keyId: keyId, attestationObject: attestationObject.base64EncodedString(), challenge: challenge
        ))
        _ = try await data("POST", "v1/attestation/apple", token: nil, body: body)
    }

    /// A request with app attestation over its exact body. When the API refuses the key (unknown to it, or unused
    /// for 180 days and deleted), one more try with a new key; a second refusal is final.
    private func attested<Reply: Decodable>(
        _ method: String, _ path: String, token: String, body: Data
    ) async throws -> Reply {
        guard let attestor else { return try await send(method, path, token: token, body: body) }
        let header = try await attestor.header(for: body)
        do {
            return try await send(method, path, token: token, body: body, attestation: header)
        } catch AuthAPIError.attestationFailed where header != nil {
            await attestor.discardKey()
            let fresh = try await attestor.header(for: body)
            return try await send(method, path, token: token, body: body, attestation: fresh)
        }
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
        _ method: String, _ path: String, token: String? = nil, body: Data? = nil, attestation: String? = nil
    ) async throws -> Reply {
        let data = try await data(method, path, token: token, body: body, attestation: attestation)
        do {
            return try Self.decoder.decode(Reply.self, from: data)
        } catch {
            throw AuthAPIError.invalidResponse
        }
    }

    private func data(
        _ method: String, _ path: String, token: String?, body: Data?, attestation: String? = nil
    ) async throws -> Data {
        // `path` is already escaped (see accountIdentity), so join strings instead of appendingPathComponent,
        // which would escape the escapes.
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        guard let url = URL(string: base + path) else { throw AuthAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let attestation {
            request.setValue(attestation, forHTTPHeaderField: AppAttestor.headerName)
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

    private static func forbidden(_ code: String?) -> AuthAPIError {
        switch code {
        case "minor_not_allowed": .minorNotAllowed
        case "age_declined": .ageDeclined
        case "attestation_failed": .attestationFailed
        case "reauthentication_required": .reauthenticationRequired
        default: .server(status: 403, code: code)
        }
    }

    private static func error(status: Int, code: String?, retryAfter: String?) -> AuthAPIError {
        switch (status, code) {
        case (401, "invalid_token"): .invalidToken
        case (401, "invalid_nonce"): .invalidNonce
        case (401, _): .unauthorized
        case (403, _): forbidden(code)
        case (409, "identity_mismatch"): .identityMismatch
        case (429, _): .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        case (503, "provider_unavailable"): .providerUnavailable
        default: .server(status: status, code: code)
        }
    }
}
