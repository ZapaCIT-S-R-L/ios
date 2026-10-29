import Foundation
import Observation

/// Why a call the user placed ended without a conversation, shown briefly after the call screen closes.
public struct CallNotice: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case declined, noAnswer, interrupted
    }

    public let reason: Reason
    public let names: [String]
}

public enum CallDirection: Sendable, Equatable {
    case incoming, outgoing
}

/// The phone's calls: one at a time, ringing through the system call UI (CallKit), logged when they end.
@MainActor
@Observable
public final class CallCoordinator: CallSystemActions {
    public private(set) var current: CallController?
    /// Why the last call this phone placed ended (declined, no answer, interrupted); nil after a normal hang-up.
    public private(set) var notice: CallNotice?
    /// Which call CallKit last refused (no `voip` background mode, Do Not Disturb, …), so the UI can say so.
    public private(set) var refused: CallDirection?
    /// The media engine follows CallKit's audio session. CallKit may activate it before an outgoing call's engine
    /// is wired up, so a newly set handler gets the current state at once.
    public var onAudioSessionChange: ((Bool) -> Void)? {
        didSet {
            if audioActive {
                onAudioSessionChange?(true)
            }
        }
    }

    private var audioActive = false

    private let system: CallSystem
    private let log: CallLogStore
    private let lookup: (String) -> CallPeer?
    private let makeController: () -> CallController
    private var uuids: [String: UUID] = [:]
    private var currentUUID: UUID?
    private var endedBySystem: Set<UUID> = []
    private var direction: CallLogEntry.Direction = .incoming
    private var startedAt = Date()
    private var conversationId: String?

    public init(
        system: CallSystem, log: CallLogStore = InMemoryCallLog(), lookup: @escaping (String) -> CallPeer?,
        makeController: @escaping () -> CallController
    ) {
        self.system = system
        self.log = log
        self.lookup = lookup
        self.makeController = makeController
        system.actions = self
    }

    /// The UI showed the refusal.
    public func clearRefusal() {
        refused = nil
    }

    public func uuid(for callId: String) -> UUID? {
        uuids[callId]
    }

    // MARK: Incoming

    /// A VoIP push. PushKit requires every push to show a call in CallKit, even one we decline at once.
    public func handle(_ push: IncomingCallPush) async {
        let uuid = UUID()
        uuids[push.callId] = uuid
        let caller = push.callerAccountId.flatMap(lookup) ?? CallPeer(
            accountId: push.callerAccountId ?? "", deviceId: "", displayName: "ZapaKid", avatar: "robot-1",
            role: .parent
        )
        do {
            try await system.reportIncoming(uuid: uuid, callerName: caller.displayName)
        } catch CallSystemError.filtered {
            // Do Not Disturb or blocked: the user chose not to be rung. Decline, so the caller stops ringing at once.
            let controller = makeController()
            controller.reportIncoming(callId: push.callId, caller: caller)
            await controller.decline()
            return
        } catch {
            // Any other refusal (e.g. no `voip` background mode) is a fault: record it, never decline silently.
            refused = .incoming
            return
        }
        let controller = makeController()
        controller.reportIncoming(callId: push.callId, caller: caller)
        guard current == nil else {
            system.reportEnded(uuid: uuid, reason: .declinedElsewhere)
            await controller.decline()
            return
        }
        begin(controller, uuid: uuid, direction: .incoming, conversationId: nil)
    }

    /// A push without a valid call: report and end it at once (PushKit's rule).
    public func handleInvalidPush() async {
        let uuid = UUID()
        try? await system.reportIncoming(uuid: uuid, callerName: "ZapaKid")
        system.reportEnded(uuid: uuid, reason: .failed)
    }

    // MARK: Outgoing

    public func startCall(conversationId: String, peers: [CallPeer]) async {
        guard current == nil else { return }
        let uuid = UUID()
        do {
            try await system.startOutgoing(uuid: uuid, name: peers.map(\.displayName).joined(separator: ", "))
        } catch {
            refused = .outgoing
            return
        }
        refused = nil
        let controller = makeController()
        begin(controller, uuid: uuid, direction: .outgoing, conversationId: conversationId)
        await controller.startCall(conversationId: conversationId, peers: peers)
        if let callId = controller.callId {
            uuids[callId] = uuid
        }
    }

