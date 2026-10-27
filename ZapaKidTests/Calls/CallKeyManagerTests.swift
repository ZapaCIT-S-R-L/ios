import CryptoKit
import Foundation
import Testing
@testable import ZapaCalls

/// End-to-end encryption of a call: a new random key on every join and leave, sealed per recipient device, so
/// the server (and Cloudflare) only ever relay opaque blobs.
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

    /// Delivers envelopes like the calls service does: only to the device each one names.
    func deliver(_ envelopes: [KeyEnvelope], to phones: [String: Phone]) async throws {
        for envelope in envelopes {
            try await phones[envelope.toDevice]?.manager.receive(envelope)
        }
    }

    @Test func theLeaderIsTheLowestDeviceIdInTheRoster() {
        #expect(CallKeyManager.leader(of: ["dev-c", "dev-a", "dev-b"]) == "dev-a")
        #expect(CallKeyManager.leader(of: []) == nil)
    }

    @Test func aJoinRotatesTheKeyAndEveryoneGetsTheSameNewKey() async throws {
        let phones = ["dev-a": phone("dev-a"), "dev-b": phone("dev-b"), "dev-c": phone("dev-c")]
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b"]), to: phones)
        }
        let first = try #require(phones["dev-a"]?.frames.installed.last)
        #expect(phones["dev-b"]?.frames.installed.last == first)

        // dev-c joins: a new epoch and a new random key, which dev-c gets too.
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b", "dev-c"]), to: phones)
        }

        let second = try #require(phones["dev-a"]?.frames.installed.last)
        #expect(second.epoch == first.epoch + 1)
        #expect(second.bytes != first.bytes)
        #expect(phones["dev-b"]?.frames.installed.last == second)
        #expect(phones["dev-c"]?.frames.installed.last == second)
        #expect(phones["dev-c"]?.frames.installed.contains(first) == false, "a joiner never gets earlier keys")
        for (_, phone) in phones {
            #expect(phone.frames.sendingEpoch == second.epoch)
        }
    }

    @Test func aLeaveRotatesTheKeySoTheLeaverCantDecryptWhatFollows() async throws {
        let phones = ["dev-a": phone("dev-a"), "dev-b": phone("dev-b"), "dev-c": phone("dev-c")]
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b", "dev-c"]), to: phones)
        }
        let before = try #require(phones["dev-c"]?.frames.installed.last)

        // dev-c leaves; only dev-a and dev-b stay in the call.
        let stay = ["dev-a": phones["dev-a"]!, "dev-b": phones["dev-b"]!] // swiftlint:disable:this force_unwrapping
        for (_, phone) in stay {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b"]), to: phones)
        }

        let after = try #require(phones["dev-a"]?.frames.installed.last)
        #expect(after.epoch == before.epoch + 1)
        #expect(phones["dev-b"]?.frames.installed.last == after)
        #expect(phones["dev-c"]?.frames.installed.last == before, "the leaver never gets the new key")
    }

    @Test func whenTheLeaderLeavesTheNextLowestDeviceRotates() async throws {
        let phones = ["dev-a": phone("dev-a"), "dev-b": phone("dev-b"), "dev-c": phone("dev-c")]
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b", "dev-c"]), to: phones)
        }
        let before = try #require(phones["dev-b"]?.frames.installed.last)

        let fromB = try await phones["dev-b"]!.manager.rosterChanged(["dev-b", "dev-c"]) // swiftlint:disable:this force_unwrapping
        let fromC = try await phones["dev-c"]!.manager.rosterChanged(["dev-b", "dev-c"]) // swiftlint:disable:this force_unwrapping

        #expect(fromB.map(\.toDevice) == ["dev-c"])
        #expect(fromC.isEmpty)
        try await deliver(fromB, to: phones)
        #expect(phones["dev-c"]?.frames.installed.last?.epoch == before.epoch + 1)
    }

    @Test func envelopesCarryOnlyOpaqueBlobsAndNeverTheKey() async throws {
        let a = phone("dev-a")

        let envelopes = try await a.manager.rosterChanged(["dev-a", "dev-b"])

        let key = try #require(a.frames.installed.last)
        let envelope = try #require(envelopes.first)
        #expect(envelope.fromDevice == "dev-a")
        #expect(envelope.epoch == key.epoch)
        #expect(envelope.blob.range(of: key.bytes) == nil)
        let json = try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
        #expect(!json.contains(key.bytes.base64EncodedString()))
    }

    @Test func anEnvelopeForAnotherDeviceOrTamperedIsRefused() async throws {
        let a = phone("dev-a")
        let c = phone("dev-c")
        let envelope = try #require(try await a.manager.rosterChanged(["dev-a", "dev-b"]).first)
        _ = try await c.manager.rosterChanged(["dev-a", "dev-b", "dev-c"])

        await #expect(throws: CallKeyError.notForMe) { try await c.manager.receive(envelope) }

        let b = phone("dev-b")
        _ = try await b.manager.rosterChanged(["dev-a", "dev-b"])
        var tampered = envelope
        tampered.blob[tampered.blob.startIndex] ^= 0xFF
        await #expect(throws: (any Error).self) { try await b.manager.receive(tampered) }
        #expect(b.frames.installed.isEmpty)
    }

    @Test func anEnvelopeFromSomeoneWhoIsNotTheLeaderIsRefused() async throws {
        let b = phone("dev-b")
        _ = try await b.manager.rosterChanged(["dev-a", "dev-b", "dev-c"])
        // dev-c pretends to be leader and rotates.
        let forged = KeyEnvelope(
            epoch: 9, fromDevice: "dev-c", toDevice: "dev-b",
            blob: try await FakeCallKeySealer(me: "dev-c").seal(
                CallKeyMaterial.encode(CallKey.random(epoch: 9), callId: callId), toDevice: "dev-b"
            )
        )

        await #expect(throws: CallKeyError.notFromLeader) { try await b.manager.receive(forged) }
        #expect(b.frames.installed.isEmpty)
    }

    @Test func anOlderEpochNeverReplacesTheSendingKey() async throws {
        let phones = ["dev-a": phone("dev-a"), "dev-b": phone("dev-b")]
        let first = try await phones["dev-a"]!.manager.rosterChanged(["dev-a", "dev-b"]) // swiftlint:disable:this force_unwrapping
        let second = try await phones["dev-a"]!.manager.rosterChanged(["dev-a", "dev-b"]) // swiftlint:disable:this force_unwrapping
        _ = try await phones["dev-b"]!.manager.rosterChanged(["dev-a", "dev-b"]) // swiftlint:disable:this force_unwrapping

        try await deliver(second, to: phones)
        try await deliver(first, to: phones)

        #expect(phones["dev-b"]?.frames.sendingEpoch == second.first?.epoch)
    }

    /// The frame round trip: what the sender encrypts under the epoch key, the receiver decrypts with the key it
    /// opened from its envelope, and a stale key from before the rotation can't.
    @Test func framesRoundTripWithTheRelayedKeyAndFailWithAStaleOne() async throws {
        let phones = ["dev-a": phone("dev-a"), "dev-b": phone("dev-b")]
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b"]), to: phones)
        }
        let stale = try #require(phones["dev-b"]?.frames.installed.last)
        for (_, phone) in phones {
            try await deliver(phone.manager.rosterChanged(["dev-a", "dev-b", "dev-c"]), to: phones)
        }
        let senderKey = try #require(phones["dev-a"]?.frames.installed.last)
        let receiverKey = try #require(phones["dev-b"]?.frames.installed.last)
        let frame = Data((0 ..< 160).map { UInt8($0 & 0xFF) }) // one 20 ms Opus frame, roughly

        let sealed = try AES.GCM.seal(frame, using: SymmetricKey(data: senderKey.bytes))
        let opened = try AES.GCM.open(sealed, using: SymmetricKey(data: receiverKey.bytes))

        #expect(opened == frame)
        #expect(throws: (any Error).self) { try AES.GCM.open(sealed, using: SymmetricKey(data: stale.bytes)) }
    }

    @Test func keyRingIndexWrapsLikeTheFrameCryptor() {
        #expect(CallKey.ringIndex(forEpoch: 0) == 0)
        #expect(CallKey.ringIndex(forEpoch: 15) == 15)
        #expect(CallKey.ringIndex(forEpoch: 16) == 0)
        #expect(CallKey.ringSize == 16)
    }
}
