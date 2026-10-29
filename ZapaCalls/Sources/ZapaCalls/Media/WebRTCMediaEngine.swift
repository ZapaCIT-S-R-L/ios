import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC

/// Voice over Cloudflare Realtime (SFU) through the calls service's proxy: one peer connection, the microphone
/// published as `audio-<device>`, remote tracks pulled per participant. Every frame passes the FrameCryptor
/// (AES-GCM, `WebRTCFrameKeys`) both ways, so Cloudflare only ever relays ciphertext. Video-ready: the same
/// session takes video transceivers later.
public final class WebRTCMediaEngine: NSObject, CallMediaEngine, @unchecked Sendable {
    public let events: AsyncStream<MediaEvent>
    public var frameKeys: FrameKeyInstaller {
        keys
    }

    private let continuation: AsyncStream<MediaEvent>.Continuation
    let keys = WebRTCFrameKeys()
    let factory: LKRTCPeerConnectionFactory
    private let queue = DispatchQueue(label: "ro.zapakid.calls.media")
    var connection: LKRTCPeerConnection?
    private var microphone: LKRTCAudioTrack?
    private var api: CallsAPI?
    private var callId = ""
    private var sessionId = ""
    private var me = ""
    /// Remote track name by transceiver mid, and the receive cryptors.
    private var remoteMids: [String: TrackRef] = [:]
    private var receivers: [String: LKRTCFrameCryptor] = [:]
    private var levelTask: Task<Void, Never>?

    override public init() {
        CallAudio.leaveSessionToCallKit()
        LKRTCInitializeSSL()
        factory = LKRTCPeerConnectionFactory()
        (events, continuation) = AsyncStream<MediaEvent>.makeStream()
        super.init()
    }

    // MARK: CallMediaEngine

    public func start(callId: String, iceServers: [IceServer], api: CallsAPI, trackName: String) async throws {
        self.api = api
        self.callId = callId
        me = trackName
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map {
            LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw CallsAPIError.invalidResponse
        }
        self.connection = connection

        let source = factory.audioSource(with: constraints)
        let microphone = factory.audioTrack(with: source, trackId: trackName)
        self.microphone = microphone
        let initial = LKRTCRtpTransceiverInit()
        initial.direction = .sendOnly
        guard let transceiver = connection.addTransceiver(with: microphone, init: initial),
              let sender = LKRTCFrameCryptor(
                  factory: factory, rtpSender: transceiver.sender, participantId: trackName, algorithm: .aesGcm,
                  keyProvider: keys.provider
              )
        else { throw CallsAPIError.invalidResponse }
        sender.enabled = true
        keys.addSender(sender)

        sessionId = try await api.newSession(callId: callId)
        let offer = try await makeOffer()
        let reply = try await api.addTracks(callId: callId, sessionId: sessionId, request: TracksRequest(
            sessionDescription: SessionDescription(type: .offer, sdp: offer),
            tracks: [TrackObject(location: .local, mid: transceiver.mid, trackName: trackName)]
        ))
        guard let answer = reply.sessionDescription else { throw CallsAPIError.invalidResponse }
        try await setRemote(answer)
        startLevels()
    }

    /// Pulls these tracks. Idempotent: tracks already pulled are skipped, so the controller may retry. Throws when the
    /// SFU refused any of them (it may not have a just-published track yet), after negotiating the others.
    public func subscribe(_ tracks: [TrackRef]) async throws {
        guard let api, !sessionId.isEmpty else { throw CallsAPIError.invalidResponse }
        let pulled = queue.sync { Set(remoteMids.values) }
        let tracks = tracks.filter { !pulled.contains($0) }
        guard !tracks.isEmpty else { return }
        let reply = try await api.addTracks(callId: callId, sessionId: sessionId, request: TracksRequest(
            tracks: tracks.map { TrackObject(location: .remote, trackName: $0.trackName, sessionId: $0.sessionId) }
        ))
        for result in reply.tracks ?? [] {
            if let mid = result.mid, let name = result.trackName,
               let track = tracks.first(where: { $0.trackName == name })
            {
                queue.sync { remoteMids[mid] = track }
            }
        }
        if let offer = reply.sessionDescription, offer.type == .offer {
            try await setRemote(offer)
            let answer = try await makeAnswer()
            try await api.renegotiate(
                callId: callId, sessionId: sessionId, answer: SessionDescription(type: .answer, sdp: answer)
            )
        }
        attachReceiveCryptors()
        if reply.tracks?.contains(where: { $0.errorCode != nil }) ?? true {
            throw CallsAPIError.invalidResponse
        }
    }

