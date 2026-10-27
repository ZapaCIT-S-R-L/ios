import Foundation
import Testing
@testable import ZapaCalls

/// The calls client against a mocked calls service (calls.zapakid.ro), per the calls API in the voice-calls brief
/// (to be aligned with services/calls/openapi.yaml in zapakid-api once it lands). Every request carries the
/// short-lived chat token; the Cloudflare app secret never reaches the phone.
@Suite(.serialized)
struct HTTPCallsAPITests {
    let base = URL(string: "https://calls.test.invalid")!
    let grantJSON = """
    {"callId":"c_1","iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},\
    {"urls":["turn:turn.cloudflare.com:3478?transport=udp"],"username":"u","credential":"p"}]}
    """

    func api(_ handler: @escaping MockURLProtocol.Handler) -> HTTPCallsAPI {
        HTTPCallsAPI(
            baseURL: base,
            session: MockURLProtocol.session(host: "calls.test.invalid", handler),
            token: { "chat-token" }
        )
    }

    @Test func createCallSendsTheConversationAndReturnsIceServers() async throws {
        let client = api { [grantJSON] _, _ in MockReply(201, grantJSON) }

        let grant = try await client.createCall(conversationId: "conv-1")

        #expect(grant.callId == "c_1")
        #expect(grant.iceServers.count == 2)
        #expect(grant.iceServers[1].username == "u")
        let sent = try #require(MockURLProtocol.requests(host: "calls.test.invalid").first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://calls.test.invalid/v1/calls")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer chat-token")
        #expect(sent.body?.json?["conversationId"] as? String == "conv-1")
    }

    @Test func joinLeaveAndDeclineUseTheCallPaths() async throws {
        let client = api { [grantJSON] _, _ in MockReply(200, grantJSON) }

        _ = try await client.join(callId: "c_1")
        try await client.leave(callId: "c_1")
        try await client.decline(callId: "c_1")

        let paths = MockURLProtocol.requests(host: "calls.test.invalid")
            .map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
        #expect(paths == ["POST /v1/calls/c_1/join", "POST /v1/calls/c_1/leave", "POST /v1/calls/c_1/decline"])
    }

    @Test func callIdsArePathEscaped() async throws {
        let client = api { _, _ in MockReply(204) }

        try await client.leave(callId: "../admin")

        #expect(MockURLProtocol.requests(host: "calls.test.invalid").first?.request.url?.absoluteString ==
            "https://calls.test.invalid/v1/calls/..%2Fadmin/leave")
    }

    @Test func realtimeProxyPublishesAndSubscribesWithCloudflareShapes() async throws {
        let client = api { request, _ in
            switch request.url?.path {
            case "/v1/calls/c_1/rtc/sessions/new": MockReply(201, #"{"sessionId":"s_me"}"#)
            default: MockReply(200, """
                {"requiresImmediateRenegotiation":false,"sessionDescription":{"type":"answer","sdp":"v=0 answer"},\
                "tracks":[{"mid":"0","trackName":"audio-dev-a","sessionId":"s_me"}]}
                """)
            }
        }

        let session = try await client.newSession(callId: "c_1")
        let reply = try await client.addTracks(callId: "c_1", sessionId: session, request: TracksRequest(
            sessionDescription: SessionDescription(type: .offer, sdp: "v=0 offer"),
            tracks: [TrackObject(location: .local, mid: "0", trackName: "audio-dev-a")]
        ))
        try await client.renegotiate(
            callId: "c_1", sessionId: session, answer: SessionDescription(type: .answer, sdp: "v=0 answer2")
        )
        _ = try await client.closeTracks(callId: "c_1", sessionId: session, mids: ["0"])

        #expect(session == "s_me")
        #expect(reply.sessionDescription?.sdp == "v=0 answer")
        #expect(reply.tracks?.first?.trackName == "audio-dev-a")
        let sent = MockURLProtocol.requests(host: "calls.test.invalid")
        #expect(sent.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" } == [
            "POST /v1/calls/c_1/rtc/sessions/new",
            "POST /v1/calls/c_1/rtc/sessions/s_me/tracks/new",
            "PUT /v1/calls/c_1/rtc/sessions/s_me/renegotiate",
            "PUT /v1/calls/c_1/rtc/sessions/s_me/tracks/close",
        ])
        let tracks = try #require(sent[1].body?.json)
        #expect((tracks["sessionDescription"] as? [String: Any])?["type"] as? String == "offer")
        #expect(((tracks["tracks"] as? [[String: Any]])?.first)?["location"] as? String == "local")
        let close = try #require(sent[3].body?.json)
        #expect((close["tracks"] as? [[String: Any]])?.first?["mid"] as? String == "0")
    }

    @Test(arguments: [
        (401, "invalid_token", CallsAPIError.unauthorized),
        (403, "conversation_not_allowed", CallsAPIError.notAllowed),
        (404, "not_found", CallsAPIError.callNotFound),
        (409, "call_full", CallsAPIError.callFull),
        (410, "call_ended", CallsAPIError.callEnded),
        (403, "session_not_yours", CallsAPIError.notAllowed),
        (500, "internal", CallsAPIError.server(status: 500, code: "internal")),
    ])
    func errorsMapByCode(status: Int, code: String, expected: CallsAPIError) async {
        let client = api { _, _ in MockReply(status, #"{"error":{"code":"\#(code)","message":"x"}}"#) }

        await #expect(throws: expected) { _ = try await client.createCall(conversationId: "conv-1") }
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let client = api { _, _ in
            MockReply(429, #"{"error":{"code":"rate_limited"}}"#, headers: ["Retry-After": "12"])
        }

        await #expect(throws: CallsAPIError.rateLimited(retryAfter: 12)) {
            _ = try await client.join(callId: "c_1")
        }
    }

    @Test func eventsSocketURLUsesWSSAndTheCallPath() throws {
        let client = HTTPCallsAPI(baseURL: base, token: { "t" })

        let request = try client.eventsRequest(callId: "c_1", token: "chat-token")

        #expect(request.url?.absoluteString == "wss://calls.test.invalid/v1/calls/c_1/events")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer chat-token")
    }
}
