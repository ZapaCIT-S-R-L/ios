import Foundation

/// `ChatAPI` over HTTPS and a WebSocket with the short-lived chat token. Attachments go to one-time URLs without
/// Authorization. Bodies and tokens are never logged.
public struct HTTPChatAPI: ChatAPI {
    public let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public static let stagingURL = URL(string: "https://chat-staging.zapakid.ro")

    public init(
        baseURL: URL,
        session: URLSession = URLSession(configuration: HTTPChatAPI.secureConfiguration()),
        token: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

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

    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    private struct Conversations: Decodable {
        var conversations: [Conversation]
    }

    private struct Members: Encodable {
        var members: [String]
    }

    private struct Send: Encodable {
        var messageId: String
        var envelopes: [OutgoingEnvelope]
    }

    private struct Sent: Decodable {
        var serverTimestamp: Int64
    }

    private struct Ack: Encodable {
        var envelopeIds: [String]
    }

    private struct Reserve: Encodable {
        var conversationId: String
        var size: Int
    }

    private struct Upload: Decodable {
        var attachmentId: String
        var uploadUrl: URL
    }

    private struct Download: Decodable {
        var downloadUrl: URL
    }

    public func conversations() async throws -> [Conversation] {
        let reply: Conversations = try await json("GET", ["v1", "conversations"])
        return reply.conversations
    }

    public func conversation(id: String) async throws -> Conversation {
        try await json("GET", ["v1", "conversations", id])
    }

    public func createConversation(members: [String]) async throws -> Conversation {
        try await json("POST", ["v1", "conversations"], body: Members(members: members))
    }

    public func send(conversationId: String, messageId: String, envelopes: [OutgoingEnvelope]) async throws -> Date {
        let reply: Sent = try await json(
            "POST", ["v1", "conversations", conversationId, "messages"],
            body: Send(messageId: messageId, envelopes: envelopes)
        )
        return Date(timeIntervalSince1970: TimeInterval(reply.serverTimestamp) / 1000)
    }

    public func fetch(conversationId: String) async throws -> EnvelopePage {
        try await json("GET", ["v1", "conversations", conversationId, "messages"])
    }

    public func ack(conversationId: String, envelopeIds: [String]) async throws {
        _ = try await data(
            request(
                "POST",
                url(["v1", "conversations", conversationId, "acks"]),
                body: Self.encoder.encode(Ack(envelopeIds: envelopeIds))
            )
        )
    }

    public func upload(conversationId: String, ciphertext: Data) async throws -> String {
        let reserved: Upload = try await json(
            "POST", ["v1", "attachments"], body: Reserve(conversationId: conversationId, size: ciphertext.count)
        )
        var put = URLRequest(url: reserved.uploadUrl)
        put.httpMethod = "PUT"
        put.httpBody = ciphertext
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await data(put)
        return reserved.attachmentId
    }

    public func download(attachmentId: String) async throws -> Data {
        let grant: Download = try await json("GET", ["v1", "attachments", attachmentId])
        return try await data(URLRequest(url: grant.downloadUrl))
    }

    public func openStream(conversationId: String) async throws -> ChatStreamConnection {
        try await WebSocketChatStream(
            task: session.webSocketTask(with: streamRequest(conversationId: conversationId, token: token()))
        )
    }

    func streamRequest(conversationId: String, token: String) throws -> URLRequest {
        guard var parts = URLComponents(
            url: url(["v1", "conversations", conversationId, "stream"]), resolvingAgainstBaseURL: false
        ) else { throw ChatAPIError.invalidResponse }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        guard let url = parts.url else { throw ChatAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: HTTP

    private func url(_ segments: [String]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segments.reduce(baseURL) { url, segment in
            url.appending(
                path: segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? "", directoryHint: .notDirectory
            )
        }
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await request.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func json<Reply: Decodable>(_ method: String, _ path: [String]) async throws -> Reply {
        try await decode(data(request(method, url(path))))
    }

    private func json<Reply: Decodable>(
        _ method: String,
        _ path: [String],
        body: some Encodable
    ) async throws -> Reply {
        try await decode(data(request(method, url(path), body: Self.encoder.encode(body))))
    }

    private func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        do {
            return try Self.decoder.decode(Reply.self, from: data)
        } catch {
            throw ChatAPIError.invalidResponse
        }
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            var code: String?
        }

        var error: Detail?
        var missingDevices: [DeviceAddress]?
        var extraDevices: [DeviceAddress]?
        var staleDevices: [DeviceAddress]?
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) {
            return data
        }
        throw Self.error(http, try? Self.decoder.decode(ErrorReply.self, from: data))
    }

    private static func error(_ http: HTTPURLResponse, _ reply: ErrorReply?) -> ChatAPIError {
        switch http.statusCode {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .staleDevices(missing: reply?.missingDevices ?? [], extra: reply?.extraDevices ?? [])
        case 410: .staleRegistration(reply?.staleDevices ?? [])
        case 413: .tooLarge
        case 429: .rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        default: .server(status: http.statusCode, code: reply?.error?.code)
        }
    }
}

/// The conversation stream over `URLSessionWebSocketTask`.
final class WebSocketChatStream: ChatStreamConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncThrowingStream<StreamFrame, Error>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncThrowingStream<StreamFrame, Error>.makeStream()
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
                    if let frame = try? StreamFrame.decode(data) {
                        continuation.yield(frame)
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { [task] _ in task.cancel(with: .normalClosure, reason: nil) }
    }

    func frames() -> AsyncThrowingStream<StreamFrame, Error> {
        stream
    }

    func ack(_ envelopeIds: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["type": "ack", "envelopeIds": envelopeIds])
        guard let text = String(bytes: body, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
