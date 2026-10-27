import Foundation
import Testing
@testable import ZapaCalls

/// The states a call goes through, as the kid and the parent see them: calling…, ringing, connecting, in the
/// call, reconnecting, ended.
struct CallStateMachineTests {
    func run(_ events: [CallEvent], from start: CallPhase = .idle) -> CallStateMachine {
        var machine = CallStateMachine(phase: start)
        for event in events {
            machine.handle(event)
        }
        return machine
    }

    @Test func anOutgoingCallIsAnsweredAndConnects() {
        #expect(run([.placeCall]).phase == .calling)
        #expect(run([.placeCall, .answered]).phase == .connecting)
        #expect(run([.placeCall, .answered, .mediaConnected]).phase == .active)
    }

    @Test func mediaThatIsAlreadyUpGoesStraightToTheCallWhenAnswered() {
        #expect(run([.placeCall, .mediaConnected]).phase == .calling)
        #expect(run([.placeCall, .mediaConnected, .answered]).phase == .active)
    }

    @Test func anIncomingCallRingsAndIsAccepted() {
        #expect(run([.incoming]).phase == .ringing)
        #expect(run([.incoming, .accept]).phase == .connecting)
        #expect(run([.incoming, .accept, .mediaConnected]).phase == .active)
    }

    @Test func anIncomingCallIsDeclinedOrMissed() {
        #expect(run([.incoming, .decline]).phase == .ended(.declined))
        #expect(run([.incoming, .ringTimeout]).phase == .ended(.missed))
        #expect(run([.incoming, .remoteEnded]).phase == .ended(.missed))
    }

    @Test func nobodyAnswersAnOutgoingCall() {
        #expect(run([.placeCall, .ringTimeout]).phase == .ended(.noAnswer))
        #expect(run([.placeCall, .everyoneDeclined]).phase == .ended(.declined))
    }

    @Test func aDroppedConnectionReconnectsOrFails() {
        let active: [CallEvent] = [.placeCall, .answered, .mediaConnected]
        #expect(run(active + [.mediaInterrupted]).phase == .reconnecting)
        #expect(run(active + [.mediaInterrupted, .mediaConnected]).phase == .active)
        #expect(run(active + [.mediaInterrupted, .reconnectTimeout]).phase == .ended(.failed))
    }

    @Test func hangingUpOrTheOthersLeavingEndsTheCall() {
        let active: [CallEvent] = [.incoming, .accept, .mediaConnected]
        #expect(run(active + [.hangUp]).phase == .ended(.hungUp))
        #expect(run(active + [.remoteEnded]).phase == .ended(.remoteEnded))
        #expect(run([.placeCall, .hangUp]).phase == .ended(.hungUp))
        #expect(run(active + [.failed]).phase == .ended(.failed))
    }

    @Test func endedIsFinal() {
        let machine = run([.incoming, .decline, .accept, .mediaConnected, .incoming])
        #expect(machine.phase == .ended(.declined))
    }

    @Test func eventsThatDontFitTheStateAreIgnored() {
        var machine = CallStateMachine()
        #expect(machine.handle(.accept) == false)
        #expect(machine.phase == .idle)
        #expect(machine.handle(.placeCall) == true)
        #expect(machine.handle(.incoming) == false)
        #expect(machine.phase == .calling)
    }

    @Test func theCallClockStartsWhenTheCallIsFirstActive() {
        var now = Date(timeIntervalSince1970: 1000)
        var machine = CallStateMachine(clock: { now })
        machine.handle(.placeCall)
        now += 5
        machine.handle(.answered)
        #expect(machine.connectedAt == nil)
        machine.handle(.mediaConnected)
        #expect(machine.connectedAt == Date(timeIntervalSince1970: 1005))
        now += 30
        machine.handle(.mediaInterrupted)
        machine.handle(.mediaConnected)
        #expect(machine.connectedAt == Date(timeIntervalSince1970: 1005), "a reconnect keeps the clock running")
    }
}
