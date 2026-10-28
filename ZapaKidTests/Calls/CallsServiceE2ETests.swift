import Foundation
import Testing
@testable import ZapaCalls

/// End to end against a real calls service (services/calls on `wrangler dev`, with the fake Realtime/TURN server
/// on loopback). Off unless the environment names the service and two chat tokens for the same conversation:
///   TEST_RUNNER_ZK_CALLS_E2E_URL=http://127.0.0.1:8790
///   TEST_RUNNER_ZK_CALLS_E2E_CONVERSATION=<conversation id>
///   TEST_RUNNER_ZK_CALLS_E2E_TOKEN_A=<chat token, device A>   TEST_RUNNER_ZK_CALLS_E2E_TOKEN_B=<chat token, device B>
///   TEST_RUNNER_ZK_CALLS_E2E_DEVICE_A=<accountId>.<deviceId>
///   TEST_RUNNER_ZK_CALLS_E2E_DEVICE_B=<accountId>.<deviceId>
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

        // Both see the roster with both devices, the server's epoch and key leader.
        let call = try await CallsE2E.first(in: bobEvents) { signal -> CallSnapshot? in
            if case let .roster(call) = signal, call.participants.count == 2 {
                call
            } else {
                nil
            }
        }
        #expect(call.participants.map(\.name).sorted() == [env.deviceA, env.deviceB].sorted())
        let leader = try #require(call.keyLeader?.name)
        let follower = leader == env.deviceA ? env.deviceB : env.deviceA
        let leaderSocket = leader == env.deviceA ? aliceSocket : bobSocket
        let followerEvents = leader == env.deviceA ? bobEvents : aliceEvents

        // The leader's sealed key for the current epoch reaches the other device unchanged.
        let envelope = KeyEnvelope(epoch: call.epoch, fromDevice: leader, toDevice: follower, blob: Data([1, 2, 3, 4]))
        try await leaderSocket.send(.keys(epoch: call.epoch, [envelope]))
        let relayed = try await CallsE2E.first(in: followerEvents) { signal -> KeyEnvelope? in
            if case let .key(got) = signal {
                got
            } else {
                nil
            }
        }
        #expect(relayed.blob == envelope.blob)
        #expect(relayed.fromDevice == leader)
        #expect(relayed.epoch == call.epoch)

        try await bob.leave(callId: grant.callId)
        let left = try await CallsE2E.first(in: aliceEvents) { signal -> String? in
            if case let .left(device, _) = signal {
                device.name
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
