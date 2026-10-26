import Foundation

/// Answers URLSession requests in tests, so the real HTTP client runs against a fake API (no network).
/// Suites that use it are `.serialized`: there is one handler at a time.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (Int, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var recorded: [(URLRequest, Data?)] = []

    /// A session whose requests go to `handler` instead of the network.
    static func session(_ handler: @escaping Handler) -> URLSession {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static var requests: [(request: URLRequest, body: Data?)] {
        lock.withLock { recorded.map { (request: $0.0, body: $0.1) } }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let handler = Self.lock.withLock {
            Self.recorded.append((request, body))
            return Self.handler
        }
        do {
            guard let handler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request, body)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: data)
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
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension Data {
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] }
}
