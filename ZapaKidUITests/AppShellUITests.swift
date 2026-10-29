import XCTest

/// The signed-in app: tabs Chats / Calls / Family, new chats (parents and kids), a chat with a call button.
/// Stubbed chat and call services (`-zk-ui-test`): no network, no microphone.
@MainActor
final class AppShellUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(session: String = "signed-in", kid: Bool = false, demo: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"]
        app.launchEnvironment = [
            "ZK_AGREEMENT": "accepted", "ZK_SESSION": session, "ZK_AGE": "adult", "ZK_KID": kid ? "paired" : "none",
            "ZK_DEMO_FAMILY": demo ? "1" : "0",
        ]
        app.launch()
        return app
    }

    func testParentSeesChatsAndFamilyTabsOnly() {
        let app = launch()

        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Calls"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["family.addKid"].waitForExistence(timeout: 5))
    }

    func testKidSeesTheirFamilyButCannotManageIt() {
        let app = launch(session: "none", kid: true)

        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Calls"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["family.addKid"].exists)
        XCTAssertFalse(app.buttons["family.inviteParent"].exists)
    }

    func testSendingATextShowsItInTheChatAndTheReplyArrives() {
        let app = launch()
        let row = app.buttons["chats.row.Ana"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let field = app.textFields["chat.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Salut, Ana!")
        app.buttons["chat.send"].tap()

        XCTAssertTrue(app.staticTexts["Salut, Ana!"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hi! 👋"].waitForExistence(timeout: 10), "the stub replies")
    }

    func testAParentStartsANewChatWithAKid() {
        let app = launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        app.buttons["chats.new"].tap()

        let ana = app.buttons["newChat.person.Ana"]
        XCTAssertTrue(ana.waitForExistence(timeout: 5))
        ana.tap()
        app.buttons["newChat.start"].tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
    }

    /// Stefan, 2026-10-28: kids start chats too, with the people in their family (parents and brothers/sisters).
    func testAKidStartsANewChatWithAParent() {
        let app = launch(session: "none", kid: true, demo: true)
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        app.buttons["chats.new"].tap()

        let mama = app.buttons["newChat.person.Mama"]
        XCTAssertTrue(mama.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["newChat.person.Tata"].exists, "the other parent")
        XCTAssertTrue(app.buttons["newChat.person.Ion"].exists, "a brother")
        XCTAssertFalse(app.buttons["newChat.person.Ana"].exists, "not the kid themself")
        mama.tap()
        app.buttons["newChat.start"].tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
    }

    func testAnIncomingCallFromAChatRings() {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"]
        app.launchEnvironment = [
            "ZK_AGREEMENT": "accepted", "ZK_SESSION": "signed-in", "ZK_AGE": "adult", "ZK_RING": "1",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["call.accept"].waitForExistence(timeout: 15), "Ana calls a few seconds after launch")
        app.buttons["call.accept"].tap()
        XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
    }

    func testTheCallButtonInAChatStartsACall() {
        let app = launch()
        XCTAssertTrue(app.buttons["chats.row.Ana"].waitForExistence(timeout: 10))
        app.buttons["chats.row.Ana"].tap()

        XCTAssertTrue(app.buttons["chat.call"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chat.call"].label, "Call")
        app.buttons["chat.call"].tap()

        XCTAssertTrue(app.buttons["call.end"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["call.timer"].waitForExistence(timeout: 10))
        app.buttons["call.end"].tap()
        // Hanging up goes straight back to the chat; no "Close" screen (Stefan, 2026-10-29).
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["call.close"].exists)
    }

}
