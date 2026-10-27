import Foundation

/// An encrypted attachment's pointer, travelling only inside the sealed message: the server never sees the key.
public struct AttachmentPointer: Codable, Sendable, Equatable {
    public var id: String
    public var key: Data
    /// SHA-256 of the ciphertext.
    public var digest: Data
    /// Ciphertext size in bytes.
    public var size: Int
    public var mimeType: String
    /// Voice messages: seconds.
    public var duration: Double?

    public init(id: String, key: Data, digest: Data, size: Int, mimeType: String, duration: Double?) {
        self.id = id
        self.key = key
        self.digest = digest
        self.size = size
        self.mimeType = mimeType
        self.duration = duration
    }
}

/// The plaintext inside a sealed message (version 1, JSON). Same layout on Android.
public struct ChatContent: Codable, Sendable, Equatable {
    public enum Body: Codable, Sendable, Equatable {
        case text(String)
        case image(AttachmentPointer)
        case voice(AttachmentPointer)
        /// "I'm calling you": rings the others while VoIP pushes aren't set up, and shows in the chat as a call.
        case call(callId: String)
    }

    public static let version = 1
    public static let maxTextLength = 4000

    public var formatVersion = ChatContent.version
    public var id: String
    public var sentAt: Date
    public var body: Body

    public init(id: String, sentAt: Date, body: Body) {
        self.id = id
        self.sentAt = sentAt
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "v"
        case id, sentAt, body
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ChatContent {
        let content = try decoder.decode(ChatContent.self, from: data)
        guard content.formatVersion == version else { throw ChatAPIError.invalidResponse }
        return content
    }

    public static func isValidText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxTextLength
    }
}
