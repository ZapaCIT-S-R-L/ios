import Foundation

/// The connection calls over HTTP (`/v1/connections*`, per openapi.yaml in zapakid-api).
public struct HTTPConnectionsAPI: ConnectionsAPI {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = URLSession(configuration: HTTPAuthAPI.secureConfiguration())) {
        self.baseURL = baseURL
        self.session = session
    }

    public static var staging: HTTPConnectionsAPI {
        // swiftlint:disable:next force_unwrapping
        HTTPConnectionsAPI(baseURL: URL(string: ZapaKidKit.apiBaseURL)!)
    }

    private struct Connections: Decodable {
        var connections: [Connection]
    }

    private struct Invitation: Decodable {
        var code: String
        var expiresAt: Date
    }

    /// `{ "error": { "code": ... } }`, as the API answers errors.
    private struct ErrorReply: Decodable {
        struct Body: Decodable {
            var code: String?
        }

        var error: Body?
    }

    private struct AcceptBody: Encodable {
        var code: String
    }

    public func list(token: String) async throws -> [Connection] {
        let reply: Connections = try await send("GET", ["v1", "connections"], token: token, body: NoBody?.none)
        return reply.connections
    }

    public func invite(token: String) async throws -> ConnectionInvitation {
        let reply: Invitation = try await send(
            "POST", ["v1", "connections", "invitations"], token: token, body: NoBody?.none
        )
        return ConnectionInvitation(code: reply.code, expiresAt: reply.expiresAt)
    }

    public func accept(code: String, token: String) async throws -> Connection {
        try await send("POST", ["v1", "connections", "accept"], token: token, body: AcceptBody(code: code))
    }

    public func share(connectionId: String, kidId: String, token: String) async throws {
        let _: EmptyReply = try await send(
            "PUT", ["v1", "connections", connectionId, "shared-kids", kidId], token: token, body: NoBody?.none
        )
    }

    public func unshare(connectionId: String, kidId: String, token: String) async throws {
        let _: EmptyReply = try await send(
            "DELETE", ["v1", "connections", connectionId, "shared-kids", kidId], token: token, body: NoBody?.none
        )
    }

    public func remove(connectionId: String, token: String) async throws {
        let _: EmptyReply = try await send(
            "DELETE",
            ["v1", "connections", connectionId],
            token: token,
            body: NoBody?.none
        )
    }

    private struct NoBody: Encodable {}

    /// For 204 answers: nothing to decode.
    private struct EmptyReply: Decodable {
        init() {}

        init(from decoder: Decoder) throws {}
    }

    private func url(_ segments: [String]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segments.reduce(baseURL) { url, segment in
            url.appending(path: segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment)
        }
    }

    private func send<Reply: Decodable>(
        _ method: String, _ path: [String], token: String, body: (some Encodable)?
    ) async throws -> Reply {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FamiliesAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw FamiliesAPIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error?.code
            throw HTTPFamiliesAPI.error(
                status: http.statusCode, code: code, retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        if data.isEmpty, let empty = EmptyReply() as? Reply {
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date
            }
            if let date = ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return try decoder.decode(Reply.self, from: data)
    }
}
