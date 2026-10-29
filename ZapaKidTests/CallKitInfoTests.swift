import Foundation
import Testing

/// CallKit refuses every call (CXErrorCodeRequestTransactionError.unentitled) from an app without the `voip`
/// background mode, and calls must keep their audio when the phone locks (`audio`). Calls did nothing at all on
/// device until these were set (Stefan, 2026-10-29).
struct CallKitInfoTests {
    let modes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []

    @Test func callKitMayStartAndReportCalls() {
        #expect(modes.contains("voip"))
    }

    @Test func callAudioKeepsRunningWhenThePhoneLocks() {
        #expect(modes.contains("audio"))
    }
}
