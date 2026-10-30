import XCTest

/// The call screens with a fake call engine (launch argument `-zk-ui-test`, `ZK_CALL`, Debug builds only):
/// no network, no microphone. The fake answers an outgoing call after a moment and makes the others "speak".
@MainActor
final class CallsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ call: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"] + arguments
        app.launchEnvironment = ["ZK_CALL": call]
        app.launch()
        return app
    }

    func testOutgoingCallRingsConnectsMutesAndEnds() {
        let app = launch("outgoing")

        // "Calling…" lasts about a second with the demo engine; the call clock replaces it once Mama answers.
        XCTAssertTrue(app.staticTexts["call.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["call.name"].label, "Mama")
        XCTAssertTrue(app.staticTexts["call.timer"].waitForExistence(timeout: 10), "the call clock shows once answered")

        let mute = app.buttons["call.mute"]
        XCTAssertTrue(mute.isHittable)
        XCTAssertEqual(mute.label, "Mute")
        mute.tap()
        XCTAssertEqual(mute.label, "Unmute")

        let speaker = app.buttons["call.speaker"]
        XCTAssertEqual(speaker.label, "Speaker")
        XCTAssertEqual(speaker.value as? String, "Off")
        speaker.tap()
        XCTAssertEqual(speaker.value as? String, "On")

        app.buttons["call.end"].tap()
        waitForLabel(app.staticTexts["call.status"], "Call ended")
    }

    func testIncomingCallShowsBigAcceptAndDeclineButtons() {
        let app = launch("incoming")

        let accept = app.buttons["call.accept"]
        let decline = app.buttons["call.decline"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        XCTAssertEqual(accept.label, "Accept")
        XCTAssertEqual(decline.label, "Decline")
        XCTAssertGreaterThanOrEqual(accept.frame.width, 72, "big round buttons for small fingers")
        XCTAssertEqual(app.staticTexts["call.name"].label, "Mama")

        accept.tap()
        XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["call.timer"].waitForExistence(timeout: 10))
    }

    func testDecliningAnIncomingCallEndsIt() {
        let app = launch("incoming")

        XCTAssertTrue(app.buttons["call.decline"].waitForExistence(timeout: 10))
        app.buttons["call.decline"].tap()

        waitForLabel(app.staticTexts["call.status"], "Declined")
    }

    func testGroupCallShowsEveryoneAsABubbleAndWhoIsSpeaking() {
        let app = launch("group")

        XCTAssertTrue(app.staticTexts["call.timer"].waitForExistence(timeout: 10))
        for name in ["Mama", "Tata", "Ana"] {
            XCTAssertTrue(app.otherElements["call.peer.\(name)"].exists, "\(name) has a bubble")
        }
        let speaking = NSPredicate(format: "value == %@", "speaking")
        expectation(for: speaking, evaluatedWith: app.otherElements["call.peer.Mama"])
        waitForExpectations(timeout: 10)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    func testRomanianLabels() {
        let app = launch("incoming", arguments: ["-AppleLanguages", "(ro)", "-AppleLocale", "ro_RO"])

        XCTAssertTrue(app.buttons["call.accept"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["call.accept"].label, "Răspunde")
        XCTAssertEqual(app.buttons["call.decline"].label, "Respinge")
    }

    func testLargestTextStillFitsTheButtons() {
        let app = launch("outgoing", arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])

        XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["call.end"].isHittable)
        XCTAssertTrue(app.buttons["call.mute"].isHittable)
        XCTAssertTrue(app.buttons["call.speaker"].isHittable)
    }
}
