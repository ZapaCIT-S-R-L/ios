import CryptoKit
import Foundation
import Testing
@testable import ZapaCalls

/// The per-call frame key: random, 256 bits, never printed, and bound to its call and epoch when sealed.
struct CallKeyTests {
    @Test func randomKeysAre256BitsAndDiffer() {
        let one = CallKey.random(epoch: 1)
        let two = CallKey.random(epoch: 1)

        #expect(one.bytes.count == 32)
        #expect(one.bytes != two.bytes)
        #expect(one.epoch == 1)
    }

    @Test func keyBytesNeverAppearInDescriptions() {
        let key = CallKey.random(epoch: 7)

        #expect(String(describing: key) == "CallKey(epoch: 7)")
        #expect(String(reflecting: key) == "CallKey(epoch: 7)")
    }

    @Test func rejectsKeysOfTheWrongLength() {
        #expect(CallKey(epoch: 1, bytes: Data(count: 16)) == nil)
        #expect(CallKey(epoch: 1, bytes: Data(count: 32)) != nil)
    }

    @Test func keyMaterialRoundTripsForTheSameCall() throws {
        let key = CallKey.random(epoch: 3)

        let material = CallKeyMaterial.encode(key, callId: "call-1")
        let decoded = try CallKeyMaterial.decode(material, callId: "call-1", epoch: 3)

        #expect(decoded == key)
    }

    @Test func keyMaterialFromAnotherCallOrEpochIsRefused() {
        let material = CallKeyMaterial.encode(CallKey.random(epoch: 3), callId: "call-1")

        #expect(throws: CallKeyError.wrongCall) { try CallKeyMaterial.decode(material, callId: "call-2", epoch: 3) }
        #expect(throws: CallKeyError.wrongEpoch) { try CallKeyMaterial.decode(material, callId: "call-1", epoch: 4) }
        #expect(throws: CallKeyError.malformed) {
            try CallKeyMaterial.decode(Data("junk".utf8), callId: "call-1", epoch: 3)
        }
    }
}
