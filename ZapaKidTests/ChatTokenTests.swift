import Foundation
import Testing
@testable import ZapaKidKit

/// The short-lived chat token (ES256, ≤ 15 min) for the chat and calls services: fetched with the session,
/// reused until a minute before it expires.
@Suite(.serialized)
struct ChatTokenTests {
    let host = "token.test.invalid"

    @Test func theTokenIsFetchedOnceAndReusedUntilItNearlyExpires() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let clock = Clock(now)
        let session = MockURLProtocol.session(host: host) { _, _ in
            MockReply(
                200,
                #"{"token":"jwt-\#(Int(clock.now.timeIntervalSince1970))","expiresAt":"1970-01-01T00:26:40Z"}"#
            )
        }
        let provider = ChatTokenProvider(
            api: HTTPChatTokenAPI(baseURL: URL(string: "https://\(host)") ?? URL(filePath: "/"), session: session),
            session: { "zks_t" }, now: { clock.now }
        )

        let first = try await provider.token()
        clock.now += 500
        let second = try await provider.token()
        clock.now += 60
        let third = try await provider.token()
        let issued = MockURLProtocol.requests(host: host).count

        #expect(first == "jwt-1000")
        #expect(second == first)
        #expect(third == "jwt-1560", "within a minute of expiry it fetches a new one")
        #expect(issued == 2)
        let request = try #require(MockURLProtocol.requests(host: host).first?.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/chat/token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_t")
    }

    @Test func noSessionNoToken() async {
        let provider = ChatTokenProvider(
            api: HTTPChatTokenAPI(baseURL: URL(string: "https://\(host)") ?? URL(filePath: "/")),
            session: { nil }
        )
        await #expect(throws: AuthAPIError.unauthorized) { _ = try await provider.token() }
    }

    final class Clock: @unchecked Sendable {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }
}
