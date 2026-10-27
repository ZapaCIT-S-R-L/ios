import CryptoKit
import Foundation
import Testing
@testable import ZapaCalls

/// End-to-end encryption of a call: on every join and leave the service bumps `epoch` and names a `keyLeader`;
/// the leader makes a new random key for that epoch and seals it per device. The service only relays blobs.
struct CallKeyManagerTests {
    let callId = "call-1"

    struct Phone {
        let manager: CallKeyManager
        let frames: RecordingFrameKeys
    }

    func phone(_ device: String) -> Phone {
        let frames = RecordingFrameKeys()
        let manager = CallKeyManager(
            callId: callId, me: device, sealer: FakeCallKeySealer(me: device), frameKeys: frames
        )
        return Phone(manager: manager, frames: frames)
    }

    func deliver(_ envelopes: [KeyEnvelope], to phones: [String: Phone]) async throws {
        for envelope in envelopes {
            _ = try await phones[envelope.toDevice]?.manager.receive(envelope)
        }
    }

    /// Every phone sees the same roster update from the server, then the leader's keys are delivered.
    func roster(_ devices: [String], epoch: UInt32, leader: String, _ phones: [String: Phone]) async throws {
        var envelopes: [KeyEnvelope] = []
        for device in devices {
            envelopes += try await phones[device]?.manager.rosterChanged(devices, epoch: epoch, leader: leader) ?? []
        }
        try await deliver(envelopes, to: phones)
    }

    @Test func theServersLeaderMakesTheKeyForTheServersEpoch() async throws {
        let phones = ["m.1": phone("m.1"), "k.2": phone("k.2")]

        try await roster(["m.1", "k.2"], epoch: 7, leader: "k.2", phones)

        let key = try #require(phones["k.2"]?.frames.installed.last)
        #expect(key.epoch == 7, "the epoch comes from the server, not a local count")
        #expect(phones["m.1"]?.frames.installed.last == key)
        #expect(phones["m.1"]?.frames.sendingEpoch == 7)
    }

    @Test func aJoinGivesEveryoneANewKeyAndTheJoinerNoOldOne() async throws {
        let phones = ["a.1": phone("a.1"), "b.1": phone("b.1"), "c.1": phone("c.1")]
        try await roster(["a.1", "b.1"], epoch: 1, leader: "a.1", phones)
        let first = try #require(phones["a.1"]?.frames.installed.last)

        try await roster(["a.1", "b.1", "c.1"], epoch: 2, leader: "a.1", phones)

        let second = try #require(phones["a.1"]?.frames.installed.last)
        #expect(second.epoch == 2)
        #expect(second.bytes != first.bytes)
        #expect(phones["b.1"]?.frames.installed.last == second)
        #expect(phones["c.1"]?.frames.installed.last == second)
        #expect(phones["c.1"]?.frames.installed.contains(first) == false)
    }

    @Test func aLeaveRotatesSoTheLeaverNeverGetsTheNextKey() async throws {
        let phones = ["a.1": phone("a.1"), "b.1": phone("b.1"), "c.1": phone("c.1")]
        try await roster(["a.1", "b.1", "c.1"], epoch: 2, leader: "a.1", phones)
        let before = try #require(phones["c.1"]?.frames.installed.last)

        try await roster(["a.1", "b.1"], epoch: 3, leader: "a.1", phones)

        #expect(phones["b.1"]?.frames.installed.last?.epoch == 3)
        #expect(phones["c.1"]?.frames.installed.last == before)
    }

    @Test func onlyTheLeaderSendsAndOnlyToTheOthers() async throws {
        let leader = phone("a.1")
        let other = phone("b.1")

        let sent = try await leader.manager.rosterChanged(["a.1", "b.1", "c.1"], epoch: 4, leader: "a.1")
        let silent = try await other.manager.rosterChanged(["a.1", "b.1", "c.1"], epoch: 4, leader: "a.1")

        #expect(sent.map(\.toDevice).sorted() == ["b.1", "c.1"])
        #expect(sent.allSatisfy { $0.epoch == 4 && $0.fromDevice == "a.1" })
        #expect(silent.isEmpty)
        let again = try await leader.manager.rosterChanged(["a.1", "b.1", "c.1"], epoch: 4, leader: "a.1")
        #expect(again.isEmpty, "one key per epoch, even if the roster is sent again")
    }

