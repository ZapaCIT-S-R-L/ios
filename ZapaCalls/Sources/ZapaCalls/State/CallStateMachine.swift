import Foundation

/// Where a call is, as the screens show it.
public enum CallPhase: Hashable, Sendable {
    case idle
    /// We called; the others' phones ring.
    case calling
    /// Someone calls us.
    case ringing
    case connecting
    case active
    case reconnecting
    case ended(CallEndReason)
}

public enum CallEndReason: Hashable, Sendable {
    case hungUp
    case declined
    case missed
    case noAnswer
    case remoteEnded
    case failed
}

public enum CallEvent: Hashable, Sendable {
    case placeCall
    case incoming
    case accept
    case decline
    /// Another participant joined our outgoing call.
    case answered
    /// Everyone we called declined.
    case everyoneDeclined
    /// The ring timeout (45 s, from the calls service) ran out.
    case ringTimeout
    case mediaConnected
    case mediaInterrupted
    case reconnectTimeout
    case hangUp
    /// The others left or the call ended elsewhere.
    case remoteEnded
    case failed
}

/// The call's states and their transitions, without side effects, so every path is easy to test.
public struct CallStateMachine: Sendable {
    public private(set) var phase: CallPhase
    /// When the call was first active (the call clock); a reconnect keeps it.
    public private(set) var connectedAt: Date?
    private var mediaUp = false
    private let clock: @Sendable () -> Date

    public init(phase: CallPhase = .idle, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.phase = phase
        self.clock = clock
    }

    public var isEnded: Bool {
        if case .ended = phase {
            true
        } else {
            false
        }
    }

    /// Applies the event; returns false (and changes nothing) when it doesn't fit the current phase.
    @discardableResult
    public mutating func handle(_ event: CallEvent) -> Bool {
        guard let next = next(after: event) else { return false }
        switch event {
        case .mediaConnected: mediaUp = true
        case .mediaInterrupted: mediaUp = false
        default: break
        }
        phase = next
        if next == .active, connectedAt == nil {
            connectedAt = clock()
        }
        return true
    }

    private func next(after event: CallEvent) -> CallPhase? {
        switch event {
        case .hangUp: return phase == .idle || isEnded ? nil : .ended(.hungUp)
        case .failed: return phase == .idle || isEnded ? nil : .ended(.failed)
        default: break
        }
        return switch phase {
        case .idle: [.placeCall: .calling, .incoming: .ringing][event]
        case .calling: afterCalling(event)
        case .ringing: [
                .accept: .connecting,
                .decline: .ended(.declined),
                .ringTimeout: .ended(.missed),
                .remoteEnded: .ended(.missed),
            ][event]
        case .connecting, .active, .reconnecting: inCall(event)
        case .ended: nil
        }
    }

    private func afterCalling(_ event: CallEvent) -> CallPhase? {
        switch event {
        case .answered: mediaUp ? .active : .connecting
        case .mediaConnected: .calling
        case .ringTimeout, .remoteEnded: .ended(.noAnswer)
        case .everyoneDeclined: .ended(.declined)
        default: nil
        }
    }

    private func inCall(_ event: CallEvent) -> CallPhase? {
        switch (phase, event) {
        case (_, .mediaConnected): .active
        case (_, .remoteEnded): .ended(.remoteEnded)
        case (.connecting, .mediaInterrupted), (.active, .mediaInterrupted): .reconnecting
        case (.reconnecting, .reconnectTimeout): .ended(.failed)
        default: nil
        }
    }
}
