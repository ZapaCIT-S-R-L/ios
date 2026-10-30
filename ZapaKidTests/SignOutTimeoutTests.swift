import Foundation
import Testing
@testable import ZapaKidKit

@MainActor
struct SignOutTimeoutTests {
    @Test func signOutTimeoutDoesNotWaitForAnUncooperativeCallback() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var finished = false
        let timeout = Task {
            await AuthModel.withTimeout(seconds: 0.02) {
                await withCheckedContinuation { gate = $0 }
            }
            finished = true
        }
        // Always release the callback, including when testing the broken structured timeout, so CI cannot hang.
        for _ in 0 ..< 200 where gate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished)
        gate?.resume()
        await timeout.value
    }
}
