import Foundation

/// What the fake API answers.
struct MockReply {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]

    init(_ status: Int, _ body: String = "", headers: [String: String] = [:]) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
    }
}

/// Answers URLSession requests in tests, so the real HTTP client runs against a fake API (no network).
/// One handler per host, so suites for different APIs (api.test.invalid, calls.test.invalid) can run in parallel;
/// suites that use it are `.serialized`: there is one handler per host at a time.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> MockReply

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    private nonisolated(unsafe) static var recorded: [(URLRequest, Data?)] = []

    /// A session whose requests to `host` go to `handler` instead of the network.
    static func session(host: String = "api.test.invalid", _ handler: @escaping Handler) -> URLSession {
        lock.withLock {
            handlers[host] = handler
            recorded.removeAll { $0.0.url?.host == host }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// The requests to the API host (api.test.invalid).
    static var requests: [(request: URLRequest, body: Data?)] {
        requests(host: "api.test.invalid")
    }

    static func requests(host: String) -> [(request: URLRequest, body: Data?)] {
        lock.withLock { recorded.filter { $0.0.url?.host == host }.map { (request: $0.0, body: $0.1) } }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let handler = Self.lock.withLock {
            Self.recorded.append((request, body))
            return request.url?.host.flatMap { Self.handlers[$0] }
        }
        do {
            guard let handler, let url = request.url else { throw URLError(.badServerResponse) }
            let reply = try handler(request, body)
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(reply.headers) { $1 }
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension Data {
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}
