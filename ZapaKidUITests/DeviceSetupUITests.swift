import XCTest

/// When this phone can't finish its secure setup, the app says so calmly and offers "Try again"; a kid phone that
/// must be paired again says to ask a parent. Stubbed setup (`ZK_SETUP`).
@MainActor
final class DeviceSetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(setup: String, kid: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"]
        app.launchEnvironment = [
            "ZK_AGREEMENT": "accepted", "ZK_SESSION": kid ? "none" : "signed-in", "ZK_AGE": "adult",
            "ZK_KID": kid ? "paired" : "none", "ZK_SETUP": setup,
        ]
        app.launch()
        return app
    }

    func testAFailingSetupOffersTryAgain() {
        let app = launch(setup: "fail", kid: false)

        let retry = app.buttons["setup.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(retry.label, "Try again")
        XCTAssertTrue(app.staticTexts["setup.message"].exists)
        retry.tap()
        XCTAssertTrue(app.buttons["setup.retry"].waitForExistence(timeout: 5), "still calm while it keeps trying")
    }

    func testAKidPhoneThatMustBePairedAgainSaysSo() {
        let app = launch(setup: "pair-again", kid: true)

        let message = app.staticTexts["setup.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Ask a parent to pair this phone again.")
        XCTAssertFalse(app.buttons["setup.retry"].exists)
    }
}
