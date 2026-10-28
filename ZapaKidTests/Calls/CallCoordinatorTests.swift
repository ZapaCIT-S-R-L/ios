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

    func makeController() -> CallController {
        CallController(me: "acc-k.1", api: api, engine: engine, sealer: FakeCallKeySealer(me: "acc-k.1"))
    }

    func coordinator() -> CallCoordinator {
        let mama = mama
        return CallCoordinator(
            system: system,
            lookup: { account in account == "acc-m" ? mama : nil },
            makeController: makeController
        )
    }

    /// Answering with the app's own button left CallKit's banner ringing until it was answered again
    /// (Stefan, 2026-10-29): the app's buttons must go through CallKit.
    @Test func answeringInTheAppAnswersThroughCallKit() async throws {
        let calls = coordinator()
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))
        let uuid = try #require(system.reported.first?.uuid)

        await calls.accept()

        #expect(system.answerRequests == [uuid])
        #expect(await eventually { api.calls.contains("join c_9") })
    }

    @Test func decliningOrHangingUpInTheAppEndsThroughCallKit() async throws {
        let calls = coordinator()
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: "acc-m"))
        let uuid = try #require(system.reported.first?.uuid)

        await calls.hangUp()

        #expect(system.endRequests == [uuid])
        #expect(await eventually { api.calls.contains("decline c_9") })
        #expect(calls.current == nil)
    }

    /// After a call closes the screen, the caller sees why in a short banner: declined, no answer or interrupted.
    /// A normal hang-up shows nothing.
    @Test func aDeclinedOutgoingCallLeavesANoticeWithTheName() async {
        let calls = coordinator()
        await calls.startCall(conversationId: "conv-1", peers: [mama])

        api.push(.ended(reason: "declined"))

        #expect(await eventually { calls.current == nil })
        #expect(calls.notice == CallNotice(reason: .declined, names: ["Mama"]))
        calls.clearNotice()
        #expect(calls.notice == nil)
    }

    @Test func hangingUpLeavesNoNotice() async {
        let calls = coordinator()
        await calls.startCall(conversationId: "conv-1", peers: [mama])

        await calls.current?.hangUp()

        #expect(await eventually { calls.current == nil })
        #expect(calls.notice == nil)
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

    @Test func aSecondCallWhileBusyIsDeclined() async {
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
        api.push(.roster(CallSnapshot(
            callId: "c_1", state: .active, epoch: 2, keyLeader: CallDevice(accountId: "acc-m", deviceId: 1),
            participants: [
                RosterParticipant(accountId: "acc-k", deviceId: 1, role: .kid, sessionId: "s_k", tracks: []),
                RosterParticipant(accountId: "acc-m", deviceId: 1, role: .parent, sessionId: "s_m", tracks: []),
            ]
        )))
        #expect(await eventually { system.connected.contains(uuid) })
    }

    @Test func whenTheCallEndsCallKitIsTold() async throws {
        let calls = coordinator()
        await calls.startCall(conversationId: "conv-1", peers: [mama])
        let uuid = try #require(system.started.first)

        api.push(.ended(reason: "no_answer"))

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
        let calls = CallCoordinator(system: system, log: log, lookup: { _ in nil }, makeController: makeController)
        await calls.handle(IncomingCallPush(callId: "c_9", callerAccountId: nil))
        let uuid = try #require(system.reported.first?.uuid)

        await system.end(uuid)

        var entries: [CallLogEntry] = []
        for _ in 0 ..< 200 where entries.isEmpty {
            entries = await log.entries()
            try await Task.sleep(for: .milliseconds(10))
        }
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

    private(set) var answerRequests: [UUID] = []
    private(set) var endRequests: [UUID] = []

    /// Like CallKit: the request comes back as the system's answer or end action.
    func requestAnswer(uuid: UUID) async throws {
        answerRequests.append(uuid)
        await actions?.answer(uuid)
    }

    func requestEnd(uuid: UUID) async throws {
        endRequests.append(uuid)
        await actions?.end(uuid)
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
