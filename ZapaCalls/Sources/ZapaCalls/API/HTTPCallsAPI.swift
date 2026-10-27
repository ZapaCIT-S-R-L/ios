import Foundation

/// `CallsAPI` over HTTPS and a WebSocket, with the short-lived chat token (ES256, ≤ 15 min, `aud` includes
/// calls.zapakid.ro) from the account service as `Authorization: Bearer`. Errors `{"error": {"code"}}` map by code;
/// bodies and tokens are never logged.
public struct HTTPCallsAPI: CallsAPI {
    public let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(
        baseURL: URL,
        session: URLSession = URLSession(configuration: HTTPCallsAPI.secureConfiguration()),
        token: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    public static let stagingURL = URL(string: "https://calls-staging.zapakid.ro")
    public static let productionURL = URL(string: "https://calls.zapakid.ro")

    /// TLS 1.3, no cookies, no cache.
    public static func secureConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return config
    }

    // MARK: Calls

    public func createCall(conversationId: String) async throws -> CallGrant {
        try await send("POST", ["v1", "calls"], body: ["conversationId": conversationId])
    }

    public func join(callId: String) async throws -> CallGrant {
        try await send("POST", ["v1", "calls", callId, "join"])
    }

    public func leave(callId: String) async throws {
        _ = try await data("POST", ["v1", "calls", callId, "leave"], body: nil)
    }

    public func decline(callId: String) async throws {
        _ = try await data("POST", ["v1", "calls", callId, "decline"], body: nil)
    }

    // MARK: Realtime proxy

    private struct NewSession: Decodable {
        var sessionId: String
    }

    private struct Renegotiate: Encodable {
        var sessionDescription: SessionDescription
    }

    private struct Close: Encodable {
        struct Mid: Encodable {
            var mid: String
        }

        var tracks: [Mid]
        var force: Bool
    }

    public func newSession(callId: String) async throws -> String {
        let reply: NewSession = try await send("POST", ["v1", "calls", callId, "sessions"])
        return reply.sessionId
    }

    public func addTracks(callId: String, sessionId: String, request: TracksRequest) async throws -> TracksResponse {
        try await send("POST", rtc(callId, "sessions", sessionId, "tracks", "new"), body: request)
    }

    public func renegotiate(callId: String, sessionId: String, answer: SessionDescription) async throws {
        _ = try await data(
            "PUT", rtc(callId, "sessions", sessionId, "renegotiate"),
            body: Self.encoder.encode(Renegotiate(sessionDescription: answer))
        )
    }

    public func closeTracks(callId: String, sessionId: String, mids: [String]) async throws -> TracksResponse {
        try await send(
            "PUT", rtc(callId, "sessions", sessionId, "tracks", "close"),
            body: Close(tracks: mids.map { Close.Mid(mid: $0) }, force: false)
        )
    }

    private func rtc(_ callId: String, _ rest: String...) -> [String] {
        ["v1", "calls", callId] + rest
    }

    // MARK: Events

    public func openEvents(callId: String) async throws -> CallEventsConnection {
        let request = try await eventsRequest(callId: callId, token: token())
        return WebSocketCallEvents(task: session.webSocketTask(with: request))
    }

    /// `GET /v1/calls/{id}/events` upgraded to a WebSocket (wss for https, ws for a local http service).
    func eventsRequest(callId: String, token: String) throws -> URLRequest {
        guard var parts = URLComponents(url: url(["v1", "calls", callId, "events"]), resolvingAgainstBaseURL: false)
        else { throw CallsAPIError.invalidResponse }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        guard let url = parts.url else { throw CallsAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: HTTP

    static let encoder = JSONEncoder()

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            var code: String?
        }

        var error: Detail?
    }

    /// Each segment is percent-escaped, so an ID can't change the path.
    private func url(_ segments: [String]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let path = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            .joined(separator: "/")
        // swiftlint:disable:next force_unwrapping
        return URL(string: path, relativeTo: baseURL.appendingPathComponent(""))!.absoluteURL
    }

    private func send<Reply: Decodable>(_ method: String, _ path: [String]) async throws -> Reply {
        try await decode(data(method, path, body: nil))
    }

    private func send<Reply: Decodable>(
        _ method: String, _ path: [String], body: some Encodable
    ) async throws -> Reply {
        try await decode(data(method, path, body: Self.encoder.encode(body)))
    }

    private func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw CallsAPIError.invalidResponse
        }
    }

    private func data(_ method: String, _ path: [String], body: Data?) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await request.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CallsAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw CallsAPIError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) {
            return data
        }
        let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error?.code
        throw Self.error(status: http.statusCode, code: code, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    static func error(status: Int, code: String?, retryAfter: String?) -> CallsAPIError {
        switch (status, code) {
        case (401, _): .unauthorized
        case (403, _): .notAllowed
        case (404, _): .callNotFound
        case (409, "call_full"): .callFull
        case (410, _): .callEnded
        case (429, _): .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        default: .server(status: status, code: code)
        }
    }
}

/// The event socket over `URLSessionWebSocketTask`; JSON text frames.
final class WebSocketCallEvents: CallEventsConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncThrowingStream<CallSignal, Error>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncThrowingStream<CallSignal, Error>.makeStream()
        self.stream = stream
        task.resume()
        Task { [task] in
            do {
                while true {
                    let message = try await task.receive()
                    let data = switch message {
                    case let .string(text): Data(text.utf8)
                    case let .data(data): data
                    @unknown default: Data()
                    }
                    if let signal = try? CallSignal.decode(data) {
                        continuation.yield(signal)
                    }
                }
            } catch {
                continuation.finish(throwing: task.closeCode == .normalClosure ? nil : error)
            }
        }
        continuation.onTermination = { [task] _ in task.cancel(with: .normalClosure, reason: nil) }
    }

    func signals() -> AsyncThrowingStream<CallSignal, Error> {
        stream
    }

    func send(_ signal: OutgoingSignal) async throws {
        guard let text = try String(bytes: signal.encoded(), encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
