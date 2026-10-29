import Foundation
import Testing
@testable import ZapaChat

/// One conversation on the phone: send (sealed per device), receive over the stream, store encrypted, ack.
@MainActor
struct ChatModelTests {
    let api = FakeChatAPI()
    let store = InMemoryChatStore()

    func model() -> ChatModel {
        ChatModel(me: "acc-m", api: api, sealer: PrefixSealer(), store: store)
    }

    @Test func conversationsLoadFromTheService() async {
        let chat = model()

        await chat.loadConversations()

        #expect(chat.conversations.map(\.id) == ["c_1"])
    }

    @Test func sendingTextSealsOneEnvelopePerOtherDeviceAndShowsIt() async throws {
        let chat = model()
        await chat.loadConversations()

        await chat.send(text: "  Salut!  ", in: "c_1")

        let message = try #require(chat.messages["c_1"]?.last)
        #expect(message.content.body == .text("Salut!"))
        #expect(message.status == .sent)
        let sent = try #require(api.sent.first)
        #expect(sent.envelopes.map(\.recipientDeviceId) == [1, 2], "both of the kid's devices")
        #expect(sent.envelopes.allSatisfy { $0.content.starts(with: Data("SEALED".utf8)) })
        #expect(try await store.messages(in: "c_1").count == 1)
    }

    /// Regression (staging, 2026-10-28): New chat → Start did nothing when the service refused; the error was
    /// swallowed. Now the model reports why, and a later success clears it.
    @Test(arguments: [
        (ChatAPIError.forbidden, ChatModel.StartFailure.notAllowed),
        (ChatAPIError.network, ChatModel.StartFailure.network),
        (ChatAPIError.server(status: 500, code: nil), ChatModel.StartFailure.other),
    ])
    func aFailedStartSaysWhy(error: ChatAPIError, expected: ChatModel.StartFailure) async {
        let chat = model()
        api.failNextCreate = error

        let started = await chat.start(with: ["acc-k"])

        #expect(started == nil)
        #expect(chat.startFailure == expected)
        #expect(await chat.start(with: ["acc-k"]) != nil)
        #expect(chat.startFailure == nil)
    }

    @Test func staleDevicesRefreshTheConversationAndRetryOnce() async {
        let chat = model()
        await chat.loadConversations()
        api.failNextSend = .staleDevices(missing: [DeviceAddress(accountId: "acc-k", deviceId: 3)], extra: [])
        api.devicesAfterRefresh = [1, 2, 3]

        await chat.send(text: "hi", in: "c_1")

        #expect(api.sent.last?.envelopes.map(\.recipientDeviceId) == [1, 2, 3])
        #expect(chat.messages["c_1"]?.last?.status == .sent)
    }

    @Test func aFailedSendIsMarkedSoItCanBeRetried() async {
        let chat = model()
        await chat.loadConversations()
        api.failNextSend = .network

        await chat.send(text: "hi", in: "c_1")

        #expect(chat.messages["c_1"]?.last?.status == .failed)
    }

    @Test func receivedEnvelopesAreOpenedStoredAndAcked() async throws {
        let chat = model()
        await chat.loadConversations()
        let content = ChatContent(id: "m9", sentAt: Date(timeIntervalSince1970: 9), body: .text("Pa!"))
        let envelope = try Envelope(
            id: "e9", conversationId: "c_1", messageId: "m9", senderAccountId: "acc-k", senderDeviceId: 1,
            type: .message, content: Data("SEALED".utf8) + content.encoded(), serverTimestamp: 9000
        )

        await chat.receive(envelope)
        await chat.receive(envelope)

        #expect(chat.messages["c_1"]?.map(\.id) == ["m9"], "a repeat is not shown twice")
        #expect(chat.messages["c_1"]?.first?.isMine == false)
        #expect(api.acked == ["e9", "e9"])
        #expect(chat.unread["c_1"] == 1)
    }

