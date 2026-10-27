import Foundation
import Observation

/// The chats on this phone: conversations from the service, messages sealed per device on send, opened, stored
/// encrypted and acknowledged on receive.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var conversations: [Conversation] = []
    public private(set) var messages: [String: [ChatMessage]] = [:]
    public private(set) var unread: [String: Int] = [:]
    public private(set) var errorMessage: String?

    public let me: String
    private let api: ChatAPI
    private let sealer: MessageSealer
    private let store: ChatStore
    private var streams: [String: Task<Void, Never>] = [:]
    /// A call message from the last minute arrived: (callId, conversationId, caller account).
    public var onIncomingCall: ((String, String, String) -> Void)?

    public var connectedConversations: [String] {
        streams.keys.sorted()
    }

    public init(me: String, api: ChatAPI, sealer: MessageSealer, store: ChatStore) {
        self.me = me
        self.api = api
        self.sealer = sealer
        self.store = store
    }

    public enum AttachmentKind: Sendable {
        case image
        case voice
    }

    // MARK: Conversations

    public func loadConversations() async {
        do {
            conversations = try await api.conversations()
            for conversation in conversations where messages[conversation.id] == nil {
                messages[conversation.id] = await (try? store.messages(in: conversation.id)) ?? []
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Starts (or finds) a conversation with these accounts.
    public func start(with members: [String]) async -> Conversation? {
        guard let conversation = try? await api.createConversation(members: members) else { return nil }
        if !conversations.contains(where: { $0.id == conversation.id }) {
            conversations.insert(conversation, at: 0)
            messages[conversation.id] = []
        }
        return conversation
    }

    /// Keeps every conversation's stream open, so messages and call rings arrive while the app is open.
    public func connectAll() {
        for conversation in conversations where conversation.state == .open {
            connect(conversation.id)
        }
    }

    /// Tells the others in the conversation that this phone is calling (sealed like any message).
    public func announceCall(_ callId: String, in conversationId: String) async {
        await deliver(
            ChatContent(id: UUID().uuidString.lowercased(), sentAt: Date(), body: .call(callId: callId)),
            in: conversationId
        )
    }

    public func markRead(_ conversationId: String) {
        unread[conversationId] = nil
    }

    // MARK: Sending

    public func send(text: String, in conversationId: String) async {
        guard ChatContent.isValidText(text) else { return }
        let content = ChatContent(
            id: UUID().uuidString.lowercased(), sentAt: Date(),
            body: .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        await deliver(content, in: conversationId)
    }

    public func send(
        attachment plaintext: Data, kind: AttachmentKind, mimeType: String, duration: Double?, in conversationId: String
    ) async {
        do {
            let sealed = try AttachmentCrypto.encrypt(plaintext)
            let id = try await api.upload(conversationId: conversationId, ciphertext: sealed.ciphertext)
            let pointer = AttachmentPointer(
                id: id, key: sealed.key, digest: sealed.digest, size: sealed.ciphertext.count, mimeType: mimeType,
                duration: duration
            )
            let body: ChatContent.Body = kind == .image ? .image(pointer) : .voice(pointer)
            await deliver(
                ChatContent(id: UUID().uuidString.lowercased(), sentAt: Date(), body: body),
                in: conversationId
            )
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// The decrypted bytes of an attachment.
    public func attachmentData(_ pointer: AttachmentPointer) async throws -> Data {
        try await AttachmentCrypto.decrypt(
            api.download(attachmentId: pointer.id),
            key: pointer.key,
            digest: pointer.digest
        )
    }

    public func retry(_ message: ChatMessage) async {
        guard message.isMine, message.status == .failed else { return }
        await deliver(message.content, in: message.conversationId)
    }

    private func deliver(_ content: ChatContent, in conversationId: String) async {
        var message = ChatMessage(
            id: content.id, conversationId: conversationId, senderAccountId: me, isMine: true, content: content,
            status: .sending
        )
        upsert(message)
        do {
            let plaintext = try content.encoded()
            do {
                try await sendSealed(plaintext, messageId: content.id, in: conversationId)
            } catch ChatAPIError.staleDevices, ChatAPIError.staleRegistration {
                // Someone added or re-installed a phone: refresh the devices and seal again, once.
                let fresh = try await api.conversation(id: conversationId)
                replace(fresh)
                try await sendSealed(plaintext, messageId: content.id, in: conversationId)
            }
            message.status = .sent
        } catch {
            message.status = .failed
        }
        upsert(message)
        await persist(conversationId)
    }

    private func sendSealed(_ plaintext: Data, messageId: String, in conversationId: String) async throws {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw ChatAPIError.notFound
        }
        let envelopes = try await sealer.seal(plaintext, for: conversation, me: me)
        _ = try await api.send(conversationId: conversationId, messageId: messageId, envelopes: envelopes)
    }

    // MARK: Receiving

    /// Opens the conversation's live stream (and fetches what queued while away).
    public func connect(_ conversationId: String) {
        guard streams[conversationId] == nil else { return }
        streams[conversationId] = Task { [weak self, api] in
            if let page = try? await api.fetch(conversationId: conversationId) {
                for envelope in page.envelopes {
                    await self?.receive(envelope)
                }
            }
            guard let stream = try? await api.openStream(conversationId: conversationId) else { return }
            do {
                for try await frame in stream.frames() {
                    switch frame {
                    case let .envelope(envelope): await self?.receive(envelope)
                    case .event: await self?.refresh(conversationId)
                    case .other: break
                    }
                }
            } catch {}
            await self?.dropStream(conversationId)
        }
    }

    public func disconnect(_ conversationId: String) {
        streams.removeValue(forKey: conversationId)?.cancel()
    }

    private func dropStream(_ conversationId: String) {
        streams[conversationId] = nil
    }

    private func refresh(_ conversationId: String) async {
        if let fresh = try? await api.conversation(id: conversationId) {
            replace(fresh)
        }
    }

    /// An envelope for this device. Anything that doesn't open is dropped (never shown) but still acknowledged.
    public func receive(_ envelope: Envelope) async {
        await show(envelope)
        try? await api.ack(conversationId: envelope.conversationId, envelopeIds: [envelope.id])
    }

    private func show(_ envelope: Envelope) async {
        guard let plaintext = try? await sealer.open(envelope), let content = try? ChatContent.decode(plaintext) else {
            return
        }
        let conversationId = envelope.conversationId
        guard !(messages[conversationId] ?? []).contains(where: { $0.id == content.id }) else { return }
        upsert(ChatMessage(
            id: content.id, conversationId: conversationId, senderAccountId: envelope.senderAccountId,
            isMine: false, content: content, status: .received
        ))
        unread[conversationId, default: 0] += 1
        await persist(conversationId)
        if case let .call(callId) = content.body, abs(content.sentAt.timeIntervalSinceNow) < 60 {
            onIncomingCall?(callId, conversationId, envelope.senderAccountId)
        }
    }

    // MARK: Helpers

    private func upsert(_ message: ChatMessage) {
        var list = messages[message.conversationId] ?? []
        if let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
        } else {
            list.append(message)
        }
        messages[message.conversationId] = list
    }

    private func replace(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        }
    }

    private func persist(_ conversationId: String) async {
        try? await store.save(messages[conversationId] ?? [], in: conversationId)
    }
}
