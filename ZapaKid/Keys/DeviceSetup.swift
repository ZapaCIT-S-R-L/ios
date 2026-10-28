import Foundation
import Network
import Observation

/// Gets this phone registered with the key directory and keeps trying calmly when it can't: 2 s, doubling, at
/// most 5 min between tries; at once when the network comes back, the app comes to the foreground, or the person
/// taps "Try again". Parents and kids alike (the same as android `setup-retry`). Only failures that can pass by
/// themselves are retried; the run belongs to the view that started it and stops when that view goes away.
@MainActor
@Observable
final class DeviceSetup {
    enum State: Equatable {
        case idle
        case working
        /// Failed; trying again soon.
        case retrying(reason: DeviceSetupResult.Reason)
        /// Failed in a way retrying can't fix (e.g. reinstall from the App Store).
        case stopped(reason: DeviceSetupResult.Reason)
        case ready(deviceId: Int)
        /// A kid phone a parent must pair again.
        case needsPairing
        /// Another phone of this parent must share the identity first.
        case waitingForReshare
    }

    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }

    var onChange: ((State) -> Void)?
    /// Called when it's ready (the app starts sealing and loads the chats).
    var onReady: ((Int) -> Void)?

    private let register: @MainActor () async -> DeviceSetupResult
    private let wait: @MainActor (Duration) async -> Void
    private let onSignedOut: @MainActor () -> Void
    private var attempt = 0
    private var running = false
    private var waiting: Task<Void, Never>?

    init(
        register: @escaping @MainActor () async -> DeviceSetupResult,
        wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onSignedOut: @escaping @MainActor () -> Void
    ) {
        self.register = register
        self.wait = wait
        self.onSignedOut = onSignedOut
    }

    /// 2 s after the first failure, doubling, capped at 5 min.
    static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(300, 2 << min(attempt, 8)))
    }

    /// Runs until ready, a pairing is needed, the session is gone, or the calling task is cancelled.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            state = .working
            let result = await register()
            if Task.isCancelled {
                break
            }
            guard case let .failed(reason) = result, reason.isRetryable else {
                finish(result)
                return
            }
            state = .retrying(reason: reason)
            await waitBeforeRetrying()
        }
        state = .idle
    }

    /// Settles the state for a result that ends the run.
    private func finish(_ result: DeviceSetupResult) {
        switch result {
        case let .ready(deviceId):
            state = .ready(deviceId: deviceId)
            attempt = 0
            onReady?(deviceId)
        case .needsPairing:
            state = .needsPairing
        case .waitingForReshare:
            state = .waitingForReshare
        case .signedOut:
            state = .idle
            onSignedOut()
        case .superseded:
            state = .idle
        case let .failed(reason):
            state = .stopped(reason: reason)
        }
    }

    private func waitBeforeRetrying() async {
        let delay = Self.delay(afterAttempt: attempt)
        attempt += 1
        let task = Task { await wait(delay) }
        waiting = task
        // `retryNow` cancels only the wait; cancelling the run cancels it too.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        waiting = nil
    }

    /// Network back, foreground, or "Try again": stop waiting and try now.
    func retryNow() {
        waiting?.cancel()
    }

    /// Calls `retryNow` whenever the network comes back.
    func watchNetwork() -> NWPathMonitor {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryNow() }
        }
        monitor.start(queue: .main)
        return monitor
    }
}
