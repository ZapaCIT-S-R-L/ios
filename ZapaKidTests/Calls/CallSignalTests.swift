import Foundation
import Testing
@testable import ZapaCalls

/// The call's WebSocket messages, per services/calls/openapi.yaml (zapakid-api main): the roster is the `Call`
/// object with the server's `epoch` and `keyLeader`; device ids are integers; keys go out as one `keys` batch.
struct CallSignalTests {
    func decode(_ json: String) throws -> CallSignal {
        try CallSignal.decode(Data(json.utf8))
    }

    let callJSON = """
    {"callId":"6f1c0e2a-0000-4000-8000-000000000001","conversationId":"conv-1","state":"active",\
    "createdAt":"2026-10-28T08:00:00Z","ringDeadline":"2026-10-28T08:00:45Z","epoch":3,\
    "keyLeader":{"accountId":"acc-m","deviceId":1},\
    "participants":[{"accountId":"acc-m","deviceId":1,"role":"parent","joinedAt":"2026-10-28T08:00:00Z",\
    "sessionId":"s_m","tracks":["audio-acc-m_1"],"connected":true},\
    {"accountId":"acc-k","deviceId":2,"role":"kid","joinedAt":"2026-10-28T08:00:05Z","sessionId":null,\
    "tracks":[],"connected":false}],"declined":[],"endReason":null}
    """

    @Test func rosterIsTheCallWithEpochLeaderAndIntegerDevices() throws {
        guard case let .roster(call) = try decode(#"{"type":"roster","call":\#(callJSON)}"#) else {
            Issue.record("not a roster")
            return
        }
        #expect(call.epoch == 3)
        #expect(call.keyLeader == CallDevice(accountId: "acc-m", deviceId: 1))
        #expect(call.keyLeader?.name == "acc-m.1")
        #expect(call.participants.map(\.name) == ["acc-m.1", "acc-k.2"])
        #expect(call.participants[0].trackRefs == [TrackRef(sessionId: "s_m", trackName: "audio-acc-m_1")])
        #expect(call.participants[1].trackRefs.isEmpty, "no session yet")
        #expect(call.participants[1].role == .kid)
    }

    @Test func keysArriveFromAnAccountAndIntegerDevice() throws {
        let signal = try decode(#"{"type":"key","epoch":4,"fromAccount":"acc-m","fromDevice":1,"blob":"AQID"}"#)

        guard case let .key(envelope) = signal else { Issue.record("not a key"); return }
        #expect(envelope.epoch == 4)
        #expect(envelope.fromDevice == "acc-m.1")
        #expect(envelope.blob == Data([1, 2, 3]))
    }

    @Test func lifecycleAndErrors() throws {
        #expect(try decode(#"{"type":"left","accountId":"a","deviceId":2,"epoch":5,"reason":"left"}"#)
            == .left(CallDevice(accountId: "a", deviceId: 2), epoch: 5))
        #expect(try decode(#"{"type":"joined","accountId":"a","deviceId":2,"epoch":4}"#)
            == .joined(CallDevice(accountId: "a", deviceId: 2), epoch: 4))
        #expect(try decode(#"{"type":"declined","accountId":"a"}"#) == .declined(accountId: "a"))
        #expect(try decode(#"{"type":"ended","reason":"no_answer"}"#) == .ended(reason: "no_answer"))
        #expect(try decode(#"{"type":"error","code":"stale_epoch","message":"x","epoch":7}"#)
            == .error(code: "stale_epoch", epoch: 7))
        #expect(try decode(#"{"type":"pong"}"#) == .unknown("pong"))
    }

    @Test func outgoingKeysAreOneBatchPerEpochWithAccountAndIntegerDevice() throws {
        let keys = try OutgoingSignal.keys(epoch: 4, [
            KeyEnvelope(epoch: 4, fromDevice: "acc-m.1", toDevice: "acc-k.2", blob: Data([9])),
            KeyEnvelope(epoch: 4, fromDevice: "acc-m.1", toDevice: "acc-a.17", blob: Data([8])),
        ]).encoded().json

        #expect(keys?["type"] as? String == "keys")
        #expect(keys?["epoch"] as? Int == 4)
        let envelopes = try #require(keys?["envelopes"] as? [[String: Any]])
        #expect(envelopes.first?["toAccount"] as? String == "acc-k")
        #expect(envelopes.first?["toDevice"] as? Int == 2)
        #expect(envelopes.first?["blob"] as? String == "CQ==")
        #expect(envelopes.last?["toDevice"] as? Int == 17)
        #expect(try OutgoingSignal.ping.encoded().json?["type"] as? String == "ping")
    }

    @Test func trackNamesUseAnUnderscoreBetweenAccountAndDevice() {
        let name = CallController.trackName(for: "6f1c0e2a-0000-4000-8000-000000000001.12")
        #expect(name == "audio-6f1c0e2a-0000-4000-8000-000000000001_12")
        #expect(name.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil, "the API's track name pattern")
    }

    @Test func garbageIsAnError() {
        #expect(throws: (any Error).self) { try decode("not json") }
    }
}
