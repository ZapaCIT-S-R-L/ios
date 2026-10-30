import Foundation
import Observation
import os

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
    /// Call results whose call message hasn't arrived yet.
    private var pendingCallResults: [String: CallResult] = [:]
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
        case video
        case document
    }

    // MARK: Conversations

    public func loadConversations() async {
        do {
            conversations = try await api.conversations()
            let loaded = conversations.count
            Logger(subsystem: "ro.zapakid.app", category: "chats").info(
                "loaded \(loaded, privacy: .public) conversations"
            )
            for conversation in conversations where messages[conversation.id] == nil {
                do {
                    messages[conversation.id] = try await store.messages(in: conversation.id)
                } catch {
                    Logger(subsystem: "ro.zapakid.app", category: "chat-store").error(
                        "reading history failed: \(String(describing: error), privacy: .public)"
                    )
                    messages[conversation.id] = []
                }
            }
        } catch {
            Logger(subsystem: "ro.zapakid.app", category: "chats").error(
                "loading conversations failed: \(String(describing: error), privacy: .public)"
            )
            errorMessage = String(describing: error)
        }
        connectAll()
    }

    /// Removes this account from a conversation: the service drops the membership, and this phone forgets it,
    /// including its history. The other members keep the chat.
    public func leave(_ conversationId: String) async {
        do {
            try await api.leave(conversationId: conversationId)
        } catch {
            Logger(subsystem: "ro.zapakid.app", category: "chats").error(
                "leaving a conversation failed: \(String(describing: error), privacy: .public)"
            )
            errorMessage = String(describing: error)
            return
        }
        disconnect(conversationId)
        conversations.removeAll { $0.id == conversationId }
        messages[conversationId] = nil
        unread[conversationId] = nil
        try? await store.delete(conversationId)
    }

    /// Why the last `start(with:)` failed (nil after a success), for the New chat screen.
    public enum StartFailure: Equatable, Sendable {
        /// The family rules don't allow these members together (403).
        case notAllowed
        case network
        case other
    }

    public private(set) var startFailure: StartFailure?

    /// Starts (or finds) a conversation with these accounts. On failure returns nil and sets `startFailure`.
    public func start(with members: [String]) async -> Conversation? {
        let conversation: Conversation
        do {
            conversation = try await api.createConversation(members: members)
        } catch {
            startFailure = switch error as? ChatAPIError {
            case .forbidden: .notAllowed
            case .network: .network
            default: .other
            }
            return nil
        }
        startFailure = nil
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

    /// How a call ended on this phone: kept on its call message in the history. If that message hasn't arrived yet,
    /// it is kept until it does.
    public func recordCallResult(callId: String, result: CallResult) async {
        var found = false
        for (conversationId, list) in messages {
            guard let index = list.firstIndex(where: { message in
                if case let .call(id) = message.content.body {
                    return id == callId
                }
                return false
            }) else { continue }
            var updated = list
            updated[index].callResult = result
            messages[conversationId] = updated
            await persist(conversationId)
            found = true
        }
        if !found {
            pendingCallResults[callId] = result
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
        attachment plaintext: Data, kind: AttachmentKind, mimeType: String, duration: Double?, fileName: String? = nil,
        in conversationId: String
    ) async {
        do {
            let sealed = try AttachmentCrypto.encrypt(plaintext)
            let id = try await api.upload(conversationId: conversationId, ciphertext: sealed.ciphertext)
            let pointer = AttachmentPointer(
                id: id, key: sealed.key, digest: sealed.digest, size: sealed.ciphertext.count, mimeType: mimeType,
                duration: duration
            )
            let body: ChatContent.Body = switch kind {
            case .image: .image(pointer)
            case .voice: .voice(pointer)
            case .video: .video(pointer)
            case .document: .document(pointer, name: fileName ?? "file")
            }
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

    /// Sends a body that has no attachment (a contact card, a location).
    public func send(body: ChatContent.Body, in conversationId: String) async {
        await deliver(ChatContent(id: UUID().uuidString.lowercased(), sentAt: Date(), body: body), in: conversationId)
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
}

// MARK: Receiving

extension ChatModel {
    /// Opens the conversation's live stream (and fetches what queued while away).
    public func connect(_ conversationId: String) {
        guard streams[conversationId] == nil else { return }
        // Keeps the stream open for as long as the conversation is connected: when it drops (network, sleep, the
        // server closing it), it reopens with a growing pause, so new messages keep arriving without a refresh.
        streams[conversationId] = Task { [weak self, api] in
            var pause: UInt64 = 1
            while !Task.isCancelled {
                if let page = try? await api.fetch(conversationId: conversationId) {
                    for envelope in page.envelopes {
                        await self?.receive(envelope)
                    }
                }
                if let stream = try? await api.openStream(conversationId: conversationId) {
                    pause = 1
                    do {
                        for try await frame in stream.frames() {
                            await self?.handle(frame, in: conversationId)
                        }
                    } catch {}
                }
                if Task.isCancelled {
                    break
                }
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 2, 30)
            }
        }
    }

    private func handle(_ frame: StreamFrame, in conversationId: String) async {
        switch frame {
        case let .envelope(envelope): await receive(envelope)
        case .event: await refresh(conversationId)
        case .other: break
        }
    }

    public func disconnect(_ conversationId: String) {
        streams.removeValue(forKey: conversationId)?.cancel()
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
        var message = ChatMessage(
            id: content.id, conversationId: conversationId, senderAccountId: envelope.senderAccountId,
            isMine: false, content: content, status: .received
        )
        if case let .call(callId) = content.body {
            message.callResult = pendingCallResults.removeValue(forKey: callId)
        }
        upsert(message)
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
