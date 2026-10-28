import CryptoKit
import Foundation

/// A message on this phone.
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case sending
        case sent
        case failed
        case received
    }

    public var id: String
    public var conversationId: String
    public var senderAccountId: String
    public var isMine: Bool
    public var content: ChatContent
    public var status: Status

    public init(
        id: String, conversationId: String, senderAccountId: String, isMine: Bool, content: ChatContent,
        status: Status
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderAccountId = senderAccountId
        self.isMine = isMine
        self.content = content
        self.status = status
    }
}

/// The chat history on the phone (the server keeps nothing once delivered).
public protocol ChatStore: Sendable {
    func messages(in conversationId: String) async throws -> [ChatMessage]
    func save(_ messages: [ChatMessage], in conversationId: String) async throws
    func delete(_ conversationId: String) async throws
}

public actor InMemoryChatStore: ChatStore {
    private var stored: [String: [ChatMessage]] = [:]

    public init() {}

    public func messages(in conversationId: String) -> [ChatMessage] {
        stored[conversationId] ?? []
    }

    public func save(_ messages: [ChatMessage], in conversationId: String) {
        stored[conversationId] = messages
    }

    public func delete(_ conversationId: String) {
        stored[conversationId] = nil
    }
}

/// One AES-GCM encrypted file per conversation, named by an HMAC of its ID (so names don't show conversations),
/// written atomically with Data Protection Complete and excluded from backups. The key is 32 bytes from the
/// Keychain (this device only); the app passes it in.
public actor EncryptedChatStore: ChatStore {
    private let directory: URL
    private let key: SymmetricKey

    public init(directory: URL, key: Data) throws {
        guard key.count == 32 else { throw ChatAPIError.invalidResponse }
        self.directory = directory
        self.key = SymmetricKey(data: key)
        var url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func file(_ conversationId: String) -> URL {
        let name = HMAC<SHA256>.authenticationCode(for: Data(conversationId.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name)
    }

    public func messages(in conversationId: String) throws -> [ChatMessage] {
        guard let sealed = try? Data(contentsOf: file(conversationId)) else { return [] }
        let plain = try AES.GCM.open(
            AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(conversationId.utf8)
        )
        return try JSONDecoder().decode([ChatMessage].self, from: plain)
    }

    public func save(_ messages: [ChatMessage], in conversationId: String) throws {
        let plain = try JSONEncoder().encode(messages)
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(conversationId.utf8)).combined
        else { throw ChatAPIError.invalidResponse }
        #if os(iOS)
            try sealed.write(to: file(conversationId), options: [.atomic, .completeFileProtection])
        #else
            try sealed.write(to: file(conversationId), options: .atomic)
        #endif
    }

    public func delete(_ conversationId: String) throws {
        let url = file(conversationId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
