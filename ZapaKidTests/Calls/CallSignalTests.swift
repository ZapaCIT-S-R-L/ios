import Foundation
import Testing
@testable import ZapaCalls

/// The messages on a call's event socket (a Durable Object per call): roster, key envelopes, joined, left, ended,
/// ring timeout. Unknown types are ignored, so the service can add messages without breaking older apps.
struct CallSignalTests {
    func decode(_ json: String) throws -> CallSignal {
        try CallSignal.decode(Data(json.utf8))
    }

    @Test func rosterListsParticipantsWithTheirTracks() throws {
        let signal = try decode("""
        {"type":"roster","participants":[{"accountId":"acc-a","deviceId":"dev-a","role":"parent",\
        "displayName":"Mama","avatar":"robot-3","muted":false,\
        "tracks":[{"sessionId":"s_a","trackName":"audio-dev-a"}]},\
        {"accountId":"acc-k","deviceId":"dev-k","role":"kid","tracks":[]}]}
        """)

        guard case let .roster(participants) = signal else { Issue.record("not a roster"); return }
        #expect(participants.map(\.deviceId) == ["dev-a", "dev-k"])
        #expect(participants[0].tracks == [TrackRef(sessionId: "s_a", trackName: "audio-dev-a")])
        #expect(participants[0].displayName == "Mama")
        #expect(participants[1].role == .kid)
        #expect(participants[1].muted == false)
    }

    @Test func keyEnvelopesDecodeFromBase64() throws {
        let signal = try decode(#"{"type":"key","epoch":4,"fromDevice":"dev-a","toDevice":"dev-b","blob":"AQID"}"#)

        #expect(signal == .key(KeyEnvelope(epoch: 4, fromDevice: "dev-a", toDevice: "dev-b", blob: Data([1, 2, 3]))))
    }

    @Test func lifecycleEvents() throws {
        #expect(try decode(#"{"type":"left","deviceId":"dev-b"}"#) == .left(deviceId: "dev-b"))
        #expect(try decode(#"{"type":"declined","deviceId":"dev-b"}"#) == .declined(deviceId: "dev-b"))
        #expect(try decode(#"{"type":"ended","reason":"everyone_left"}"#) == .ended(reason: "everyone_left"))
        #expect(try decode(#"{"type":"ring_timeout"}"#) == .ringTimeout)
        #expect(try decode(#"{"type":"something_new","x":1}"#) == .unknown("something_new"))
    }

    @Test func outgoingKeyAndMuteMessages() throws {
        let key = try OutgoingSignal.key(KeyEnvelope(epoch: 2, fromDevice: "dev-a", toDevice: "dev-b", blob: Data([9])))
            .encoded().json
        #expect(key?["type"] as? String == "key")
        #expect(key?["blob"] as? String == "CQ==")
        #expect(key?["toDevice"] as? String == "dev-b")

        let mute = try OutgoingSignal.muted(true).encoded().json
        #expect(mute?["type"] as? String == "mute")
        #expect(mute?["muted"] as? Bool == true)
    }

    @Test func garbageIsAnError() {
        #expect(throws: (any Error).self) { try decode("not json") }
    }
}
