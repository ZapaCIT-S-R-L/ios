import Foundation
import Testing
import ZapaCalls
@testable import ZapaKid

/// iOS refusing a call is never silent: the caller is told the call couldn't start, and the called phone that it
/// couldn't ring (review of ios #64: an incoming refusal was recorded but not shown).
struct CallRefusalAlertTests {
    @Test func anOutgoingRefusalSaysTheCallCouldntStart() {
        let alert = CallRefusalAlert(.outgoing)
        #expect(alert.title == "The call couldn't start")
        #expect(alert.message == "Your iPhone didn't allow the call. Check Do Not Disturb and try again.")
    }

    @Test func anIncomingRefusalSaysACallCouldntRing() {
        let alert = CallRefusalAlert(.incoming)
        #expect(alert.title == "A call couldn't ring")
        #expect(alert.message == "Your iPhone didn't let ZapaKid ring. Close ZapaKid and open it again.")
    }
}