    @Test func anEnvelopeThatDoesntOpenIsNotShownButAcked() async {
        let chat = model()
        await chat.loadConversations()
        let envelope = Envelope(
            id: "e1", conversationId: "c_1", messageId: "m1", senderAccountId: "acc-k", senderDeviceId: 1,
            type: .message, content: Data("garbage".utf8), serverTimestamp: 1
        )

        await chat.receive(envelope)

        #expect(chat.messages["c_1"]?.isEmpty ?? true)
        #expect(api.acked == ["e1"])
    }

    @Test func photosAreEncryptedUploadedAndSentAsAPointer() async throws {
        let chat = model()
        await chat.loadConversations()
        let photo = Data(repeating: 0xAB, count: 2048)

        await chat.send(attachment: photo, kind: .image, mimeType: "image/jpeg", duration: nil, in: "c_1")

        let uploaded = try #require(api.uploads.first)
        #expect(uploaded.range(of: photo.prefix(32)) == nil, "only ciphertext leaves the phone")
        guard case let .image(pointer) = chat.messages["c_1"]?.last?.content.body else {
            Issue.record("not an image")
            return
        }
        #expect(pointer.id == "a_1")
        #expect(pointer.size == uploaded.count)
        #expect(try AttachmentCrypto.decrypt(uploaded, key: pointer.key, digest: pointer.digest) == photo)
    }

    /// Until VoIP pushes are set up, a call rings through the chat: the caller sends a sealed "call" message.
    @Test func aCallMessageRingsAndIsShownInTheChat() async throws {
        let chat = model()
        await chat.loadConversations()
        var rang: [String] = []
        chat.onIncomingCall = { callId, conversationId, caller in rang.append("\(callId) \(conversationId) \(caller)") }
        let fresh = ChatContent(id: "m5", sentAt: Date(), body: .call(callId: "call-7"))
        let stale = ChatContent(id: "m6", sentAt: Date().addingTimeInterval(-600), body: .call(callId: "call-8"))
        for content in [fresh, stale] {
            try await chat.receive(Envelope(
                id: content.id, conversationId: "c_1", messageId: content.id, senderAccountId: "acc-k",
                senderDeviceId: 1, type: .message, content: Data("SEALED".utf8) + content.encoded(),
                serverTimestamp: 0
            ))
        }

        #expect(rang == ["call-7 c_1 acc-k"], "only a call from the last minute rings")
        #expect(chat.messages["c_1"]?.count == 2, "both show in the chat as calls")
    }

    @Test func announcingACallSendsASealedCallMessage() async throws {
        let chat = model()
        await chat.loadConversations()

        await chat.announceCall("call-9", in: "c_1")

        let sent = try #require(api.sent.first?.envelopes.first?.content)
        let content = try ChatContent.decode(sent.dropFirst(6))
        #expect(content.body == .call(callId: "call-9"))
    }

    @Test func loadingConversationsConnectsEveryStream() async {
        let chat = model()
        await chat.loadConversations()
        chat.connectAll()
        #expect(chat.connectedConversations == ["c_1"])
    }

    /// ios #63: a parent who only observes their kid's chats sees them last, and can't write in them.
    @Test func observedChatsSortLastAndAreReadOnly() async {
        let chat = model()
        let observed = Conversation(id: "c_0", kind: .direct, state: .open, members: [
            ConversationMember(accountId: "acc-m", role: .observer, guardian: true, devices: []),
            ConversationMember(accountId: "acc-k", role: .kid, guardian: false, devices: []),
            ConversationMember(accountId: "acc-k2", role: .kid, guardian: false, devices: []),
        ])
        api.laterConversations = [observed, api.conversation(id: "c_2", devices: [1])]

        await chat.loadConversations()

        #expect(chat.orderedConversations.map(\.id) == ["c_1", "c_2", "c_0"])
        #expect(chat.isObserving("c_0"))
        #expect(!chat.isObserving("c_1"))
    }

