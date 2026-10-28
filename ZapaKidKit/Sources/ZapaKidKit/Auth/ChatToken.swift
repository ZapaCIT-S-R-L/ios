import Foundation

/// `POST /v1/chat/token` on the account API: the session buys a short-lived ES256 token (≤ 15 min) for the chat
/// and calls services (`aud` both hosts, `conv` the account's conversations).
public struct HTTPChatTokenAPI: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = URLSession(configuration: HTTPAuthAPI.secureConfiguration())) {
        self.baseURL = baseURL
        self.session = session
    }

    public struct ChatToken: Decodable, Sendable {
        public var token: String
        public var expiresAt: Date
    }

    public func issue(sessionToken: String) async throws -> ChatToken {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
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
            guard let token = try? HTTPAuthAPI.decoder.decode(ChatToken.self, from: data) else {
                throw AuthAPIError.invalidResponse
            }
            return token
        case 401: throw AuthAPIError.unauthorized
        default: throw AuthAPIError.server(status: http.statusCode, code: nil)
        }
    }
}

/// Hands out the chat token, fetching a new one a minute before it expires. Tokens stay in memory only.
public actor ChatTokenProvider {
    private let api: HTTPChatTokenAPI
    private let session: @Sendable () async -> String?
    private let now: @Sendable () -> Date
    private var cached: HTTPChatTokenAPI.ChatToken?

    public init(
        api: HTTPChatTokenAPI, session: @escaping @Sendable () async -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.session = session
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > 60 {
            return cached.token
        }
        guard let sessionToken = await session() else { throw AuthAPIError.unauthorized }
        let fresh = try await api.issue(sessionToken: sessionToken)
        cached = fresh
        return fresh.token
    }

    /// After a 401 from chat or calls.
    public func invalidate() {
        cached = nil
    }
}
