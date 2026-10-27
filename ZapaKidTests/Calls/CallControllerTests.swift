import Foundation
import Testing
@testable import ZapaCalls

/// One call from the phone's side: the calls API, the event socket, the key rotation and the media engine together.
/// Devices are `<accountId>.<deviceId>`; names and robots come from the family directory.
@MainActor
struct CallControllerTests {
    let api = FakeCallsAPI()
    let engine = FakeMediaEngine()
    let mama = CallPeer(accountId: "acc-m", deviceId: "acc-m.1", displayName: "Mama", avatar: "robot-1", role: .parent)
    let kid = CallPeer(accountId: "acc-k", deviceId: "acc-k.1", displayName: "Ana", avatar: "robot-4", role: .kid)

    func controller(me device: String = "acc-k.1") -> CallController {
        let people = [mama, kid]
        return CallController(
            me: device, api: api, engine: engine, sealer: FakeCallKeySealer(me: device), reconnectTimeout: .seconds(1),
            directory: { account in people.first { $0.accountId == account } }
        )
    }

    /// A roster from the server: the given devices, all with a session and their mic track.
    func roster(_ devices: [String], epoch: UInt32 = 1, leader: String? = nil) -> CallSignal {
        .roster(CallSnapshot(
            callId: "c_1", state: .active, epoch: epoch,
            keyLeader: (leader ?? devices.first).flatMap(CallDevice.init(name:)),
            participants: devices.compactMap { name in
                CallDevice(name: name).map {
                    RosterParticipant(
                        accountId: $0.accountId, deviceId: $0.deviceId, role: $0.accountId == "acc-k" ? .kid : .parent,
                        sessionId: "s_\($0.accountId)", tracks: [CallController.trackName(for: name)]
                    )
                }
            }
        ))
    }

    @Test func anOutgoingCallRingsThenConnectsWhenSomeoneJoins() async throws {
        let call = controller()

        await call.startCall(conversationId: "conv-1", peers: [mama])

        #expect(call.phase == .calling)
        #expect(call.participants.map(\.displayName) == ["Mama"])
        #expect(api.calls == ["create conv-1", "events c_1"])
        #expect(engine.calls == ["start c_1 audio-acc-k_1"])

        api.push(roster(["acc-k.1", "acc-m.1"]))
        #expect(await eventually { call.phase == .connecting })
        #expect(await eventually { engine.calls.contains("subscribe audio-acc-m_1") })
        #expect(call.participants.first?.displayName == "Mama", "names come from the directory")
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })
    }

    @Test func theServersLeaderSendsOneKeysBatchForTheServersEpoch() async throws {
        let call = controller(me: "acc-k.1")
        await call.startCall(conversationId: "conv-1", peers: [mama])

        api.push(roster(["acc-k.1", "acc-m.1"], epoch: 9, leader: "acc-k.1"))

        #expect(await eventually { api.sent.count == 1 })
        guard case let .keys(epoch, envelopes) = api.sent.first else { Issue.record("no keys sent"); return }
        #expect(epoch == 9)
        #expect(envelopes.map(\.toDevice) == ["acc-m.1"])
        #expect(engine.keys.sendingEpoch == 9)
    }

    @Test func aKeyFromTheLeaderIsInstalledInTheEngine() async throws {
        let call = controller(me: "acc-k.1")
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(roster(["acc-m.1", "acc-k.1"], epoch: 5, leader: "acc-m.1"))
        let key = CallKey.random(epoch: 5)
        let blob = try await FakeCallKeySealer(me: "acc-m.1")
            .seal(CallKeyMaterial.encode(key, callId: "c_1"), toDevice: "acc-k.1")

        api.push(.key(KeyEnvelope(epoch: 5, fromDevice: "acc-m.1", toDevice: "acc-k.1", blob: blob)))

        #expect(await eventually { engine.keys.installed.last == key })
        #expect(engine.keys.sendingEpoch == 5)
    }

    @Test func anIncomingCallIsAcceptedAndJoined() async throws {
        let call = controller()
        call.reportIncoming(callId: "c_9", caller: mama)
        #expect(call.phase == .ringing)

        await call.accept()

        #expect(call.phase == .connecting)
        #expect(api.calls == ["join c_9", "events c_9"])
        #expect(engine.calls == ["start c_9 audio-acc-k_1"])
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

    @Test func nobodyAnsweringEndsTheCall() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])

        api.push(.ended(reason: "no_answer"))

        #expect(await eventually { call.phase == .ended(.noAnswer) })
        #expect(await eventually { engine.calls.last == "stop" })
    }

    @Test func whenTheOthersLeaveTheCallEnds() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(roster(["acc-k.1", "acc-m.1"]))
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        api.push(roster(["acc-k.1"], epoch: 2))

        #expect(await eventually { call.phase == .ended(.remoteEnded) })
        #expect(await eventually { api.calls.contains("leave c_1") })
    }

    @Test func aDroppedConnectionReconnectsOrGivesUp() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(roster(["acc-k.1", "acc-m.1"]))
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        engine.emit(.interrupted)
        #expect(await eventually { call.phase == .reconnecting })
        engine.emit(.connected)
        #expect(await eventually { call.phase == .active })

        engine.emit(.interrupted)
        #expect(await eventually { call.phase == .ended(.failed) })
    }

    @Test func muteAndSpeakerGoToTheEngine() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])

        await call.setMuted(true)
        call.setSpeakerOn(true)

        #expect(call.isMuted)
        #expect(call.isSpeakerOn)
        #expect(engine.calls.contains("muted true"))
        #expect(engine.calls.contains("speaker true"))
    }

    @Test func audioLevelsLightUpWhoIsSpeaking() async {
        let call = controller()
        await call.startCall(conversationId: "conv-1", peers: [mama])
        api.push(roster(["acc-k.1", "acc-m.1"]))
        #expect(await eventually { engine.calls.contains("subscribe audio-acc-m_1") })

        engine.emit(.levels(["audio-acc-m_1": 0.6]))

        #expect(await eventually { call.participants.first?.isSpeaking == true })
        engine.emit(.levels(["audio-acc-m_1": 0.01]))
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
