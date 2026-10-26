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
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"] + extraArguments
        app.launchEnvironment = ["ZK_AGREEMENT": agreement, "ZK_SESSION": session, "ZK_AGE": age]
            .merging(extraEnvironment) { $1 }
        app.launch()
        return app
    }

    func testFirstLaunchShowsTheParentalAgreementPlaceholderThenSignIn() {
        let app = launch(agreement: "pending")

        XCTAssertTrue(app.screen("agreement.screen").waitForExistence(timeout: 10))
        app.buttons["agreement.accept"].tap()

        XCTAssertTrue(app.screen("signin.screen").waitForExistence(timeout: 5))
    }

    func testSignInScreenShowsAppleAndGoogleButtons() {
        let app = launch()

        XCTAssertTrue(app.screen("signin.screen").waitForExistence(timeout: 10))
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

        XCTAssertTrue(app.screen("home.screen").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["home.parentName"].label, "TEST Parent")
        app.buttons["home.signOut"].tap()
        XCTAssertTrue(app.screen("signin.screen").waitForExistence(timeout: 5))
    }

    func testStoredSessionOpensSignedIn() {
        let app = launch(session: "signed-in")

        XCTAssertTrue(app.screen("home.screen").waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["home.parentName"].label, "TEST Parent")
    }

    func testMinorIsBlocked() {
        let app = launch(age: "minor")
        XCTAssertTrue(app.buttons["signin.google"].waitForExistence(timeout: 10))

        app.buttons["signin.google"].tap()

        XCTAssertTrue(app.screen("blocked.screen").waitForExistence(timeout: 5))
        XCTAssertFalse(app.screen("home.screen").exists)
    }

    func testDeclinedAgeShowsTheDeclinedScreenAndTryAgainReturnsToSignIn() {
        let app = launch(age: "declined")
        XCTAssertTrue(app.buttons["signin.google"].waitForExistence(timeout: 10))

        app.buttons["signin.google"].tap()

        XCTAssertTrue(app.screen("declined.screen").waitForExistence(timeout: 5))
        app.buttons["declined.tryAgain"].tap()
        XCTAssertTrue(app.screen("signin.screen").waitForExistence(timeout: 5))
    }

    func testRateLimitedSignInSaysWhenToTryAgain() {
        let app = launch(extraEnvironment: ["ZK_SIGNIN": "rate-limited"])
        XCTAssertTrue(app.buttons["signin.google"].waitForExistence(timeout: 10))

        app.buttons["signin.google"].tap()

        let error = app.staticTexts["signin.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("30"), "says to wait 30 seconds")
    }

    func testLargestDynamicTypeKeepsSignInReachable() {
        let app = launch(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        XCTAssertTrue(app.screen("signin.screen").waitForExistence(timeout: 10))

        for id in ["signin.apple", "signin.google"] {
            let button = app.buttons[id]
            if !button.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(button.isHittable, "\(id) can be reached at the largest text size")
        }
    }
}

extension XCUIApplication {
    /// A screen by its accessibility identifier, whatever element type SwiftUI gives its container
    /// (a ScrollView shows up as a scroll view, a NavigationStack as an other element).
    func screen(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
