import Foundation

/// The chat service (chat.zapakid.ro, `services/chat` in zapakid-api, see its openapi.yaml).
public protocol ChatAPI: Sendable {
    func conversations() async throws -> [Conversation]
    func conversation(id: String) async throws -> Conversation
    /// `members`: the other accounts (not the caller). One account → direct.
    func createConversation(members: [String]) async throws -> Conversation
    /// Returns the server timestamp.
    func send(conversationId: String, messageId: String, envelopes: [OutgoingEnvelope]) async throws -> Date
    func fetch(conversationId: String) async throws -> EnvelopePage
    func ack(conversationId: String, envelopeIds: [String]) async throws
    /// Reserves and uploads an encrypted attachment; returns its id.
    func upload(conversationId: String, ciphertext: Data) async throws -> String
    func download(attachmentId: String) async throws -> Data
    func openStream(conversationId: String) async throws -> ChatStreamConnection
}

public protocol ChatStreamConnection: Sendable {
    func frames() -> AsyncThrowingStream<StreamFrame, Error>
    func ack(_ envelopeIds: [String]) async throws
    func close()
}

/// A text frame from the conversation stream.
public enum StreamFrame: Sendable, Equatable {
    case envelope(Envelope)
    case event(kind: String, conversationId: String)
    case other

    private struct Frame: Decodable {
        struct Event: Decodable {
            var kind: String
            var conversationId: String
        }

        var type: String
        var envelope: Envelope?
        var event: Event?
    }

    public static func decode(_ data: Data) throws -> StreamFrame {
        let frame = try HTTPChatAPI.decoder.decode(Frame.self, from: data)
        switch frame.type {
        case "envelope":
            guard let envelope = frame.envelope else { throw ChatAPIError.invalidResponse }
            return .envelope(envelope)
        case "event":
            guard let event = frame.event else { throw ChatAPIError.invalidResponse }
            return .event(kind: event.kind, conversationId: event.conversationId)
        default:
            return .other
        }
    }
}
