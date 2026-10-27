import Foundation
import Testing
@testable import ZapaCalls

/// Ringing on iOS: a content-free VoIP push → CallKit's native incoming call → the call controller. CallKit and
/// PushKit sit behind protocols (the real VoIP certificate comes later); these use fakes.
@MainActor
struct CallCoordinatorTests {
    let api = FakeCallsAPI()
    let engine = FakeMediaEngine()
    let system = FakeCallSystem()
    let mama = CallPeer(accountId: "acc-m", deviceId: "dev-m", displayName: "Mama", avatar: "robot-1", role: .parent)

    func coordinator() -> CallCoordinator {
        CallCoordinator(system: system, lookup: { [mama] account in account == "acc-m" ? mama : nil }) { [api, engine] in
            CallController(me: "dev-k", api: api, engine: engine, sealer: FakeCallKeySealer(me: "dev-k"))
        }
    }

    @Test func pushPayloadsCarryOnlyTheCallId() throws {
        let push = try #require(IncomingCallPush(payload: ["callId": "c_9", "callerAccountId": "acc-m"]))
        #expect(push.callId == "c_9")
        #expect(push.callerAccountId == "acc-m")
        #expect(IncomingCallPush(payload: ["aps": ["alert": "hi"]]) == nil)
        #expect(IncomingCallPush(payload: ["callId": ""]) == nil)
        #expect(IncomingCallPush(payload: ["callId": String(repeating: "x", count: 200)]) == nil)
    }

    @Test func aPushRingsThroughCallKitWithTheFamilyName() async throws {
        let calls = coordinator()

        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))

        let uuid = try #require(system.reported.first?.uuid)
        #expect(system.reported.first?.name == "Mama")
        #expect(calls.current?.phase == .ringing)
        #expect(calls.current?.callId == "c_9")
        #expect(calls.uuid(for: "c_9") == uuid)
    }

    @Test func anUnknownCallerShowsAsZapaKid() async {
        let calls = coordinator()

        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-unknown"))

        #expect(system.reported.first?.name == "ZapaKid")
    }

    @Test func answeringInCallKitJoinsTheCall() async throws {
        let calls = coordinator()
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))
        let uuid = try #require(system.reported.first?.uuid)

        await system.answer(uuid)

        #expect(api.calls.first == "join c_9")
        #expect(calls.current?.phase == .connecting)
    }

    @Test func endingARingingCallInCallKitDeclines() async throws {
        let calls = coordinator()
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))
        let uuid = try #require(system.reported.first?.uuid)

        await system.end(uuid)

        #expect(api.calls == ["decline c_9"])
        #expect(calls.current == nil)
    }

    @Test func aSecondCallWhileBusyIsDeclined() async throws {
        let calls = coordinator()
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))

        await calls.handle(IncomingCallPush(callId: "c_10", callerAccountId: "acc-m"))

        // CallKit still has to see the push (PushKit rule), then it ends at once.
        #expect(system.reported.count == 2)
        #expect(system.ended.map(\.reason) == [.declinedElsewhere])
        #expect(api.calls == ["decline c_10"])
        #expect(calls.current?.callId == "c_9")
    }

    @Test func outgoingCallsAreReportedAndConnectedInCallKit() async throws {
        let calls = coordinator()

        await calls.startCall(conversationId: "conv-1", peers: [mama])

        let uuid = try #require(system.started.first)
        engine.emit(.connected)
        api.push(.roster([
            RosterParticipant(accountId: "acc-k", deviceId: "dev-k", role: .kid),
            RosterParticipant(accountId: "acc-m", deviceId: "dev-m", role: .parent),
        ]))
        #expect(await eventually { system.connected.contains(uuid) })
    }

    @Test func whenTheCallEndsCallKitIsTold() async throws {
        let calls = coordinator()
        await calls.startCall(conversationId: "conv-1", peers: [mama])
        let uuid = try #require(system.started.first)

        api.push(.ringTimeout)

        #expect(await eventually { system.ended.first?.uuid == uuid })
        #expect(system.ended.first?.reason == .unanswered)
        #expect(await eventually { calls.current == nil })
    }

    @Test func muteFromCallKitMutesTheCall() async throws {
        let calls = coordinator()
        await calls.startCall(conversationId: "conv-1", peers: [mama])
        let uuid = try #require(system.started.first)

        await system.mute(uuid, true)

        #expect(calls.current?.isMuted == true)
    }

    @Test func endedCallsGoToTheLog() async throws {
        let log = InMemoryCallLog()
        let calls = CallCoordinator(system: system, log: log, lookup: { _ in nil }) { [api, engine] in
            CallController(me: "dev-k", api: api, engine: engine, sealer: FakeCallKeySealer(me: "dev-k"))
        }
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: nil))
        let uuid = try #require(system.reported.first?.uuid)

        await system.end(uuid)

        let entries = await log.entries()
        #expect(entries.first?.id == "c_9")
        #expect(entries.first?.outcome == .declined)
        #expect(entries.first?.direction == .incoming)
    }
}

/// CallKit in memory.
@MainActor
final class FakeCallSystem: CallSystem {
    struct Reported {
        let uuid: UUID
        let name: String
    }

    var actions: CallSystemActions?
    private(set) var reported: [Reported] = []
    private(set) var started: [UUID] = []
    private(set) var connected: [UUID] = []
    private(set) var ended: [(uuid: UUID, reason: CallSystemEndReason)] = []

    func reportIncoming(uuid: UUID, callerName: String) async throws {
        reported.append(Reported(uuid: uuid, name: callerName))
    }

    func startOutgoing(uuid: UUID, name _: String) async throws {
        started.append(uuid)
    }

    func reportConnected(uuid: UUID) {
        connected.append(uuid)
    }

    func reportEnded(uuid: UUID, reason: CallSystemEndReason) {
        ended.append((uuid, reason))
    }

    func answer(_ uuid: UUID) async {
        await actions?.answer(uuid)
    }

    func end(_ uuid: UUID) async {
        await actions?.end(uuid)
    }

    func mute(_ uuid: UUID, _ muted: Bool) async {
        await actions?.setMuted(uuid, muted)
    }
}
