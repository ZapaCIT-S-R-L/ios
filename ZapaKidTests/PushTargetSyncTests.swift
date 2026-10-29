import Foundation
import Testing
@testable import ZapaKid
import ZapaKidKit

/// The phone's VoIP token reaches the server once the phone has a device ID, and follows the token as PushKit rotates
/// it.
@MainActor
struct PushTargetSyncTests {
    final class FakePushAPI: DevicePushAPI, @unchecked Sendable {
        var calls: [(deviceId: Int, target: PushTarget?, token: String)] = []
        func setDevicePush(deviceId: Int, target: PushTarget?, token: String) async throws {
            calls.append((deviceId, target, token))
        }
    }

    final class Box {
        var deviceId: Int?
        var session: String? = "zks_tok"
    }

    func make(_ api: FakePushAPI, _ box: Box) -> PushTargetSync {
        PushTargetSync(api: api, token: { box.session }, deviceId: { box.deviceId })
    }

    @Test func aTokenBeforeRegistrationWaitsForIt() async {
        let api = FakePushAPI()
        let box = Box()
        let sync = make(api, box)

        await sync.voipTokenChanged("ab12")
        #expect(api.calls.isEmpty)

        box.deviceId = 2
        await sync.deviceRegistered()
        #expect(api.calls.count == 1)
        #expect(api.calls.first?.deviceId == 2)
        #expect(api.calls.first?.target == PushTarget(provider: .apns, token: "ab12"))
        #expect(api.calls.first?.token == "zks_tok")
    }

    @Test func aRotatedTokenIsSentAgain() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = make(api, box)

        await sync.voipTokenChanged("aa")
        await sync.voipTokenChanged("bb")
        #expect(api.calls.map(\.target) == [
            PushTarget(provider: .apns, token: "aa"),
            PushTarget(provider: .apns, token: "bb"),
        ])
    }

    @Test func invalidatedTokenClearsTheTargetOnlyIfOneWasSent() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = make(api, box)

        await sync.voipTokenChanged(nil)
        #expect(api.calls.isEmpty)

        await sync.voipTokenChanged("aa")
        await sync.voipTokenChanged(nil)
        #expect(api.calls.last?.target == nil)
        #expect(api.calls.count == 2)
    }

    @Test func noSessionMeansNothingIsSent() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        box.session = nil
        let sync = make(api, box)

        await sync.voipTokenChanged("aa")
        #expect(api.calls.isEmpty)
    }

    @Test func tokenBytesBecomeLowercaseHex() {
        #expect(PushTargetSync.hex(Data([0x0A, 0xFF, 0x01])) == "0aff01")
    }
}