    // MARK: The app's buttons

    /// Answers the ringing call through the system, so CallKit's own UI stops ringing.
    public func accept() async {
        guard let current else { return }
        do {
            guard let uuid = currentUUID else { throw CancellationError() }
            try await system.requestAnswer(uuid: uuid)
        } catch {
            await current.accept()
        }
    }

    /// Declines a ringing call or hangs up, through the system.
    public func hangUp() async {
        guard let current else { return }
        do {
            guard let uuid = currentUUID else { throw CancellationError() }
            try await system.requestEnd(uuid: uuid)
        } catch {
            if current.phase == .ringing {
                await current.decline()
            } else {
                await current.hangUp()
            }
        }
    }

    // MARK: CallKit actions

    public func answer(_ uuid: UUID) async {
        guard uuid == currentUUID else { return }
        await current?.accept()
    }

    public func end(_ uuid: UUID) async {
        guard uuid == currentUUID, let current else { return }
        endedBySystem.insert(uuid)
        if current.phase == .ringing {
            await current.decline()
        } else {
            await current.hangUp()
        }
    }

    public func setMuted(_ uuid: UUID, _ muted: Bool) async {
        guard uuid == currentUUID else { return }
        await current?.setMuted(muted)
    }

    public func audioSession(active: Bool) {
        audioActive = active
        onAudioSessionChange?(active)
    }

    // MARK: Following the call

    private func begin(
        _ controller: CallController, uuid: UUID, direction: CallLogEntry.Direction, conversationId: String?
    ) {
        current = controller
        currentUUID = uuid
        self.direction = direction
        self.conversationId = conversationId
        startedAt = Date()
        watch(controller, uuid: uuid)
        phaseChanged(controller, uuid: uuid)
    }

    private func watch(_ controller: CallController, uuid: UUID) {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, current === controller else { return }
                phaseChanged(controller, uuid: uuid)
                if current === controller {
                    watch(controller, uuid: uuid)
                }
            }
        }
    }

    private func phaseChanged(_ controller: CallController, uuid: UUID) {
        switch controller.phase {
        case .active:
            system.reportConnected(uuid: uuid)
        case let .ended(reason):
            if !endedBySystem.contains(uuid) {
                system.reportEnded(uuid: uuid, reason: Self.systemReason(reason))
            }
            finish(controller, reason: reason)
        default:
            break
        }
    }

    private func finish(_ controller: CallController, reason: CallEndReason) {
        let entry = CallLogEntry(
            id: controller.callId ?? UUID().uuidString, peers: controller.participants, direction: direction,
            startedAt: startedAt, duration: controller.connectedAt.map { Date().timeIntervalSince($0) } ?? 0,
            outcome: .init(endReason: reason, wasConnected: controller.connectedAt != nil),
            conversationId: conversationId
        )
        notice = Self.notice(for: reason, direction: direction, peers: controller.participants)
        current = nil
        currentUUID = nil
        Task { await log.record(entry) }
    }

    /// The banner showed the notice.
    public func clearNotice() {
        notice = nil
    }

    static func notice(for reason: CallEndReason, direction: CallLogEntry.Direction, peers: [CallPeer]) -> CallNotice? {
        guard direction == .outgoing else { return nil }
        let names = peers.map(\.displayName).filter { !$0.isEmpty }
        return switch reason {
        case .declined: CallNotice(reason: .declined, names: names)
        case .noAnswer: CallNotice(reason: .noAnswer, names: names)
        case .failed: CallNotice(reason: .interrupted, names: names)
        case .hungUp, .remoteEnded, .missed: nil
        }
    }

    static func systemReason(_ reason: CallEndReason) -> CallSystemEndReason {
        switch reason {
        case .noAnswer, .missed: .unanswered
        case .failed: .failed
        case .declined: .declinedElsewhere
        case .hungUp, .remoteEnded: .remoteEnded
        }
    }
}
