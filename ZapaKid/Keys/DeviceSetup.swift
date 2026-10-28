import Foundation
import Network
import Observation

/// Gets this phone registered with the key directory and keeps trying calmly when it can't: 2 s, doubling, at
/// most 5 min between tries; at once when the network comes back, the app comes to the foreground, or the person
/// taps "Try again". Parents and kids alike (the same as android `setup-retry`).
@MainActor
@Observable
final class DeviceSetup {
    enum State: Equatable {
        case idle
        case working
        /// Failed; trying again soon.
        case retrying(reason: DeviceSetupResult.Reason)
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

    /// Runs until ready, a pairing is needed, or the session is gone.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while true {
            state = .working
            switch await register() {
            case let .ready(deviceId):
                state = .ready(deviceId: deviceId)
                attempt = 0
                onReady?(deviceId)
                return
            case .needsPairing:
                state = .needsPairing
                return
            case .waitingForReshare:
                state = .waitingForReshare
                return
            case .signedOut:
                state = .idle
                onSignedOut()
                return
            case let .failed(reason):
                state = .retrying(reason: reason)
                let delay = Self.delay(afterAttempt: attempt)
                attempt += 1
                let task = Task { await wait(delay) }
                waiting = task
                await task.value
                waiting = nil
            }
        }
    }

    /// Network back, foreground, or "Try again": stop waiting and try now.
    func retryNow() {
        if let waiting {
            waiting.cancel()
        } else if case .retrying = state {
            Task { await run() }
        }
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
