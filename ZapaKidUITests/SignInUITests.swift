import XCTest

/// Parent sign-in, end to end in the app with a stubbed backend (launch argument `-zk-ui-test`, Debug builds only):
/// no network, a fake Google account, a fresh in-memory session store on every launch.
@MainActor
final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(
        agreement: String = "accepted",
        session: String = "none",
        age: String = "adult",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"] + extraArguments
        app.launchEnvironment = ["ZK_AGREEMENT": agreement, "ZK_SESSION": session, "ZK_AGE": age]
        app.launch()
        return app
    }

    func testFirstLaunchShowsTheParentalAgreementPlaceholderThenSignIn() {
        let app = launch(agreement: "pending")

        XCTAssertTrue(app.otherElements["agreement.screen"].waitForExistence(timeout: 10))
        app.buttons["agreement.accept"].tap()

        XCTAssertTrue(app.otherElements["signin.screen"].waitForExistence(timeout: 5))
    }

    func testSignInScreenShowsAppleAndGoogleButtons() {
        let app = launch()

        XCTAssertTrue(app.otherElements["signin.screen"].waitForExistence(timeout: 10))
        let apple = app.buttons["signin.apple"]
        let google = app.buttons["signin.google"]
        XCTAssertTrue(apple.exists)
        XCTAssertTrue(google.exists)
        XCTAssertTrue(apple.isHittable)
        XCTAssertTrue(google.isHittable)
        XCTAssertFalse(google.label.isEmpty, "VoiceOver reads a label")
        XCTAssertEqual(google.label, "Sign in with Google")
    }

    func testGoogleSignInShowsTheSignedInStateAndSignOutReturnsToSignIn() {
        let app = launch()
        XCTAssertTrue(app.buttons["signin.google"].waitForExistence(timeout: 10))

        app.buttons["signin.google"].tap()

        XCTAssertTrue(app.otherElements["home.screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TEST Parent"].exists)
        app.buttons["home.signOut"].tap()
        XCTAssertTrue(app.otherElements["signin.screen"].waitForExistence(timeout: 5))
    }

    func testStoredSessionOpensSignedIn() {
        let app = launch(session: "signed-in")

        XCTAssertTrue(app.otherElements["home.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["TEST Parent"].exists)
    }

    func testMinorIsBlocked() {
        let app = launch(age: "minor")
        XCTAssertTrue(app.buttons["signin.google"].waitForExistence(timeout: 10))

        app.buttons["signin.google"].tap()

        XCTAssertTrue(app.otherElements["blocked.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["home.screen"].exists)
    }

    func testLargestDynamicTypeKeepsSignInReachable() {
        let app = launch(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        XCTAssertTrue(app.otherElements["signin.screen"].waitForExistence(timeout: 10))

        for id in ["signin.apple", "signin.google"] {
            let button = app.buttons[id]
            if !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, "\(id) can be reached at the largest text size")
        }
    }
}
