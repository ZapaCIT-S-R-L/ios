import XCTest

/// The family: a signed-in parent adds a kid and shows the pairing QR; the kid's phone redeems a code.
/// Stubbed backend (`-zk-ui-test`), no network, no camera.
@MainActor
final class FamilyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(session: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zk-ui-test"]
        app.launchEnvironment = ["ZK_AGREEMENT": "accepted", "ZK_SESSION": session, "ZK_AGE": "adult"]
        app.launch()
        return app
    }

    func testParentAddsAKidAndShowsThePairingQR() {
        let app = launch(session: "signed-in")
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["family.addKid"].waitForExistence(timeout: 5))
        app.buttons["family.addKid"].tap()
        let nickname = app.textFields["addKid.nickname"]
        XCTAssertTrue(nickname.waitForExistence(timeout: 5))
        nickname.tap()
        nickname.typeText("Ana")
        app.buttons["addKid.avatar.robot-4"].tap()
        app.buttons["addKid.save"].tap()

        let pair = app.buttons["family.kid.Ana.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        pair.tap()
        XCTAssertTrue(app.images["pairing.qr"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["pairing.qr"].label.isEmpty, "VoiceOver says what the QR is for")
    }

    /// Stefan (2026-10-28): "father can't change name".
    func testParentChangesTheirName() {
        let app = launch(session: "signed-in")
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()

        let me = app.buttons["family.me"]
        XCTAssertTrue(me.waitForExistence(timeout: 5))
        me.tap()
        let field = app.textFields["rename.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.clearAndType("Tata Stefan")
        app.buttons["rename.save"].tap()

        let renamed = NSPredicate(format: "label CONTAINS %@", "Tata Stefan")
        expectation(for: renamed, evaluatedWith: me)
        waitForExpectations(timeout: 5)
    }

    func testParentInvitesTheSecondParent() {
        let app = launch(session: "signed-in")
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["family.inviteParent"].waitForExistence(timeout: 5))
        app.buttons["family.inviteParent"].tap()

        XCTAssertTrue(app.images["invite.qr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["invite.share"].exists)
    }

    func testKidPhonePairsWithACode() {
        let app = launch(session: "none")
        XCTAssertTrue(app.buttons["signin.kidPhone"].waitForExistence(timeout: 10))
        app.buttons["signin.kidPhone"].tap()

        let field = app.textFields["pair.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zkp_" + String(repeating: "P", count: 43))
        app.buttons["pair.submit"].tap()

        // The kid lands on Chats, with no greeting above them (Stefan, 2026-10-28: the app doesn't need to be
        // friendly).
        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["kid.hello"].exists)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
