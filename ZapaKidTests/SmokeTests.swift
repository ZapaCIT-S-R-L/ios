import Testing
import ZapaKidKit

struct SmokeTests {
    @Test func apiIsStaging() {
        #expect(ZapaKidKit.apiBaseURL == "https://api-staging.zapakid.ro")
    }
}
