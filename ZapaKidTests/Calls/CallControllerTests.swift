import Foundation
import Testing
@testable import ZapaCalls

/// One call from the phone's side: the calls API, the event socket, the key rotation and the media engine together.
@MainActor
struct CallControllerTests {
    let api = FakeCallsAPI()
    let engine = FakeMediaEngine()
    let mama = CallPeer(accountId: "acc-m", deviceId: "dev-m", displayName: "Mama", avatar: "robot-1", role: .parent)
    let kid = CallPeer(accountId: "acc-k", deviceId: "dev-k", displayName: "Ana", avatar: "robot-4", role: .kid)

    func controller(me device: String = "dev-k") -> CallController {
        CallController(
            me: device, api: api, engine: engine, sealer: FakeCallKeySealer(me: device), reconnectTimeout: .seconds(1)
        )
    }

    func participant(_ peer: CallPeer, tracks: [String] = []) -> RosterParticipant {
        RosterParticipant(
            accountId: peer.accountId, deviceId: peer.deviceId, role: peer.role, displayName: peer.displayName,
            avatar: peer.avatar, muted: false,
            tracks: tracks.map { TrackRef(sessionId: "s_\(peer.deviceId)", trackName: $0) }
        )
    }

    @Test func anOutgoingCallRingsThenConnectsWhenSomeoneJoins() async throws {
        let call = controller()

        await call.startCall(conversationId: "conv-1", peers: [mama])

        #expect(call.phase == .calling)
        #expect(call.participants.map(\.displayName) == ["Mama"], "the callee shows while it rings")
        #expect(api.calls == ["create conv-1", "events c_1"])
        #expect(engine.calls == ["start c_1 audio-dev-k"])

        api.push(.roster([participant(kid, tracks: ["audio-dev-k"]), participant(mama, tracks: ["audio-dev-m"])]))
        #expect(await eventually { call.phase == .connecting })
        #expect(await eventually { engine.calls.contains("subscribe audio-dev-m") })
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })
        #expect(call.connectedAt != nil)
    }

    @Test func theLeaderSendsTheNewKeyOnEveryJoinAndInstallsIt() async throws {
        let call = controller(me: "dev-a")
        await call.startCall(conversationId: "conv-1", peers: [mama])

        api.push(.roster([
            RosterParticipant(accountId: "acc-a", deviceId: "dev-a", role: .parent, tracks: []),
            participant(mama),
        ]))

        #expect(await eventually { api.sent.count == 1 })
        guard case let .key(envelope) = api.sent.first else { Issue.record("no key sent"); return }
        #expect(envelope.toDevice == "dev-m")
        #expect(envelope.fromDevice == "dev-a")
        #expect(engine.keys.sendingEpoch == envelope.epoch)
    }

    @Test func aKeyFromTheLeaderIsInstalledInTheEngine() async throws {
        let call = controller(me: "dev-z")
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(.roster([participant(mama), RosterParticipant(accountId: "z", deviceId: "dev-z", role: .kid)]))
        let key = CallKey.random(epoch: 5)
        let blob = try await FakeCallKeySealer(me: "dev-m")
            .seal(CallKeyMaterial.encode(key, callId: "c_1"), toDevice: "dev-z")

        api.push(.key(KeyEnvelope(epoch: 5, fromDevice: "dev-m", toDevice: "dev-z", blob: blob)))

        #expect(await eventually { engine.keys.installed.last == key })
        #expect(engine.keys.sendingEpoch == 5)
    }

    @Test func anIncomingCallIsAcceptedAndJoined() async throws {
        let call = controller()
        call.reportIncoming(callId: "c_9", caller: mama)
        #expect(call.phase == .ringing)
        #expect(call.participants.map(\.displayName) == ["Mama"])

        await call.accept()

        #expect(call.phase == .connecting)
        #expect(api.calls == ["join c_9", "events c_9"])
        #expect(engine.calls == ["start c_9 audio-dev-k"])
    }

    @Test func declineTellsTheServiceAndEnds() async {
        let call = controller()
        call.reportIncoming(callId: "c_9", caller: mama)

        await call.decline()

        #expect(call.phase == .ended(.declined))
        #expect(api.calls == ["decline c_9"])
    }

    @Test func hangUpLeavesStopsTheMediaAndClosesTheSocket() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])

        await call.hangUp()

        #expect(call.phase == .ended(.hungUp))
        #expect(api.calls.suffix(2) == ["leave c_1", "close"])
        #expect(engine.calls.last == "stop")
    }

    @Test func nobodyAnsweringEndsTheCallAfterTheRingTimeout() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])

        api.push(.ringTimeout)

        #expect(await eventually { call.phase == .ended(.noAnswer) })
        #expect(await eventually { engine.calls.last == "stop" })
    }

    @Test func whenTheOthersLeaveTheCallEnds() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(.roster([participant(kid), participant(mama, tracks: ["audio-dev-m"])]))
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        api.push(.left(deviceId: "dev-m"))

        #expect(await eventually { call.phase == .ended(.remoteEnded) })
        #expect(await eventually { api.calls.contains("leave c_1") })
    }

    @Test func aDroppedConnectionReconnectsOrGivesUp() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(.roster([participant(kid), participant(mama)]))
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        engine.emit(.interrupted)
        #expect(await eventually { call.phase == .reconnecting })
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        engine.emit(.interrupted)
        #expect(await eventually { call.phase == .ended(.failed) })
    }

    @Test func muteAndSpeakerGoToTheEngineAndMuteIsShared() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])

        await call.setMuted(true)
        call.setSpeakerOn(true)

        #expect(call.isMuted)
        #expect(call.isSpeakerOn)
        #expect(engine.calls.contains("muted true"))
        #expect(engine.calls.contains("speaker true"))
        #expect(api.sent.contains(.muted(true)))
    }

    @Test func audioLevelsLightUpWhoIsSpeaking() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(.roster([participant(kid), participant(mama, tracks: ["audio-dev-m"])]))
        #expect(await eventually { call.participants.first?.deviceId == "dev-m" })

        engine.emit(.levels(["audio-dev-m": 0.6]))

        #expect(await eventually { call.participants.first?.isSpeaking == true })
        engine.emit(.levels(["audio-dev-m": 0.01]))
        #expect(await eventually { call.participants.first?.isSpeaking == false })
    }

    @Test func aFailedCreateEndsWithAFriendlyError() async {
        api.failCreate = .callFull
        let call = controller()

        await call.startCall(conversationId: "conv-1", peers: [mama])

        #expect(call.phase == .ended(.failed))
        #expect(call.lastError == .callFull)
        #expect(engine.calls.isEmpty)
    }
}
