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
        var alertCalls: [Call] = []
        func setDevicePush(deviceId: Int, target: PushTarget?, token: String) async throws {
            calls.append(Call(deviceId: deviceId, target: target, token: token))
        }

        func setDeviceAlertPush(deviceId: Int, target: PushTarget?, token: String) async throws {
            alertCalls.append(Call(deviceId: deviceId, target: target, token: token))
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

        await sync.tokenChanged("ab12")
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

        await sync.tokenChanged("aa")
        await sync.tokenChanged("bb")
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
        await sync.tokenChanged(nil)
        #expect(api.calls.map(\.target) == [nil])

        await sync.tokenChanged("aa")
        await sync.tokenChanged(nil)
        #expect(api.calls.map(\.target) == [nil, PushTarget(provider: .apns, token: "aa"), nil])
    }

    @Test func signingOutClearsTheServerTargetWhileTheCredentialsRemain() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = PushTargetSync(api: api, channel: .alert, token: { box.session }, deviceId: { box.deviceId })
        await sync.tokenChanged("aa")

        await sync.signOut()
        #expect(api.alertCalls.map(\.target) == [PushTarget(provider: .apns, token: "aa"), nil])
        #expect(api.alertCalls.last?.token == "zks_tok")
    }

    @Test func afterSigningOutAnOldCallbackNeverRegistersTheTargetAgain() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let sync = PushTargetSync(api: api, channel: .alert, token: { box.session }, deviceId: { box.deviceId })
        await sync.signOut()
        let sent = api.alertCalls.count

        await sync.tokenChanged("bb")
        await sync.deviceRegistered()
        #expect(api.alertCalls.count == sent)
    }

    @Test func aFailedClearDoesNotBlockSigningOut() async {
        final class Failing: DevicePushAPI, @unchecked Sendable {
            func setDevicePush(deviceId _: Int, target _: PushTarget?, token _: String) async throws {
                throw URLError(.notConnectedToInternet)
            }

            func setDeviceAlertPush(deviceId _: Int, target _: PushTarget?, token _: String) async throws {
                throw URLError(.notConnectedToInternet)
            }
        }
        let box = Box()
        box.deviceId = 1
        let sync = PushTargetSync(api: Failing(), channel: .alert, token: { box.session }, deviceId: { box.deviceId })
        await sync.tokenChanged("aa")
        await sync.signOut()
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

        func setDeviceAlertPush(deviceId _: Int, target _: PushTarget?, token _: String) async throws {}

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

        let first = Task { await sync.tokenChanged("aa") }
        for _ in 0 ..< 200 where api.gate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.gate != nil)

        await sync.tokenChanged("bb") // Returns at once: the running sync picks it up.
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

        let first = Task { await sync.tokenChanged("aa") }
        for _ in 0 ..< 200 where api.gate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.gate != nil)

        await sync.tokenChanged("bb")
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

        await sync.tokenChanged("aa")
        #expect(api.calls.isEmpty)
    }

    /// The alert channel (chat notifications) sends to the alert endpoint, and never touches the VoIP target.
    @Test func theAlertChannelUsesItsOwnEndpoint() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 3
        let alert = PushTargetSync(api: api, channel: .alert, token: { box.session }, deviceId: { box.deviceId })

        await alert.tokenChanged("cd34")
        #expect(api.calls.isEmpty)
        #expect(api.alertCalls.map(\.target) == [PushTarget(provider: .apns, token: "cd34")])
        #expect(api.alertCalls.first?.deviceId == 3)
        #expect(api.alertCalls.first?.token == "zks_tok")
    }

    /// The two channels keep separate targets: a VoIP token and an alert token never overwrite each other.
    @Test func theVoIPAndAlertTargetsStayApart() async {
        let api = FakePushAPI()
        let box = Box()
        box.deviceId = 1
        let voip = make(api, box)
        let alert = PushTargetSync(api: api, channel: .alert, token: { box.session }, deviceId: { box.deviceId })

        await voip.tokenChanged("aa")
        await alert.tokenChanged("bb")
        #expect(api.calls.map(\.target) == [PushTarget(provider: .apns, token: "aa")])
        #expect(api.alertCalls.map(\.target) == [PushTarget(provider: .apns, token: "bb")])
    }

    @Test func tokenBytesBecomeLowercaseHex() {
        #expect(PushTargetSync.hex(Data([0x0A, 0xFF, 0x01])) == "0aff01")
    }
}