    public func unsubscribe(_ tracks: [TrackRef]) async {
        guard let api else { return }
        let names = Set(tracks.map(\.trackName))
        let mids = queue.sync { remoteMids.filter { names.contains($0.value.trackName) }.map(\.key) }
        guard !mids.isEmpty else { return }
        queue.sync {
            for mid in mids {
                remoteMids[mid] = nil
                receivers[mid] = nil
            }
        }
        if let reply = try? await api.closeTracks(callId: callId, sessionId: sessionId, mids: mids),
           let offer = reply.sessionDescription, offer.type == .offer
        {
            try? await setRemote(offer)
            if let answer = try? await makeAnswer() {
                try? await api.renegotiate(
                    callId: callId, sessionId: sessionId, answer: SessionDescription(type: .answer, sdp: answer)
                )
            }
        }
    }

    public func setMuted(_ muted: Bool) {
        microphone?.isEnabled = !muted
    }

    public func setSpeakerOn(_ speakerOn: Bool) {
        #if os(iOS)
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            try? session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        #endif
    }

    /// CallKit activated or deactivated the audio session (use with `CallCoordinator.onAudioSessionChange`).
    public func audioSession(active: Bool) {
        #if os(iOS)
            let session = LKRTCAudioSession.sharedInstance()
            if active {
                session.audioSessionDidActivate(AVAudioSession.sharedInstance())
            } else {
                session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
            }
            session.isAudioEnabled = active
        #endif
    }

    public func stop() async {
        levelTask?.cancel()
        keys.removeAll()
        queue.sync {
            receivers.removeAll()
            remoteMids.removeAll()
        }
        connection?.close()
        connection = nil
        microphone = nil
    }

    // MARK: SDP

    func makeOffer() async throws -> String {
        guard let connection else { throw CallsAPIError.invalidResponse }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { done in
            connection.offer(for: constraints) { sdp, error in
                if let sdp {
                    done.resume(returning: sdp)
                } else {
                    done.resume(throwing: error ?? CallsAPIError.invalidResponse)
                }
            }
        }
        let capped = OpusBitrate.capping(offer.sdp, kbps: OpusBitrate.configuredKbps)
        try await setLocal(LKRTCSessionDescription(type: offer.type, sdp: capped))
        return capped
    }

    private func makeAnswer() async throws -> String {
        guard let connection else { throw CallsAPIError.invalidResponse }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { done in
            connection.answer(for: constraints) { sdp, error in
                if let sdp {
                    done.resume(returning: sdp)
                } else {
                    done.resume(throwing: error ?? CallsAPIError.invalidResponse)
                }
            }
        }
        let capped = OpusBitrate.capping(answer.sdp, kbps: OpusBitrate.configuredKbps)
        try await setLocal(LKRTCSessionDescription(type: answer.type, sdp: capped))
        return capped
    }

    private func setLocal(_ description: LKRTCSessionDescription) async throws {
        guard let connection else { throw CallsAPIError.invalidResponse }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    done.resume(throwing: error)
                } else {
                    done.resume()
                }
            }
        }
    }

    private func setRemote(_ description: SessionDescription) async throws {
        guard let connection else { throw CallsAPIError.invalidResponse }
        let remote = LKRTCSessionDescription(type: description.type == .offer ? .offer : .answer, sdp: description.sdp)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(remote) { error in
                if let error {
                    done.resume(throwing: error)
                } else {
                    done.resume()
                }
            }
        }
    }

    /// A receive cryptor on every remote audio transceiver that doesn't have one yet.
    private func attachReceiveCryptors() {
        guard let connection else { return }
        for transceiver in connection.transceivers where transceiver.mediaType == .audio {
            let mid = transceiver.mid
            guard let track = queue.sync(execute: { remoteMids[mid] }), queue.sync(execute: { receivers[mid] }) == nil,
                  let cryptor = LKRTCFrameCryptor(
                      factory: factory, rtpReceiver: transceiver.receiver, participantId: track.trackName,
                      algorithm: .aesGcm, keyProvider: keys.provider
                  )
            else { continue }
            cryptor.enabled = true
            queue.sync { receivers[mid] = cryptor }
        }
    }

    // MARK: Levels

    /// Audio levels per remote track from the inbound-rtp stats, three times a second.
    private func startLevels() {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(330))
                guard let self, let connection else { return }
                let levels: [String: Float] = await withCheckedContinuation { done in
                    connection.statistics { report in
                        var levels: [String: Float] = [:]
                        for stats in report.statistics.values where stats.type == "inbound-rtp" {
                            if let mid = stats.values["mid"] as? String,
                               let track = self.queue.sync(execute: { self.remoteMids[mid] }),
                               let level = stats.values["audioLevel"] as? NSNumber
                            {
                                levels[track.trackName] = level.floatValue
                            }
                        }
                        done.resume(returning: levels)
                    }
                }
                if !levels.isEmpty {
                    continuation.yield(.levels(levels))
                }
            }
        }
    }
}

extension WebRTCMediaEngine: LKRTCPeerConnectionDelegate {
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        switch newState {
        case .connected, .completed: continuation.yield(.connected)
        case .disconnected, .failed: continuation.yield(.interrupted)
        default: break
        }
    }

    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}
    public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
}
