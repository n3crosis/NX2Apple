import XCTest

/// `--host`: the views on the real host layer, with the fixture bundles in the app's Games folder.
@MainActor final class ShellHostUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(select id: String) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", id]
        app.launch()
        XCTAssertTrue(app.buttons["tile.\(id)"].waitForExistence(timeout: 10))
    }

    func testImportOffersFilesAndSharingLinkAndCanReopen() {
        launch(select: "0100000000010000")
        for _ in 0..<2 {
            let open = app.buttons["package.import.open"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true AND isEnabled == true"), object: open)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            open.tap()
            app.buttons["package.import.choose"].tap()
            XCTAssertTrue(app.buttons["Choose file…"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["Sharing link"].exists)
            XCTAssertFalse(app.buttons["Receive game"].isEnabled)
            app.navigationBars["Import prebuilt games"].buttons["Cancel"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
        }
    }

    func testSigningIdentityBackReturnsToSettings() {
        launch(select: "0100000000010000")
        app.buttons["shellSettings.open"].tap()
        let signing = app.buttons["shellSettings.signing"]
        XCTAssertTrue(signing.waitForExistence(timeout: 5))
        if !signing.isHittable { app.swipeUp() }
        signing.tap()
        XCTAssertTrue(app.buttons["signing.chooseP12"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signing.chooseProfile"].exists)
        XCTAssertTrue(app.secureTextFields["signing.password"].exists)
        XCTAssertFalse(app.buttons["signing.save"].isEnabled)
        let back = app.navigationBars["Signing identity"].buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["shellSettings.signing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["signing.chooseP12"].exists)
    }

    func testBundledGameSettingsDoNotOfferResigning() {
        launch(select: "0100000000010000")
        XCTAssertFalse(app.buttons["signing.open"].exists)
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["set.resign"].exists)
        XCTAssertFalse(app.buttons["signing.chooseP12"].exists)
    }

    func testPlayableFixtureSaysLaunchingIsNotAvailable() {
        launch(select: "0100000000010000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        let primary = app.buttons.matching(identifier: "state.action").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(primary)
        primary?.tap()
        XCTAssertTrue(app.alerts["NX2Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Launching is not available yet."].exists)
        app.alerts.buttons["OK"].tap()
    }

    func testBrokenFixtureShowsItsReason() {
        launch(select: "0100000000040000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "No Framework Fixture")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Fix Game Files")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'DmGame.framework'")).firstMatch.exists)
        openRecoveryHelp()
        XCTAssertTrue(app.staticTexts["The game's code is missing from this app. Rebuild and reinstall it."].waitForExistence(timeout: 5))
    }

    func testBadSettingsShowsASentenceAndKeepsTheRawMessageInDetails() {
        launch(select: "0100000000070000")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Fix Game Files")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'DM_X'")).firstMatch.exists)
        openRecoveryHelp()
        XCTAssertTrue(app.staticTexts["This game's settings list is damaged. Rebuild the game in the launcher on your Mac."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DM_X is a choice without [value, label] options."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Details"].exists)
    }

    func testUnreadableManifestIsUnknownGameWithoutTheTitleIDInTheMainUI() {
        launch(select: "0100000000050000")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Unknown game")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0100000000050000'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Fix Game Files")).firstMatch.exists)
        openRecoveryHelp()
        XCTAssertTrue(app.staticTexts["This game's manifest is damaged. Rebuild the game in the launcher on your Mac."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["help.titleid"].label, "Title ID 0100000000050000")
    }

    private func openRecoveryHelp() {
        let fix = app.buttons["state.action"]
        XCTAssertTrue(fix.waitForExistence(timeout: 5))
        XCTAssertTrue(fix.isHittable)
        fix.tap()
        XCTAssertTrue(app.staticTexts["help.title"].waitForExistence(timeout: 5))
    }

    func testLibraryStartsOnAPlayableGameWithoutAVersionLineOnTheCover() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hero.title"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.staticTexts["hero.title"].label, "Bad Settings Fixture")
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        // The accepted design shows the version in the game's settings only, no longer under the hero title.
        XCTAssertFalse(app.staticTexts["Version 1.0.0"].exists)
    }

    func testSettingChangeSurvivesReopeningSettings() {
        launch(select: "0100000000010000")
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let frameRate = app.switches["setting.DM_SHOW_FPS"]
        XCTAssertTrue(frameRate.waitForExistence(timeout: 5))
        XCTAssertEqual(frameRate.value as? String, "0")
        // The accessibility switch spans the row, while the native UISwitch is at its trailing edge.
        frameRate.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let enabled = NSPredicate(format: "value == %@", "1")
        expectation(for: enabled, evaluatedWith: frameRate)
        waitForExpectations(timeout: 5)
        app.buttons["library.back"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(frameRate.waitForExistence(timeout: 5))
        XCTAssertEqual(frameRate.value as? String, "1")
    }

    func testStrippedFrameworkWithoutShadersShowsUpdateDataAction() {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--host", "--select", "0100000000010000", "--omit-msl", "0100000000010000"]
        app.launch()
        XCTAssertTrue(app.buttons["tile.0100000000010000"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["hero.title"].label, "Orbit Fixture")
        let action = app.buttons["state.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("Update game data"))
        XCTAssertFalse(app.buttons["settings.open"].exists)
    }
}
