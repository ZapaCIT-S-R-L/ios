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

/// One device in the call, as the call's Durable Object reports it.
public struct RosterParticipant: Codable, Sendable, Equatable {
    public var accountId: String
    public var deviceId: String
    public var role: ParticipantRole
    public var displayName: String?
    /// One of the robot avatars, e.g. `robot-3`.
    public var avatar: String?
    public var muted: Bool
    public var tracks: [TrackRef]

    public init(
        accountId: String, deviceId: String, role: ParticipantRole, displayName: String? = nil,
        avatar: String? = nil, muted: Bool = false, tracks: [TrackRef] = []
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.role = role
        self.displayName = displayName
        self.avatar = avatar
        self.muted = muted
        self.tracks = tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        role = try container.decode(ParticipantRole.self, forKey: .role)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        tracks = try container.decodeIfPresent([TrackRef].self, forKey: .tracks) ?? []
    }
}

/// A message from the call's event socket: `{"type": ..., ...}`.
public enum CallSignal: Sendable, Equatable {
    case roster([RosterParticipant])
    case key(KeyEnvelope)
    case joined(RosterParticipant)
    case left(deviceId: String)
    case declined(deviceId: String)
    case ended(reason: String)
    case ringTimeout
    /// A type this app version doesn't know; ignored.
    case unknown(String)

    private struct Envelope: Decodable {
        var type: String
    }

    private struct Roster: Decodable {
        var participants: [RosterParticipant]
    }

    private struct Device: Decodable {
        var deviceId: String
    }

    private struct Ended: Decodable {
        var reason: String?
    }

    private struct Joined: Decodable {
        var participant: RosterParticipant
    }

    public static func decode(_ data: Data) throws -> CallSignal {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: data).type
        return switch type {
        case "roster": try .roster(decoder.decode(Roster.self, from: data).participants)
        case "key": try .key(decoder.decode(KeyEnvelope.self, from: data))
        case "joined": try .joined(decoder.decode(Joined.self, from: data).participant)
        case "left": try .left(deviceId: decoder.decode(Device.self, from: data).deviceId)
        case "declined": try .declined(deviceId: decoder.decode(Device.self, from: data).deviceId)
        case "ended": try .ended(reason: decoder.decode(Ended.self, from: data).reason ?? "ended")
        case "ring_timeout": .ringTimeout
        default: .unknown(type)
        }
    }
}

/// A message this phone sends on the event socket.
public enum OutgoingSignal: Sendable, Equatable {
    /// A sealed key for one device; the service relays it to that device only.
    case key(KeyEnvelope)
    case muted(Bool)

    private struct Key: Encodable {
        var type = "key"
        var epoch: UInt32
        var fromDevice: String
        var toDevice: String
        var blob: Data
    }

    private struct Mute: Encodable {
        var type = "mute"
        var muted: Bool
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return switch self {
        case let .key(envelope): try encoder.encode(Key(
                epoch: envelope.epoch, fromDevice: envelope.fromDevice, toDevice: envelope.toDevice,
                blob: envelope.blob
            ))
        case let .muted(muted): try encoder.encode(Mute(muted: muted))
        }
    }
}