    @Test func theObserverRoleDecodes() throws {
        let json = Data(#"{"accountId":"a","role":"observer","guardian":true,"devices":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ConversationMember.self, from: json).role == .observer)
    }

    @Test func markingReadClearsTheUnreadCount() async {
        let chat = model()
        await chat.loadConversations()
        chat.markRead("c_1")
        #expect(chat.unread["c_1"] == nil)
    }
}

/// Stands in for libsignal: "seals" by prefixing, opens only prefixed data.
struct PrefixSealer: MessageSealer {
    func seal(_ plaintext: Data, for conversation: Conversation, me: String) async throws -> [OutgoingEnvelope] {
        conversation.members.filter { $0.accountId != me }.flatMap { member in
            member.devices.map {
                OutgoingEnvelope(
                    recipientAccountId: member.accountId, recipientDeviceId: $0.deviceId,
                    recipientRegistrationId: $0.registrationId, type: .message, content: Data("SEALED".utf8) + plaintext
                )
            }
        }
    }

    func open(_ envelope: Envelope) async throws -> Data {
        let prefix = Data("SEALED".utf8)
        guard envelope.content.starts(with: prefix) else { throw ChatAPIError.invalidResponse }
        return envelope.content.dropFirst(prefix.count)
    }
}

final class FakeChatAPI: ChatAPI, @unchecked Sendable {
    struct Sent {
        let conversationId: String
        let messageId: String
        let envelopes: [OutgoingEnvelope]
    }

    private let lock = NSLock()
    private var sentLog: [Sent] = []
    private var ackLog: [String] = []
    private var uploadLog: [Data] = []
    var failNextSend: ChatAPIError?
    var failNextCreate: ChatAPIError?
    var devicesAfterRefresh: [Int]?

    var sent: [Sent] {
        lock.withLock { sentLog }
    }

    var acked: [String] {
        lock.withLock { ackLog }
    }

    var uploads: [Data] {
        lock.withLock { uploadLog }
    }

    var laterConversations: [Conversation] = []

    func conversation(devices: [Int]) -> Conversation {
        conversation(id: "c_1", devices: devices)
    }

    func conversation(id: String, devices: [Int]) -> Conversation {
        Conversation(id: id, kind: .direct, state: .open, members: [
            ConversationMember(
                accountId: "acc-m",
                role: .parent,
                guardian: false,
                devices: [DeviceRef(deviceId: 1, registrationId: 42)]
            ),
            ConversationMember(
                accountId: "acc-k",
                role: .kid,
                guardian: false,
                devices: devices.map { DeviceRef(deviceId: $0, registrationId: 6 + $0) }
            ),
        ])
    }

    func conversations() async throws -> [Conversation] {
        [conversation(devices: [1, 2])] + laterConversations
    }

    func conversation(id _: String) async throws -> Conversation {
        conversation(devices: devicesAfterRefresh ?? [1, 2])
    }

    func createConversation(members _: [String]) async throws -> Conversation {
        let failure: ChatAPIError? = lock.withLock {
            defer { failNextCreate = nil }
            return failNextCreate
        }
        if let failure {
            throw failure
        }
        return conversation(devices: [1, 2])
    }

    func send(conversationId: String, messageId: String, envelopes: [OutgoingEnvelope]) async throws -> Date {
        let failure: ChatAPIError? = lock.withLock {
            defer { failNextSend = nil }
            return failNextSend
        }
        if let failure {
            throw failure
        }
        lock
            .withLock {
                sentLog.append(Sent(conversationId: conversationId, messageId: messageId, envelopes: envelopes))
            }
        return Date(timeIntervalSince1970: 100)
    }

    func fetch(conversationId _: String) async throws -> EnvelopePage {
        EnvelopePage(envelopes: [], more: false)
    }

    func ack(conversationId _: String, envelopeIds: [String]) async throws {
        lock.withLock { ackLog += envelopeIds }
    }

    func upload(conversationId _: String, ciphertext: Data) async throws -> String {
        lock.withLock { uploadLog.append(ciphertext) }
        return "a_1"
    }

    func download(attachmentId _: String) async throws -> Data {
        lock.withLock { uploadLog.last ?? Data() }
    }

    func openStream(conversationId _: String) async throws -> ChatStreamConnection {
        throw ChatAPIError.network
    }
}
