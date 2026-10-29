import Foundation

public enum ChatRole: String, Codable, Sendable {
    case parent
    case kid
    /// A parent of a kid in the conversation, added by the server: reads along, never writes.
    case observer
}

public struct DeviceRef: Codable, Sendable, Equatable {
    public var deviceId: Int
    public var registrationId: Int

    public init(deviceId: Int, registrationId: Int) {
        self.deviceId = deviceId
        self.registrationId = registrationId
    }
}

public struct ConversationMember: Codable, Sendable, Equatable {
    public var accountId: String
    public var role: ChatRole
    /// Added by the server as a parent of a kid in the conversation.
    public var guardian: Bool
    public var devices: [DeviceRef]

    public init(accountId: String, role: ChatRole, guardian: Bool, devices: [DeviceRef]) {
        self.accountId = accountId
        self.role = role
        self.guardian = guardian
        self.devices = devices
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case direct
        case group
    }

    public enum State: String, Codable, Sendable {
        case open
        case closed
    }

    public var id: String
    public var kind: Kind
    public var state: State
    public var members: [ConversationMember]

    public init(id: String, kind: Kind, state: State, members: [ConversationMember]) {
        self.id = id
        self.kind = kind
        self.state = state
        self.members = members
    }
}

public struct DeviceAddress: Codable, Sendable, Equatable, Hashable {
    public var accountId: String
    public var deviceId: Int

    public init(accountId: String, deviceId: Int) {
        self.accountId = accountId
        self.deviceId = deviceId
    }
}

/// The libsignal ciphertext type; there is no plaintext type.
public enum EnvelopeType: String, Codable, Sendable {
    case prekeyMessage = "prekey_message"
    case message
    case senderKeyMessage = "sender_key_message"
}

public struct OutgoingEnvelope: Codable, Sendable, Equatable {
    public var recipientAccountId: String
    public var recipientDeviceId: Int
    public var recipientRegistrationId: Int
    public var type: EnvelopeType
    /// libsignal ciphertext (base64 on the wire), at most 64 KiB.
    public var content: Data

    public init(
        recipientAccountId: String, recipientDeviceId: Int, recipientRegistrationId: Int, type: EnvelopeType,
        content: Data
    ) {
        self.recipientAccountId = recipientAccountId
        self.recipientDeviceId = recipientDeviceId
        self.recipientRegistrationId = recipientRegistrationId
        self.type = type
        self.content = content
    }
}

/// One delivery copy for this device; acknowledge it by `id`.
public struct Envelope: Codable, Sendable, Equatable {
    public var id: String
    public var conversationId: String
    public var messageId: String
    public var senderAccountId: String
    public var senderDeviceId: Int
    public var type: EnvelopeType
    public var content: Data
    /// Milliseconds since the epoch.
    public var serverTimestamp: Int64

    public init(
        id: String, conversationId: String, messageId: String, senderAccountId: String, senderDeviceId: Int,
        type: EnvelopeType, content: Data, serverTimestamp: Int64
    ) {
        self.id = id
        self.conversationId = conversationId
        self.messageId = messageId
        self.senderAccountId = senderAccountId
        self.senderDeviceId = senderDeviceId
        self.type = type
        self.content = content
        self.serverTimestamp = serverTimestamp
    }
}

public struct EnvelopePage: Codable, Sendable, Equatable {
    public var envelopes: [Envelope]
    public var more: Bool

    public init(envelopes: [Envelope], more: Bool) {
        self.envelopes = envelopes
        self.more = more
    }
}

public enum ChatAPIError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    /// 409: the envelopes don't match the members' current devices. Refresh the conversation and seal again.
    case staleDevices(missing: [DeviceAddress], extra: [DeviceAddress])
    /// 410: a device was re-installed. Fetch its keys again.
    case staleRegistration([DeviceAddress])
    case tooLarge
    case rateLimited(retryAfter: Int?)
    case server(status: Int, code: String?)
    case network
    case invalidResponse
}

/// Seals a message for every other device of a conversation and opens what arrives. libsignal (sessions and
/// sender keys) in the app; a fake in tests. The chat service only ever sees what this returns.
public protocol MessageSealer: Sendable {
    func seal(_ plaintext: Data, for conversation: Conversation, me: String) async throws -> [OutgoingEnvelope]
    func open(_ envelope: Envelope) async throws -> Data
}

/// A sealer allowed in release builds: real end-to-end encryption (libsignal). Fakes for tests and demos must not
/// conform and must stay inside `#if DEBUG` (`scripts/release-sealers.js`, `npm test`).
public protocol ReleaseMessageSealer: MessageSealer {}
