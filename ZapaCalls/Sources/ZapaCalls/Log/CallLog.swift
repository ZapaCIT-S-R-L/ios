import Foundation

/// One call in the log: who, when, how long, how it ended. Metadata only; audio is never stored.
public struct CallLogEntry: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable {
        case incoming
        case outgoing
    }

    public enum Outcome: Sendable, Equatable {
        case answered
        case missed
        case declined
        case noAnswer
        case cancelled
        case failed

        public init(endReason: CallEndReason, wasConnected: Bool) {
            if wasConnected {
                self = .answered
                return
            }
            self = switch endReason {
            case .missed: .missed
            case .noAnswer: .noAnswer
            case .declined: .declined
            case .failed: .failed
            case .hungUp, .remoteEnded: .cancelled
            }
        }
    }

    public var id: String
    public var peers: [CallPeer]
    public var direction: Direction
    public var startedAt: Date
    public var duration: TimeInterval
    public var outcome: Outcome
    /// The conversation to call back.
    public var conversationId: String?

    public init(
        id: String, peers: [CallPeer], direction: Direction, startedAt: Date, duration: TimeInterval,
        outcome: Outcome, conversationId: String? = nil
    ) {
        self.id = id
        self.peers = peers
        self.direction = direction
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.conversationId = conversationId
    }

    public var isMissed: Bool {
        outcome == .missed
    }
}

/// Where the log lives: on the phone for now (the calls service keeps its own metadata log in D1).
public protocol CallLogStore: Sendable {
    func record(_ entry: CallLogEntry) async
    func entries() async -> [CallLogEntry]
}

public actor InMemoryCallLog: CallLogStore {
    private var stored: [CallLogEntry]

    public init(entries: [CallLogEntry] = []) {
        stored = entries
    }

    public func record(_ entry: CallLogEntry) {
        stored.removeAll { $0.id == entry.id }
        stored.append(entry)
    }

    public func entries() -> [CallLogEntry] {
        stored.sorted { $0.startedAt > $1.startedAt }
    }
}
