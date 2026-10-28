import Foundation

/// A STUN/TURN server for WebRTC. TURN credentials are short-lived (≤ 1 h), minted by the calls service.
public struct IceServer: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// `POST /v1/calls` and `POST /v1/calls/{id}/join` → `{callId, iceServers}`.
public struct CallGrant: Codable, Sendable, Equatable {
    public var callId: String
    public var iceServers: [IceServer]

    public init(callId: String, iceServers: [IceServer]) {
        self.callId = callId
        self.iceServers = iceServers
    }
}

// MARK: - Cloudflare Realtime shapes (proxied unchanged by the calls service)

public struct SessionDescription: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case offer
        case answer
    }

    public var type: Kind
    public var sdp: String

    public init(type: Kind, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

public struct TrackObject: Codable, Sendable, Equatable {
    public enum Location: String, Codable, Sendable {
        case local
        case remote
    }

    public var location: Location
    public var mid: String?
    public var trackName: String
    /// For `remote`: the session that publishes the track.
    public var sessionId: String?

    public init(location: Location, mid: String? = nil, trackName: String, sessionId: String? = nil) {
        self.location = location
        self.mid = mid
        self.trackName = trackName
        self.sessionId = sessionId
    }
}

public struct TracksRequest: Codable, Sendable, Equatable {
    public var sessionDescription: SessionDescription?
    public var tracks: [TrackObject]

    public init(sessionDescription: SessionDescription? = nil, tracks: [TrackObject]) {
        self.sessionDescription = sessionDescription
        self.tracks = tracks
    }
}

public struct TrackResult: Codable, Sendable, Equatable {
    public var mid: String?
    public var trackName: String?
    public var sessionId: String?
    public var errorCode: String?
}

public struct TracksResponse: Codable, Sendable, Equatable {
    public var requiresImmediateRenegotiation: Bool?
    public var sessionDescription: SessionDescription?
    public var tracks: [TrackResult]?

    public init(
        requiresImmediateRenegotiation: Bool? = nil, sessionDescription: SessionDescription? = nil,
        tracks: [TrackResult]? = nil
    ) {
        self.requiresImmediateRenegotiation = requiresImmediateRenegotiation
        self.sessionDescription = sessionDescription
        self.tracks = tracks
    }
}

public enum CallsAPIError: Error, Equatable, Sendable {
    /// 401: the chat token is missing, expired or not for calls.zapakid.ro. Get a new one.
    case unauthorized
    /// 403: the conversation isn't in the token, or the Realtime session isn't this caller's.
    case notAllowed
    case callNotFound
    /// 409 `call_full`: 8 people are already in the call.
    case callFull
    /// 410 `call_ended`.
    case callEnded
    case rateLimited(retryAfter: Int?)
    case server(status: Int, code: String?)
    case network
    case invalidResponse
}
