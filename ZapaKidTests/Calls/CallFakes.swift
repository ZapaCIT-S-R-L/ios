import Foundation
@testable import ZapaCalls

/// A calls service in memory: records the requests and lets the test push signals down the event socket.
final class FakeCallsAPI: CallsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var continuation: AsyncThrowingStream<CallSignal, Error>.Continuation?
    private var outgoing: [OutgoingSignal] = []
    var failCreate: CallsAPIError?

    var calls: [String] {
        lock.withLock { log }
    }

    var sent: [OutgoingSignal] {
        lock.withLock { outgoing }
    }

    private func record(_ line: String) {
        lock.withLock { log.append(line) }
    }

    func push(_ signal: CallSignal) {
        _ = lock.withLock { continuation }?.yield(signal)
    }

    func createCall(conversationId: String) async throws -> CallGrant {
        record("create \(conversationId)")
        if let failCreate {
            throw failCreate
        }
        return CallGrant(callId: "c_1", iceServers: [IceServer(urls: ["stun:stun.test.invalid"])], call: nil)
    }

    func join(callId: String) async throws -> CallGrant {
        record("join \(callId)")
        return CallGrant(callId: callId, iceServers: [], call: nil)
    }

    func leave(callId: String) async throws {
        record("leave \(callId)")
    }

    func decline(callId: String) async throws {
        record("decline \(callId)")
    }

    func newSession(callId _: String) async throws -> String {
        "s_me"
    }

    func addTracks(callId _: String, sessionId _: String, request _: TracksRequest) async throws -> TracksResponse {
        TracksResponse(requiresImmediateRenegotiation: false, sessionDescription: nil, tracks: [])
    }

    func renegotiate(callId _: String, sessionId _: String, answer _: SessionDescription) async throws {}

    func closeTracks(callId _: String, sessionId _: String, mids _: [String]) async throws -> TracksResponse {
        TracksResponse(requiresImmediateRenegotiation: false, sessionDescription: nil, tracks: [])
    }

    func openEvents(callId: String) async throws -> CallEventsConnection {
        record("events \(callId)")
        let (stream, continuation) = AsyncThrowingStream<CallSignal, Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return FakeEvents(stream: stream, api: self)
    }

    fileprivate func didSend(_ signal: OutgoingSignal) {
        lock.withLock { outgoing.append(signal) }
    }

    fileprivate func didClose() {
        record("close")
        lock.withLock { continuation }?.finish()
    }
}

private struct FakeEvents: CallEventsConnection {
    let stream: AsyncThrowingStream<CallSignal, Error>
    let api: FakeCallsAPI

    func signals() -> AsyncThrowingStream<CallSignal, Error> {
        stream
    }

    func send(_ signal: OutgoingSignal) async throws {
        api.didSend(signal)
    }

    func close() {
        api.didClose()
    }
}

/// The media engine without WebRTC: records what the controller asks for; the test drives its events.
final class FakeMediaEngine: CallMediaEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let keys = RecordingFrameKeys()
    let (events, eventContinuation) = AsyncStream<MediaEvent>.makeStream()

    var frameKeys: FrameKeyInstaller {
        keys
    }

    var calls: [String] {
        lock.withLock { log }
    }

    private func record(_ line: String) {
        lock.withLock { log.append(line) }
    }

    /// How long `start` takes (the SFU session and the mic track), so a roster can arrive meanwhile.
    var startDelay: Duration = .zero
    /// The next subscribes that fail (the SFU didn't have the track yet).
    var failingSubscribes = 0
    private var started = false

    func start(callId: String, iceServers _: [IceServer], api _: CallsAPI, trackName: String) async throws {
        record("start \(callId) \(trackName)")
        if startDelay > .zero {
            try? await Task.sleep(for: startDelay)
        }
        lock.withLock { started = true }
        record("started")
    }

    func subscribe(_ tracks: [TrackRef]) async throws {
        let names = tracks.map(\.trackName).joined(separator: ",")
        guard lock.withLock({ started }) else {
            record("subscribe before start \(names)")
            throw CallsAPIError.invalidResponse
        }
        let fail = lock.withLock {
            defer { failingSubscribes = max(0, failingSubscribes - 1) }
            return failingSubscribes > 0
        }
        record("subscribe \(names)\(fail ? " (failed)" : "")")
        if fail {
            throw CallsAPIError.invalidResponse
        }
    }

    func unsubscribe(_ tracks: [TrackRef]) async {
        record("unsubscribe \(tracks.map(\.trackName).joined(separator: ","))")
    }

    func setMuted(_ muted: Bool) {
        record("muted \(muted)")
    }

    func setSpeakerOn(_ speakerOn: Bool) {
        record("speaker \(speakerOn)")
    }

    func stop() async {
        record("stop")
    }

    func emit(_ event: MediaEvent) {
        eventContinuation.yield(event)
    }
}

/// Waits (up to 2 s by default) for a condition on the main actor; the controller works through async tasks.
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let tries = Int(timeout / .milliseconds(10))
    for _ in 0 ..< tries {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
