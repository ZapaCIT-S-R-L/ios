import Foundation

/// Why a call ended, as the system call UI (CallKit) is told.
public enum CallSystemEndReason: Sendable, Equatable {
    case remoteEnded
    case unanswered
    case failed
    case declinedElsewhere
}

/// Why the system refused to ring an incoming call.
public enum CallSystemError: Error, Equatable {
    /// Do Not Disturb or a blocked caller: the user chose not to be rung.
    case filtered
}

/// The system call UI: CallKit on iOS (native incoming call screen, lock screen, Bluetooth, audio session).
@MainActor
public protocol CallSystem: AnyObject {
    /// Where the user's taps on the system UI go.
    var actions: CallSystemActions? { get set }
    func reportIncoming(uuid: UUID, callerName: String) async throws
    func startOutgoing(uuid: UUID, name: String) async throws
    func reportConnected(uuid: UUID)
    func reportEnded(uuid: UUID, reason: CallSystemEndReason)
    /// The app's own answer button: asks the system to answer, which comes back as `actions.answer`, so the system
    /// UI (CallKit's banner) stops ringing too.
    func requestAnswer(uuid: UUID) async throws
    /// The app's own decline or hang-up button: comes back as `actions.end`.
    func requestEnd(uuid: UUID) async throws
}

@MainActor
public protocol CallSystemActions: AnyObject {
    func answer(_ uuid: UUID) async
    func end(_ uuid: UUID) async
    func setMuted(_ uuid: UUID, _ muted: Bool) async
    /// CallKit activated or deactivated the audio session (the media engine starts audio only when active).
    func audioSession(active: Bool)
}

/// A VoIP push. It carries no content, only which call rings (and who calls, as an account ID the app looks up in
/// its own family list): `{"callId": "...", "callerAccountId": "..."}`.
public struct IncomingCallPush: Sendable, Equatable {
    public let callId: String
    public let callerAccountId: String?

    public init(callId: String, callerAccountId: String?) {
        self.callId = callId
        self.callerAccountId = callerAccountId
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let callId = payload["callId"] as? String, Self.valid(callId) else { return nil }
        self.callId = callId
        callerAccountId = (payload["callerAccountId"] as? String).flatMap { Self.valid($0) ? $0 : nil }
    }

    private static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
    }
}
