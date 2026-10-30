import Foundation
import Observation
import os

/// Someone in the call as the screens show them: a robot avatar, a name, muted, speaking.
public struct CallPeer: Sendable, Equatable, Identifiable {
    public var accountId: String
    public var deviceId: String
    public var displayName: String
    public var avatar: String
    public var role: ParticipantRole
    public var isMuted = false
    public var isSpeaking = false

    public var id: String {
        deviceId
    }

    public init(
        accountId: String, deviceId: String, displayName: String, avatar: String, role: ParticipantRole,
        isMuted: Bool = false, isSpeaking: Bool = false
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.displayName = displayName
        self.avatar = avatar
        self.role = role
        self.isMuted = isMuted
        self.isSpeaking = isSpeaking
    }
}

/// One call on this phone: drives the state machine from the calls API, the event socket and the media engine,
/// and rotates the frame key on every join and leave. The screens observe it.
@MainActor
@Observable
public final class CallController {
    public private(set) var phase: CallPhase = .idle
    public private(set) var participants: [CallPeer] = []
    public private(set) var isMuted = false
    public private(set) var isSpeakerOn = false
    public private(set) var callId: String?
    /// True for a call someone else placed to this phone (it rings here).
    public private(set) var isIncoming = false
    public private(set) var lastError: CallsAPIError?
    /// The call clock's start: the server's answer time when it sent one (the same on every phone), else when this
    /// phone's call became active.
    public var connectedAt: Date? {
        guard let local = machine.connectedAt else { return nil }
        return answeredAt ?? local
    }

    private var answeredAt: Date?

    /// Level above which a participant shows the speaking ring.
    static let speakingLevel: Float = 0.08

    public let me: String
    private let api: CallsAPI
    private let engine: CallMediaEngine
    private let sealer: CallKeySealer
    private let reconnectTimeout: Duration
    /// Names and robots by account (the family); the server's roster has neither.
    private let directory: ((String) -> CallPeer?)?
    private var machine = CallStateMachine()
    private var keys: CallKeyManager?
    private var events: CallEventsConnection?
    private var tasks: [Task<Void, Never>] = []
    private var subscribed: Set<TrackRef> = []
    /// The others' tracks from the latest roster. Pulled only once this phone's SFU session exists.
    private var wanted: Set<TrackRef> = []
    private var mediaStarted = false
    private var retryTask: Task<Void, Never>?
    private var pullAttempts = 0
    private let pullRetryDelay: @Sendable (Int) -> Duration
    private var trackOwner: [String: String] = [:]
    private var hadOthers = false
    private var reconnectTask: Task<Void, Never>?

    public init(
        me: String, api: CallsAPI, engine: CallMediaEngine, sealer: CallKeySealer,
        reconnectTimeout: Duration = .seconds(20),
        pullRetryDelay: @escaping @Sendable (Int) -> Duration = CallController.defaultPullRetryDelay,
        directory: ((String) -> CallPeer?)? = nil
    ) {
        self.pullRetryDelay = pullRetryDelay
        self.directory = directory
        self.me = me
        self.api = api
        self.engine = engine
        self.sealer = sealer
        self.reconnectTimeout = reconnectTimeout
    }

    // MARK: Actions

    /// Calls the conversation; `peers` show while it rings.
    public func startCall(conversationId: String, peers: [CallPeer]) async {
        guard apply(.placeCall) else { return }
        participants = peers
        do {
            let grant = try await api.createCall(conversationId: conversationId)
            try await connect(grant)
        } catch {
            fail(error)
        }
    }

    /// A ringing call (from PushKit/CallKit or the event socket).
    public func reportIncoming(callId: String, caller: CallPeer) {
        guard apply(.incoming) else { return }
        self.callId = callId
        isIncoming = true
        participants = [caller]
    }

    public func accept() async {
        guard let callId, apply(.accept) else { return }
        do {
            try await connect(api.join(callId: callId))
        } catch {
            fail(error)
        }
    }

    public func decline() async {
        guard let callId, apply(.decline) else { return }
        try? await api.decline(callId: callId)
    }

