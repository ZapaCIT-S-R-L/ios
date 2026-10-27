import XCTest

/// Chats, Chat, Call and Family in both looks (stubbed services). With `TEST_RUNNER_ZK_SCREENSHOTS=<folder>` the
/// test also writes <role>-<screen>.png there, for design review.
@MainActor
final class ThemeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(kid: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"]
        app.launchEnvironment = [
            "ZK_AGREEMENT": "accepted", "ZK_SESSION": kid ? "none" : "signed-in", "ZK_AGE": "adult",
            "ZK_KID": kid ? "paired" : "none", "ZK_DEMO_FAMILY": "1",
        ]
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["ZK_SCREENSHOTS"], !folder.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    private func walk(_ role: String, kid: Bool) {
        let app = launch(kid: kid)

        // Chats: the theme's marker, the conversation and the tabs.
        XCTAssertTrue(app.staticTexts["theme.e2ee"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["theme.e2ee"].value as? String, role)
        XCTAssertTrue(app.buttons["chats.row.\(kid ? "Mama" : "Ana")"].exists)
        XCTAssertTrue(app.tabBars.buttons["Family"].exists)
        shoot(app, "\(role)-chats")

        // Chat: a message both ways.
        app.buttons["chats.row.\(kid ? "Mama" : "Ana")"].tap()
        let field = app.textFields["chat.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(kid ? "Can Maria come over?" : "Yes, after homework!")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Hi! 👋"].waitForExistence(timeout: 10))
        if app.keyboards.firstMatch.exists {
            app.swipeDown()
        }
        shoot(app, "\(role)-chat")

        // Call: big mute, speaker and hang-up buttons.
        app.buttons["chat.call"].tap()
        XCTAssertTrue(app.staticTexts["call.timer"].waitForExistence(timeout: 10))
        for id in ["call.mute", "call.speaker", "call.end"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.width, kid ? 76 : 64, id)
        }
        shoot(app, "\(role)-call")
        app.buttons["call.end"].tap()
        app.buttons["call.close"].tap()

        // Family.
        app.tabBars.buttons["Family"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["family.screen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["family.addKid"].exists, !kid, "only parents add kids")
        shoot(app, "\(role)-family")
    }

    func testParentLook() {
        walk("parent", kid: false)
    }

    func testKidLook() {
        walk("kid", kid: true)
    }
}
