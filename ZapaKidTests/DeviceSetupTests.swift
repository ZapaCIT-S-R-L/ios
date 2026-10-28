import Foundation
import Testing
@testable import ZapaKid
import ZapaKidKit

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

    func setup(_ script: Script, signedOut: @escaping @MainActor () -> Void = {}) -> DeviceSetup {
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

    /// Review (gemini-zpc, ios #53): only failures that can pass by themselves are retried.
    @Test func rateLimitsAreRetriedToo() async {
        let script = Script([.failed(.rateLimited), .ready(deviceId: 3)])
        let setup = setup(script)

        await setup.run()

        #expect(setup.state == .ready(deviceId: 3))
        #expect(script.waits == [.seconds(2)])
    }

    @Test(arguments: [DeviceSetupResult.Reason.attestationFailed, .rejected])
    func failuresThatNeedAPersonStop(reason: DeviceSetupResult.Reason) async {
        let script = Script([.failed(reason)])
        let setup = setup(script)

        await setup.run()

        #expect(setup.state == .stopped(reason: reason))
        #expect(script.runs == 1)
        #expect(script.waits.isEmpty)
    }

    /// Review (gemini-zpc, ios #53, high): a loop from an earlier session must never act for the next one.
    @Test func aSupersededSessionStopsWithoutSigningOut() async {
        let script = Script([.superseded])
        var signOuts = 0
        let setup = setup(script) { signOuts += 1 }

        await setup.run()

        #expect(signOuts == 0, "never sign out the account that is signed in now")
        #expect(setup.state == .idle)
        #expect(script.runs == 1)
    }

    @Test func cancellingTheRunStopsTheLoopWhileItWaits() async {
        var runs = 0
        let setup = DeviceSetup(
            register: {
                runs += 1
                return .failed(.network)
            },
            wait: { duration in try? await Task.sleep(for: duration) },
            onSignedOut: {}
        )

        let task = Task { await setup.run() }
        while runs == 0 {
            await Task.yield()
        }
        task.cancel()
        await task.value

        #expect(runs == 1, "no registration after the view that started it is gone")
        #expect(setup.state == .idle)
    }

    @Test func registrationOnlyRunsForTheAccountThatStartedIt() {
        let ana = ParentProfile(id: "ana", email: nil, displayName: nil)
        let kid = KidSession(
            token: "zkk_t", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ion", avatar: "robot-1"),
            familyId: "f1", familyName: nil, pairedAt: Date()
        )
        #expect(LiveServices.isCurrent(.signedIn(ana), me: "ana", kid: false))
        #expect(!LiveServices.isCurrent(.signedIn(ana), me: "bob", kid: false))
        #expect(!LiveServices.isCurrent(.signedOut, me: "ana", kid: false))
        #expect(LiveServices.isCurrent(.kid(kid), me: "k1", kid: true))
        #expect(!LiveServices.isCurrent(.kid(kid), me: "k1", kid: false))
        #expect(!LiveServices.isCurrent(.signedIn(ana), me: "ana", kid: true))
    }
}
