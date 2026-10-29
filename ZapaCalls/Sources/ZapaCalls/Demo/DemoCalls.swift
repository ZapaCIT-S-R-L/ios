#if DEBUG
    import Foundation

    /// A pretend call for SwiftUI previews and the UI tests (Debug builds only): no network, no microphone.
    /// The others answer after a moment, and the first of them keeps "speaking".
    public enum DemoCalls {
        public static let me = "acc-me.1"
        public static let mama = CallPeer(
            accountId: "acc-m", deviceId: "acc-m.1", displayName: "Mama", avatar: "robot-2", role: .parent
        )
        public static let tata = CallPeer(
            accountId: "acc-t", deviceId: "acc-t.1", displayName: "Tata", avatar: "robot-6", role: .parent
        )
        public static let ana = CallPeer(
            accountId: "acc-a", deviceId: "acc-a.1", displayName: "Ana", avatar: "robot-9", role: .kid
        )

        @MainActor
        public static func controller(peers: [CallPeer]) -> CallController {
            let peers = peers.map(DemoCallsAPI.named)
            let engine = DemoMediaEngine(speaker: peers.first.map { CallController.trackName(for: $0.deviceId) })
            return CallController(
                me: me, api: DemoCallsAPI(peers: peers), engine: engine, sealer: DemoSealer(),
                directory: { account in peers.first { $0.accountId == account } }
            )
        }
    }

    final class DemoCallsAPI: CallsAPI, @unchecked Sendable {
        let peers: [CallPeer]
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<CallSignal, Error>.Continuation?

        init(peers: [CallPeer]) {
            self.peers = peers
        }

        /// A peer with a device name (`<accountId>.1` when it has none).
        static func named(_ peer: CallPeer) -> CallPeer {
            var peer = peer
            if CallDevice(name: peer.deviceId) == nil {
                peer.deviceId = "\(peer.accountId).1"
            }
            return peer
        }

        private var roster: CallSnapshot {
            let names = [DemoCalls.me] + peers.map(\.deviceId)
            return CallSnapshot(
                callId: "demo-call", state: .active, epoch: 1, keyLeader: CallDevice(name: DemoCalls.me),
                participants: names.compactMap { name in
                    CallDevice(name: name).map {
                        RosterParticipant(
                            accountId: $0.accountId, deviceId: $0.deviceId,
                            role: peers.first { $0.deviceId == name }?.role ?? .kid, sessionId: "s_\($0.accountId)",
                            tracks: [CallController.trackName(for: name)]
                        )
                    }
                }
            )
        }

        func createCall(conversationId _: String) async throws -> CallGrant {
            CallGrant(callId: "demo-call", iceServers: [], call: nil)
        }

        func join(callId: String) async throws -> CallGrant {
            CallGrant(callId: callId, iceServers: [], call: nil)
        }

        func leave(callId _: String) async throws {}
        func decline(callId _: String) async throws {}

        func newSession(callId _: String) async throws -> String {
            "s_me"
        }

        func addTracks(callId _: String, sessionId _: String, request _: TracksRequest) async throws -> TracksResponse {
            TracksResponse()
        }

        func renegotiate(callId _: String, sessionId _: String, answer _: SessionDescription) async throws {}

        func closeTracks(callId _: String, sessionId _: String, mids _: [String]) async throws -> TracksResponse {
            TracksResponse()
        }

        func openEvents(callId _: String) async throws -> CallEventsConnection {
            let (stream, continuation) = AsyncThrowingStream<CallSignal, Error>.makeStream()
            lock.withLock { self.continuation = continuation }
            let roster = roster
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                continuation.yield(.roster(roster))
            }
            return DemoEvents(stream: stream, continuation: continuation)
        }
    }

    private struct DemoEvents: CallEventsConnection {
        let stream: AsyncThrowingStream<CallSignal, Error>
        let continuation: AsyncThrowingStream<CallSignal, Error>.Continuation

        func signals() -> AsyncThrowingStream<CallSignal, Error> {
            stream
        }

        func send(_: OutgoingSignal) async throws {}

        func close() {
            continuation.finish()
        }
    }

    final class DemoMediaEngine: CallMediaEngine, @unchecked Sendable {
        let frameKeys: FrameKeyInstaller = DemoFrameKeys()
        let events: AsyncStream<MediaEvent>
        private let continuation: AsyncStream<MediaEvent>.Continuation
        private let speaker: String?
        private let lock = NSLock()
        private var ticker: Task<Void, Never>?

        init(speaker: String?) {
            (events, continuation) = AsyncStream<MediaEvent>.makeStream()
            self.speaker = speaker
        }

        func start(callId _: String, iceServers _: [IceServer], api _: CallsAPI, trackName _: String) async throws {
            let task = Task { [continuation, speaker] in
                try? await Task.sleep(for: .milliseconds(1500))
                continuation.yield(.connected)
                while !Task.isCancelled {
                    if let speaker {
                        continuation.yield(.levels([speaker: 0.5]))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            lock.withLock { ticker = task }
        }

        func subscribe(_: [TrackRef]) async throws {}
        func unsubscribe(_: [TrackRef]) async {}
        func setMuted(_: Bool) {}
        func setSpeakerOn(_: Bool) {}

        func stop() async {
            lock.withLock { ticker }?.cancel()
        }
    }

    private struct DemoFrameKeys: FrameKeyInstaller {
        func install(_: CallKey) {}
        func useForSending(epoch _: UInt32) {}
    }

    private struct DemoSealer: CallKeySealer {
        func seal(_ keyMaterial: Data, toDevice _: String) async throws -> Data {
            keyMaterial
        }

        func open(_ blob: Data, fromDevice _: String) async throws -> Data {
            blob
        }
    }
#endif