    @Test func aKeyFromSomeoneElseOrForAnotherEpochIsNotUsed() async throws {
        let bob = phone("b.1")
        _ = try await bob.manager.rosterChanged(["a.1", "b.1", "c.1"], epoch: 4, leader: "a.1")
        let forged = try await KeyEnvelope(
            epoch: 4, fromDevice: "c.1", toDevice: "b.1",
            blob: FakeCallKeySealer(me: "c.1").seal(
                CallKeyMaterial.encode(CallKey.random(epoch: 4), callId: callId), toDevice: "b.1"
            )
        )
        let stale = try await KeyEnvelope(
            epoch: 3, fromDevice: "a.1", toDevice: "b.1",
            blob: FakeCallKeySealer(me: "a.1").seal(
                CallKeyMaterial.encode(CallKey.random(epoch: 3), callId: callId), toDevice: "b.1"
            )
        )

        #expect(try await bob.manager.receive(forged) == false)
        #expect(try await bob.manager.receive(stale) == false)
        #expect(bob.frames.installed.isEmpty)
    }

    @Test func aKeyThatArrivesBeforeItsRosterIsUsedOnceTheRosterComes() async throws {
        let phones = ["a.1": phone("a.1"), "b.1": phone("b.1")]
        let envelopes = try await phones["a.1"]!.manager.rosterChanged(["a.1", "b.1"], epoch: 5, leader: "a.1")

        try await deliver(envelopes, to: phones) // b.1 hasn't seen epoch 5 yet
        #expect(phones["b.1"]?.frames.installed.isEmpty == true)
        _ = try await phones["b.1"]!.manager.rosterChanged(["a.1", "b.1"], epoch: 5, leader: "a.1")

        #expect(phones["b.1"]?.frames.installed.last?.epoch == 5)
    }

    @Test func tamperedBlobsAreRefused() async throws {
        let alice = phone("a.1")
        let bob = phone("b.1")
        var envelope = try #require(try await alice.manager.rosterChanged(["a.1", "b.1"], epoch: 1, leader: "a.1").first)
        _ = try await bob.manager.rosterChanged(["a.1", "b.1"], epoch: 1, leader: "a.1")
        envelope.blob[envelope.blob.startIndex] ^= 0xFF

        await #expect(throws: (any Error).self) { _ = try await bob.manager.receive(envelope) }
        #expect(bob.frames.installed.isEmpty)
    }

    @Test func framesRoundTripWithTheRelayedKeyAndFailWithAStaleOne() async throws {
        let phones = ["a.1": phone("a.1"), "b.1": phone("b.1")]
        try await roster(["a.1", "b.1"], epoch: 1, leader: "a.1", phones)
        let stale = try #require(phones["b.1"]?.frames.installed.last)
        try await roster(["a.1", "b.1"], epoch: 2, leader: "a.1", phones)
        let senderKey = try #require(phones["a.1"]?.frames.installed.last)
        let receiverKey = try #require(phones["b.1"]?.frames.installed.last)
        let frame = Data((0 ..< 160).map { UInt8($0 & 0xFF) })

        let sealed = try AES.GCM.seal(frame, using: SymmetricKey(data: senderKey.bytes))

        #expect(try AES.GCM.open(sealed, using: SymmetricKey(data: receiverKey.bytes)) == frame)
        #expect(throws: (any Error).self) { try AES.GCM.open(sealed, using: SymmetricKey(data: stale.bytes)) }
    }

    @Test func keyRingIndexWrapsLikeTheFrameCryptor() {
        #expect(CallKey.ringIndex(forEpoch: 16) == 0)
        #expect(CallKey.ringSize == 16)
    }
}
