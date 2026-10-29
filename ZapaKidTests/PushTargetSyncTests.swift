import Foundation
import Testing
@testable import ZapaKid
import ZapaKidKit

/// The phone's VoIP token reaches the server once the phone has a device ID, and follows the token as PushKit rotates
/// it.
@MainActor
struct PushTargetSyncTests {
    final class FakePushAPI: DevicePushAPI, @unchecked Sendable {
        struct Call {
            let deviceId: Int
            let target: PushTarget?
            let token: String
        }

        var calls: [Call] = []
        func setDevicePush(deviceId: Int, target: PushTarget?, token: String) async throws {
            calls.append(Call(deviceId: deviceId, target: target, token: token))
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

    @Test func anInvalidationClearsTheTargetEvenOnAFreshLaunch() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = make(api, box)

        // The server may still hold the previous launch's token, so the first invalidation clears it.
        await sync.voipTokenChanged(nil)
        #expect(api.calls.map(\.target) == [nil])

        await sync.voipTokenChanged("aa")
        await sync.voipTokenChanged(nil)
        #expect(api.calls.map(\.target) == [nil, PushTarget(provider: .apns, token: "aa"), nil])
    }

    @Test func registeringBeforePushKitAnswersSendsNothing() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = make(api, box)

        await sync.deviceRegistered()
        #expect(api.calls.isEmpty)
    }

    /// Holds the first request until the test releases it, so a second token arrives while it is out.
    final class GatedPushAPI: DevicePushAPI, @unchecked Sendable {
        var targets: [PushTarget?] = []
        var gate: CheckedContinuation<Void, Never>?
        /// The held first request fails once released (the server or network refused it).
        var failFirst = false
        private var holdFirst = true

        func setDevicePush(deviceId _: Int, target: PushTarget?, token _: String) async throws {
            targets.append(target)
            guard holdFirst else { return }
            holdFirst = false
            await withCheckedContinuation { gate = $0 }
            if failFirst {
                throw URLError(.networkConnectionLost)
            }
        }
    }

    @Test func aTokenThatArrivesDuringARequestIsSentAfterIt() async throws {
        let api = GatedPushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = PushTargetSync(api: api, token: { box.session }, deviceId: { box.deviceId })

        let first = Task { await sync.voipTokenChanged("aa") }
        for _ in 0 ..< 200 where api.gate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.gate != nil)

        await sync.voipTokenChanged("bb") // Returns at once: the running sync picks it up.
        api.gate?.resume()
        await first.value

        // The newest token went last, and nothing was sent twice.
        #expect(api.targets == [PushTarget(provider: .apns, token: "aa"), PushTarget(provider: .apns, token: "bb")])
        await sync.deviceRegistered()
        #expect(api.targets.count == 2)
    }

    @Test func aTokenThatArrivesDuringAFailedRequestIsStillSent() async throws {
        let api = GatedPushAPI()
        api.failFirst = true
        let box = Box()
        box.deviceId = 1
        let sync = PushTargetSync(api: api, token: { box.session }, deviceId: { box.deviceId })

        let first = Task { await sync.voipTokenChanged("aa") }
        for _ in 0 ..< 200 where api.gate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.gate != nil)

        await sync.voipTokenChanged("bb")
        api.gate?.resume() // PUT(aa) fails now.
        await first.value

        // bb went out without waiting for another PushKit or registration callback.
        #expect(api.targets == [PushTarget(provider: .apns, token: "aa"), PushTarget(provider: .apns, token: "bb")])
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
