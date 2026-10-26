import Foundation
import Testing

/// Checks on the built app (the test host): App Transport Security stays strict, with no exceptions.
struct AppSecurityTests {
    let info = Bundle.main.infoDictionary ?? [:]

    @Test func runsInsideTheApp() {
        #expect(Bundle.main.bundleIdentifier == "com.zapacit.cuzaai")
    }

    @Test func appTransportSecurityHasNoExceptions() {
        // No NSAppTransportSecurity key at all means iOS's strict defaults: HTTPS only, no arbitrary loads.
        // TLS 1.3 is enforced on the API session (HTTPAuthAPITests.defaultSessionRequiresTLS13...).
        #expect(info["NSAppTransportSecurity"] == nil)
    }
}
