import Foundation
import Testing
@testable import ZapaCalls

/// End to end against a real calls service (services/calls on `wrangler dev`, with the fake Realtime/TURN server
/// on loopback). Off unless the environment names the service and two chat tokens for the same conversation:
///   TEST_RUNNER_ZK_CALLS_E2E_URL=http://127.0.0.1:8790
///   TEST_RUNNER_ZK_CALLS_E2E_CONVERSATION=<conversation id>
///   TEST_RUNNER_ZK_CALLS_E2E_TOKEN_A=<chat token, device A>   TEST_RUNNER_ZK_CALLS_E2E_TOKEN_B=<chat token, device B>
///   TEST_RUNNER_ZK_CALLS_E2E_DEVICE_A=<device id A>          TEST_RUNNER_ZK_CALLS_E2E_DEVICE_B=<device id B>
/// (xcodebuild passes TEST_RUNNER_-prefixed variables to the tests without the prefix.)
@Suite(.enabled(if: CallsE2E.configured, "set ZK_CALLS_E2E_* to run against a local calls service"))
struct CallsServiceE2ETests {
    @Test func signallingRosterAndKeyRelayBetweenTwoDevices() async throws {
        let env = try #require(CallsE2E.environment)
        let alice = HTTPCallsAPI(baseURL: env.url, session: .shared, token: { env.tokenA })
        let bob = HTTPCallsAPI(baseURL: env.url, session: .shared, token: { env.tokenB })

        let grant = try await alice.createCall(conversationId: env.conversation)
        let aliceSocket = try await alice.openEvents(callId: grant.callId)
        _ = try await bob.join(callId: grant.callId)
        let bobSocket = try await bob.openEvents(callId: grant.callId)
        let aliceEvents = SignalInbox(aliceSocket)
        let bobEvents = SignalInbox(bobSocket)
        defer {
            aliceSocket.close()
            bobSocket.close()
        }

        // Both see a roster with both devices.
        let roster = try await CallsE2E.first(in: bobEvents) { signal -> [String]? in
            if case let .roster(people) = signal, people.count == 2 {
                people.map(\.deviceId).sorted()
            } else {
                nil
            }
        }
        #expect(roster == [env.deviceA, env.deviceB].sorted())

        // A key envelope from A reaches B unchanged (the service relays only the opaque blob).
        let envelope = KeyEnvelope(epoch: 1, fromDevice: env.deviceA, toDevice: env.deviceB, blob: Data([1, 2, 3, 4]))
        try await aliceSocket.send(.key(envelope))
        let relayed = try await CallsE2E.first(in: bobEvents) { signal -> KeyEnvelope? in
            if case let .key(got) = signal {
                got
            } else {
                nil
            }
        }
        #expect(relayed == envelope)

        try await bob.leave(callId: grant.callId)
        let left = try await CallsE2E.first(in: aliceEvents) { signal -> String? in
            if case let .left(device) = signal {
                device
            } else {
                nil
            }
        }
        #expect(left == env.deviceB)
        try await alice.leave(callId: grant.callId)
    }
}

enum CallsE2E {
    struct Environment {
        let url: URL
        let conversation: String
        let tokenA: String
        let tokenB: String
        let deviceA: String
        let deviceB: String
    }

    static var environment: Environment? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["ZK_CALLS_E2E_URL"], let url = URL(string: raw),
              let conversation = env["ZK_CALLS_E2E_CONVERSATION"],
              let tokenA = env["ZK_CALLS_E2E_TOKEN_A"], let tokenB = env["ZK_CALLS_E2E_TOKEN_B"],
              let deviceA = env["ZK_CALLS_E2E_DEVICE_A"], let deviceB = env["ZK_CALLS_E2E_DEVICE_B"]
        else { return nil }
        return Environment(
            url: url, conversation: conversation, tokenA: tokenA, tokenB: tokenB, deviceA: deviceA, deviceB: deviceB
        )
    }

    static var configured: Bool {
        environment != nil
    }

    /// The first signal (within 10 s) that `match` turns into a value.
    static func first<T: Sendable>(
        in inbox: SignalInbox, _ match: @escaping @Sendable (CallSignal) -> T?
    ) async throws -> T {
        for _ in 0 ..< 200 {
            if let value = await inbox.take(match) {
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.timedOut)
    }
}

/// Collects a socket's signals (a stream has one consumer) so the test can look for one at a time.
actor SignalInbox {
    private var received: [CallSignal] = []

    init(_ connection: CallEventsConnection) {
        Task { [weak self] in
            for try await signal in connection.signals() {
                await self?.append(signal)
            }
        }
    }

    private func append(_ signal: CallSignal) {
        received.append(signal)
    }

    func take<T>(_ match: (CallSignal) -> T?) -> T? {
        guard let index = received.firstIndex(where: { match($0) != nil }) else { return nil }
        return match(received.remove(at: index))
    }
}