    public func hangUp() async {
        guard apply(.hangUp) else { return }
        await tearDown(leave: true)
    }

    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        engine.setMuted(muted)
    }

    public func setSpeakerOn(_ speakerOn: Bool) {
        isSpeakerOn = speakerOn
        engine.setSpeakerOn(speakerOn)
    }

    // MARK: Connection

    private func connect(_ grant: CallGrant) async throws {
        callId = grant.callId
        keys = CallKeyManager(callId: grant.callId, me: me, sealer: sealer, frameKeys: engine.frameKeys)
        let events = try await api.openEvents(callId: grant.callId)
        self.events = events
        tasks.append(Task { [weak self] in
            do {
                for try await signal in events.signals() {
                    await self?.handle(signal)
                }
            } catch {}
        })
        tasks.append(Task { [weak self, engine] in
            for await event in engine.events {
                self?.handle(event)
            }
        })
        try await engine.start(
            callId: grant.callId, iceServers: grant.iceServers, api: api, trackName: Self.trackName(for: me)
        )
        mediaStarted = true
        await syncTracks()
    }

    /// `audio-<accountId>_<deviceId>`: the API allows only `A-Za-z0-9_-` in track names (the same on Android).
    public nonisolated static func trackName(for device: String) -> String {
        guard let parsed = CallDevice(name: device) else { return "audio-\(device)" }
        return "audio-\(parsed.accountId)_\(parsed.deviceId)"
    }

    private func handle(_ signal: CallSignal) async {
        switch signal {
        case let .roster(call): await rosterChanged(call)
        case var .key(envelope):
            envelope.toDevice = me
            _ = try? await keys?.receive(envelope)
        case let .ended(reason):
            switch reason {
            case "no_answer": await end(.ringTimeout)
            case "declined": await end(.everyoneDeclined)
            default: await end(.remoteEnded)
            }
        case .joined, .left, .declined, .error, .unknown: break // a roster follows every change
        }
    }

    private func rosterChanged(_ call: CallSnapshot) async {
        if let answered = call.answeredDate {
            answeredAt = answered
        }
        let others = call.participants.filter { $0.name != me }
        let listed = others.map { person in
            let known = participants.first { $0.deviceId == person.name } ?? participants.first {
                $0.accountId == person.accountId
            }
            let directoryEntry = directory?(person.accountId)
            return CallPeer(
                accountId: person.accountId, deviceId: person.name,
                displayName: directoryEntry?.displayName ?? known?.displayName ?? "",
                avatar: directoryEntry?.avatar ?? known?.avatar ?? "robot-1", role: person.role,
                isMuted: false, isSpeaking: known?.isSpeaking ?? false
            )
        }
        // Still ringing: the roster lists only this phone, so keep the invited peers on screen until someone joins.
        if !others.isEmpty || hadOthers {
            participants = listed
        }
        trackOwner = Dictionary(
            others.flatMap { person in person.tracks.map { ($0, person.name) } }
        ) { first, _ in first }

        if let keys, let envelopes = try? await keys.rosterChanged(
            call.participants.map(\.name), epoch: call.epoch, leader: call.keyLeader?.name
        ), !envelopes.isEmpty {
            try? await events?.send(.keys(epoch: call.epoch, envelopes))
        }

        wanted = Set(others.flatMap(\.trackRefs))
        await syncTracks()

        if !others.isEmpty {
            hadOthers = true
            apply(.answered)
        } else if hadOthers {
            await end(.remoteEnded)
        }
    }

    /// Pulls the others' new tracks and drops the ones that left. A pull before this phone's SFU session exists
    /// would go out without a session (404), so it waits for `start`; a failed pull is tried again shortly.
    private func syncTracks() async {
        guard mediaStarted else { return }
        let added = wanted.subtracting(subscribed)
        let removed = subscribed.subtracting(wanted)
        subscribed.subtract(removed)
        if !removed.isEmpty {
            await engine.unsubscribe(Array(removed))
        }
        guard !added.isEmpty else { return }
        subscribed.formUnion(added)
        do {
            try await engine.subscribe(added.sorted { $0.trackName < $1.trackName })
            pullAttempts = 0
        } catch {
            // The SFU may not have a just-published track yet: try again, backing off, for as long as the call is
            // live (tearDown cancels it). Never give up silently with one-way audio.
            subscribed.subtract(added)
            let delay = pullRetryDelay(pullAttempts)
            pullAttempts += 1
            let attempt = pullAttempts
            let reason = String(describing: error) // may hold the SFU's reply: private in logs
            Self.log.warning("Track pull refused (attempt \(attempt, privacy: .public)): \(reason, privacy: .private)")
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.syncTracks()
            }
        }
    }

    private static let log = Logger(subsystem: "ro.zapakid.app", category: "calls")

    /// 0.5 s, 1 s, 2 s, 4 s, then every 5 s.
    public nonisolated static func defaultPullRetryDelay(_ attempt: Int) -> Duration {
        min(.milliseconds(500) * (1 << min(attempt, 4)), .seconds(5))
    }

    private func handle(_ event: MediaEvent) {
        switch event {
        case .connected:
            reconnectTask?.cancel()
            apply(.mediaConnected)
        case .interrupted:
            guard apply(.mediaInterrupted) else { return }
            reconnectTask = Task { [weak self, reconnectTimeout] in
                try? await Task.sleep(for: reconnectTimeout)
                guard !Task.isCancelled else { return }
                await self?.end(.reconnectTimeout)
            }
        case let .levels(levels):
            for index in participants.indices {
                let tracks = trackOwner.filter { $0.value == participants[index].deviceId }.keys
                let level = tracks.compactMap { levels[$0] }.max() ?? 0
                participants[index].isSpeaking = level >= Self.speakingLevel
            }
        }
    }

    private func end(_ event: CallEvent) async {
        guard apply(event) else { return }
        await tearDown(leave: true)
    }

    private func fail(_ error: Error) {
        lastError = error as? CallsAPIError ?? .network
        apply(.failed)
        Task { await tearDown(leave: callId != nil) }
    }

    private func tearDown(leave: Bool) async {
        reconnectTask?.cancel()
        retryTask?.cancel()
        for task in tasks {
            task.cancel()
        }
        tasks = []
        if leave, let callId {
            try? await api.leave(callId: callId)
        }
        events?.close()
        events = nil
        await engine.stop()
    }

    @discardableResult
    private func apply(_ event: CallEvent) -> Bool {
        let changed = machine.handle(event)
        phase = machine.phase
        return changed
    }
}
