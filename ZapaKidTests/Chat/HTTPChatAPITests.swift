import Foundation
import Testing
@testable import ZapaChat

/// The chat client against a mocked chat service (chat.zapakid.ro), per services/chat/openapi.yaml in zapakid-api.
/// The service only ever sees libsignal ciphertext and routing metadata.
@Suite(.serialized)
struct HTTPChatAPITests {
    let host = "chat.test.invalid"
    let conversationJSON = """
    {"id":"c_AAAAAAAAAAAAAAAAAAAAAA","kind":"direct","state":"open","createdAt":"2026-10-27T18:00:00Z",\
    "closedAt":null,"members":[{"accountId":"acc-m","role":"parent","guardian":false,\
    "devices":[{"deviceId":1,"registrationId":42}]},{"accountId":"acc-k","role":"kid","guardian":false,\
    "devices":[{"deviceId":1,"registrationId":7},{"deviceId":2,"registrationId":8}]}]}
    """

    func api(_ handler: @escaping MockURLProtocol.Handler) -> HTTPChatAPI {
        HTTPChatAPI(
            baseURL: URL(string: "https://\(host)") ?? URL(filePath: "/"),
            session: MockURLProtocol.session(host: host, handler), token: { "chat-token" }
        )
    }

    var sent: [(request: URLRequest, body: Data?)] {
        MockURLProtocol.requests(host: host)
    }

    @Test func conversationsListWithMembersAndDevices() async throws {
        let client = api { [conversationJSON] _, _ in MockReply(200, #"{"conversations":[\#(conversationJSON)]}"#) }

        let list = try await client.conversations()

        #expect(list.first?.kind == .direct)
        #expect(list.first?.members.last?.devices.map(\.deviceId) == [1, 2])
        #expect(sent.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer chat-token")
    }

    @Test func createSendsOnlyTheOtherMembers() async throws {
        let client = api { [conversationJSON] _, _ in MockReply(201, conversationJSON) }

        _ = try await client.createConversation(members: ["acc-k"])

        #expect(sent.first?.request.url?.path == "/v1/conversations")
        #expect(sent.first?.body?.json?["members"] as? [String] == ["acc-k"])
    }

    @Test func sendPostsOneEnvelopePerDevice() async throws {
        let client = api { _, _ in MockReply(202, #"{"messageId":"m1","serverTimestamp":1793120000000}"#) }
        let envelopes = [
            OutgoingEnvelope(
                recipientAccountId: "acc-k",
                recipientDeviceId: 1,
                recipientRegistrationId: 7,
                type: .message,
                content: Data([1, 2])
            ),
        ]

        let stamp = try await client.send(conversationId: "c_1", messageId: "m1", envelopes: envelopes)

        #expect(stamp == Date(timeIntervalSince1970: 1_793_120_000))
        let body = try #require(sent.first?.body?.json)
        #expect(body["messageId"] as? String == "m1")
        let first = try #require((body["envelopes"] as? [[String: Any]])?.first)
        #expect(first["type"] as? String == "message")
        #expect(first["content"] as? String == "AQI=")
        #expect(first["recipientRegistrationId"] as? Int == 7)
    }

    @Test func staleDevicesComeBackWithWhatIsMissing() async {
        let client = api { _, _ in
            MockReply(409, """
            {"error":{"code":"stale_devices"},"missingDevices":[{"accountId":"acc-k","deviceId":3}],"extraDevices":[]}
            """)
        }

        await #expect(throws: ChatAPIError.staleDevices(
            missing: [DeviceAddress(accountId: "acc-k", deviceId: 3)],
            extra: []
        )) {
            _ = try await client.send(conversationId: "c_1", messageId: "m1", envelopes: [])
        }
    }

    @Test func fetchAndAck() async throws {
        let client = api { request, _ in
            if request.httpMethod == "GET" {
                return MockReply(200, """
                {"envelopes":[{"id":"e1","conversationId":"c_1","messageId":"m1","senderAccountId":"acc-m",\
                "senderDeviceId":1,"type":"prekey_message","content":"AQI=","serverTimestamp":1793120000000}],\
                "more":false}
                """)
            }
            return MockReply(204)
        }

        let page = try await client.fetch(conversationId: "c_1")
        try await client.ack(conversationId: "c_1", envelopeIds: ["e1"])

        #expect(page.envelopes.first?.content == Data([1, 2]))
        #expect(page.envelopes.first?.type == .prekeyMessage)
        #expect(sent.last?.request.url?.path == "/v1/conversations/c_1/acks")
        #expect(sent.last?.body?.json?["envelopeIds"] as? [String] == ["e1"])
    }

    @Test func attachmentsUploadToTheOneTimeURLWithoutAuthorization() async throws {
        let client = api { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/attachments"):
                MockReply(201, """
                {"attachmentId":"a_1","uploadUrl":"https://\(host)/v1/attachments/a_1/upload?t=x",\
                "expiresAt":"2026-10-27T18:15:00Z"}
                """)
            case ("GET", "/v1/attachments/a_1"):
                MockReply(200, """
                {"attachmentId":"a_1","size":3,"downloadUrl":"https://\(host)/v1/attachments/a_1/download?t=y",\
                "expiresAt":"2026-10-27T18:15:00Z"}
                """)
            case ("GET", _): MockReply(200, "abc")
            default: MockReply(204)
            }
        }

        let id = try await client.upload(conversationId: "c_1", ciphertext: Data("abc".utf8))
        let data = try await client.download(attachmentId: id)

        #expect(id == "a_1")
        #expect(data == Data("abc".utf8))
        let put = try #require(sent.first { $0.request.httpMethod == "PUT" })
        #expect(put.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(put.body == Data("abc".utf8))
        #expect(sent.first?.body?.json?["size"] as? Int == 3)
    }

    @Test func streamUsesWSS() throws {
        let client = HTTPChatAPI(baseURL: URL(string: "https://\(host)") ?? URL(filePath: "/"), token: { "t" })

        let request = try client.streamRequest(conversationId: "c_1", token: "chat-token")

        #expect(request.url?.absoluteString == "wss://\(host)/v1/conversations/c_1/stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer chat-token")
    }

    @Test func streamFramesDecode() throws {
        let envelope = try StreamFrame.decode(Data("""
        {"type":"envelope","envelope":{"id":"e1","conversationId":"c_1","messageId":"m1","senderAccountId":"a",\
        "senderDeviceId":1,"type":"message","content":"AQI=","serverTimestamp":1}}
        """.utf8))
        let event = try StreamFrame
            .decode(Data(#"{"type":"event","event":{"kind":"devices_changed","conversationId":"c_1"}}"#.utf8))

        guard case let .envelope(got) = envelope else { Issue.record("no envelope"); return }
        #expect(got.id == "e1")
        #expect(event == .event(kind: "devices_changed", conversationId: "c_1"))
        #expect(try StreamFrame.decode(Data(#"{"type":"pong"}"#.utf8)) == .other)
    }
}
