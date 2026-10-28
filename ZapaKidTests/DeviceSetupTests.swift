import Foundation
import Testing
@testable import ZapaKid

/// Registering a phone retries calmly: 2 s, doubling, at most 5 min; at once when the network comes back, the app
/// comes to the foreground or the person taps "Try again". Parents and kids alike (android `setup-retry`).
@MainActor
struct DeviceSetupTests {
    final class Script: @unchecked Sendable {
        var results: [DeviceSetupResult]
        var runs = 0
        var waits: [Duration] = []

        init(_ results: [DeviceSetupResult]) {
            self.results = results
        }
    }

    func setup(_ script: Script, signedOut: @escaping () -> Void = {}) -> DeviceSetup {
        DeviceSetup(
            register: {
                script.runs += 1
                return script.results.isEmpty ? .ready(deviceId: 1) : script.results.removeFirst()
            },
            wait: { duration in script.waits.append(duration) },
            onSignedOut: signedOut
        )
    }

    @Test func theBackoffDoublesFromTwoSecondsUpToFiveMinutes() {
        let delays = (0 ..< 10).map { DeviceSetup.delay(afterAttempt: $0) }
        #expect(delays == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300].map { Duration.seconds($0) })
    }

    @Test func failuresAreRetriedUntilReady() async {
        let script = Script([.failed(.network), .failed(.server), .ready(deviceId: 7)])
        let setup = setup(script)

        await setup.run()

        #expect(setup.state == .ready(deviceId: 7))
        #expect(script.runs == 3)
        #expect(script.waits == [.seconds(2), .seconds(4)])
    }

    @Test func needingAPairingStopsRetrying() async {
        let script = Script([.needsPairing])
        let setup = setup(script)

        await setup.run()

        #expect(setup.state == .needsPairing)
        #expect(script.runs == 1)
    }

    @Test func anExpiredSessionSignsOutOnce() async {
        let script = Script([.signedOut])
        var signOuts = 0
        let setup = setup(script) { signOuts += 1 }

        await setup.run()

        #expect(signOuts == 1)
        #expect(script.waits.isEmpty)
    }

    @Test func whileWaitingTheStateSaysWhenItTriesAgain() async {
        let script = Script([.failed(.network)])
        var seen: DeviceSetup.State?
        let setup = DeviceSetup(
            register: { script.results.isEmpty ? .ready(deviceId: 1) : script.results.removeFirst() },
            wait: { _ in },
            onSignedOut: {}
        )
        setup.onChange = { state in
            if case .retrying = state {
                seen = state
            }
        }

        await setup.run()

        #expect(seen == .retrying(reason: .network))
        #expect(setup.state == .ready(deviceId: 1))
    }
}
