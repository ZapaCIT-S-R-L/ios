import Foundation

public enum ParticipantRole: String, Codable, Sendable {
    case parent
    case kid
}

public struct TrackRef: Codable, Sendable, Hashable {
    public var sessionId: String
    public var trackName: String

    public init(sessionId: String, trackName: String) {
        self.sessionId = sessionId
        self.trackName = trackName
    }
}

/// A device in a call: an account and its libsignal device id (an integer in the API). `name` is the
/// `<accountId>.<deviceId>` form the key sealer and leader checks use.
public struct CallDevice: Codable, Sendable, Hashable {
    public var accountId: String
    public var deviceId: Int

    public init(accountId: String, deviceId: Int) {
        self.accountId = accountId
        self.deviceId = deviceId
    }

    /// From `<accountId>.<deviceId>`.
    public init?(name: String) {
        guard let dot = name.lastIndex(of: "."), let device = Int(name[name.index(after: dot)...]) else { return nil }
        self.init(accountId: String(name[..<dot]), deviceId: device)
    }

    public var name: String {
        "\(accountId).\(deviceId)"
    }
}

/// One device in the call, as the call's Durable Object reports it (`Call.participants`).
public struct RosterParticipant: Codable, Sendable, Equatable {
    public var accountId: String
    public var deviceId: Int
    public var role: ParticipantRole
    /// Their SFU session; nil until they created one.
    public var sessionId: String?
    /// Their published track names.
    public var tracks: [String]
    /// Their events WebSocket is open.
    public var connected: Bool

    public init(
        accountId: String, deviceId: Int, role: ParticipantRole, sessionId: String?, tracks: [String],
        connected: Bool = true
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.role = role
        self.sessionId = sessionId
        self.tracks = tracks
        self.connected = connected
    }

    public var name: String {
        CallDevice(accountId: accountId, deviceId: deviceId).name
    }

    /// What to subscribe to: their tracks in their session.
    public var trackRefs: [TrackRef] {
        guard let sessionId else { return [] }
        return tracks.map { TrackRef(sessionId: sessionId, trackName: $0) }
    }
}

/// The `Call` object: state, the key generation (`epoch`, up on every join and leave) and who makes its key.
public struct CallSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case ringing
        case active
        case ended
    }

    public var callId: String
    public var state: State
    public var epoch: UInt32
    public var keyLeader: CallDevice?
    public var participants: [RosterParticipant]

    public init(
        callId: String, state: State, epoch: UInt32, keyLeader: CallDevice?, participants: [RosterParticipant]
    ) {
        self.callId = callId
        self.state = state
        self.epoch = epoch
        self.keyLeader = keyLeader
        self.participants = participants
    }
}

/// A message from the call's event socket, per services/calls/openapi.yaml.
public enum CallSignal: Sendable, Equatable {
    case roster(CallSnapshot)
    /// A sealed call key for this device.
    case key(KeyEnvelope)
    case joined(CallDevice, epoch: UInt32)
    case left(CallDevice, epoch: UInt32)
    case declined(accountId: String)
    /// `hung_up`, `no_answer`, `declined`, `max_duration`, `disconnected`.
    case ended(reason: String)
    case error(code: String, epoch: UInt32?)
    /// A type this app doesn't use (`keys_ack`, `pong`, new ones); ignored.
    case unknown(String)

    private struct Message: Decodable {
        var type: String
        var call: CallSnapshot?
        var accountId: String?
        var deviceId: Int?
        var epoch: UInt32?
        var fromAccount: String?
        var fromDevice: Int?
        var blob: Data?
        var reason: String?
        var code: String?
    }

    public static func decode(_ data: Data) throws -> CallSignal {
        let message = try JSONDecoder().decode(Message.self, from: data)
        func device() throws -> CallDevice {
            guard let accountId = message.accountId, let deviceId = message.deviceId else {
                throw CallsAPIError.invalidResponse
            }
            return CallDevice(accountId: accountId, deviceId: deviceId)
        }
        switch message.type {
        case "roster":
            guard let call = message.call else { throw CallsAPIError.invalidResponse }
            return .roster(call)
        case "key":
            guard let epoch = message.epoch, let account = message.fromAccount, let from = message.fromDevice,
                  let blob = message.blob
            else { throw CallsAPIError.invalidResponse }
            let sender = CallDevice(accountId: account, deviceId: from).name
            return .key(KeyEnvelope(epoch: epoch, fromDevice: sender, toDevice: "", blob: blob))
        case "joined": return try .joined(device(), epoch: message.epoch ?? 0)
        case "left": return try .left(device(), epoch: message.epoch ?? 0)
        case "declined": return .declined(accountId: message.accountId ?? "")
        case "ended": return .ended(reason: message.reason ?? "ended")
        case "error": return .error(code: message.code ?? "", epoch: message.epoch)
        default: return .unknown(message.type)
        }
    }
}

/// A message this phone sends on the event socket.
public enum OutgoingSignal: Sendable, Equatable {
    /// The new call key for the current epoch, sealed once per other participant device.
    case keys(epoch: UInt32, [KeyEnvelope])
    case ping

    private struct Keys: Encodable {
        struct Envelope: Encodable {
            var toAccount: String
            var toDevice: Int
            var blob: Data
        }

        var type = "keys"
        var epoch: UInt32
        var envelopes: [Envelope]
    }

    private struct Ping: Encodable {
        var type = "ping"
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        switch self {
        case let .keys(epoch, envelopes):
            let wire = try envelopes.map { envelope in
                guard let device = CallDevice(name: envelope.toDevice) else { throw CallsAPIError.invalidResponse }
                return Keys.Envelope(toAccount: device.accountId, toDevice: device.deviceId, blob: envelope.blob)
            }
            return try encoder.encode(Keys(epoch: epoch, envelopes: wire))
        case .ping:
            return try encoder.encode(Ping())
        }
    }
}
