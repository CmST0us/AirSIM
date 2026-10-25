import XCTest

class R7UITestCase: XCTestCase {
    let app = XCUIApplication()
    var scenario: String { "v2-unconfigured" }
    var presentationArguments: [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--r7-ui-scenario", scenario
        ] + presentationArguments
        app.launch()
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 {
            capture("failure")
        }
        app.terminate()
    }

    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "缺少原标签：\(title)", file: file, line: line)
        guard tab.exists else { return }
        tab.tap()
        XCTAssertTrue(tab.isSelected, file: file, line: line)
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func verifyOriginalTabs() {
        for title in ["拨号", "最近", "短信", "联系人", "设置"] {
            openTab(title)
            capture("\(scenario)-\(title)")
        }
        XCTAssertEqual(app.tabBars.buttons.count, 5)
    }
}

final class R7NavigationTests: R7UITestCase {
    func testV2UsesAllFiveOriginalTabs() {
        verifyOriginalTabs()
        XCTAssertFalse(app.tabBars.buttons["模块与通话"].exists)
    }

    func testV2SettingsDoNotExposeLegacyPairingOrRelaySelfTest() {
        openTab("设置")
        XCTAssertFalse(app.buttons["配对三星手机"].exists)
        XCTAssertFalse(app.buttons["运行云端模式自检"].exists)
        XCTAssertFalse(app.buttons["保存 Relay 地址"].exists)
        capture("v2-settings")
    }

    func testV2CanReturnToDialAfterBrowsingMessagesAndRecents() {
        openTab("短信")
        openTab("最近")
        openTab("拨号")
        XCTAssertFalse(app.tabBars.buttons["模块与通话"].exists)
        capture("v2-dial-return")
    }
}

final class R7FreshInstallTests: R7UITestCase {
    override var scenario: String { "fresh" }

    func testFreshInstallRequiresExplicitConnectionChoice() {
        XCTAssertTrue(app.buttons["仅本地 VoWLAN"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["云端 v1（现有版本）"].exists)
        let v2Choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "云端 v2")).firstMatch
        XCTAssertTrue(v2Choice.exists)
        XCTAssertEqual(app.tabBars.count, 0)
        capture("fresh-connection-choice")
        app.buttons["仅本地 VoWLAN"].tap()
        XCTAssertTrue(app.buttons["稍后在设置中配对"].waitForExistence(timeout: 10))
        capture("local-first-connection")
        app.buttons["稍后在设置中配对"].tap()
        openTab("拨号")
    }
}

final class R7LocalNavigationTests: R7UITestCase {
    override var scenario: String { "local-unpaired" }

    func testLocalRetainsOriginalTabsAndPairingEntry() {
        verifyOriginalTabs()
        let pairing = app.buttons["配对三星手机"]
        for _ in 0..<4 where !pairing.isHittable { app.swipeUp() }
        XCTAssertTrue(pairing.isHittable)
        capture("local-pairing-settings")
    }
}

final class R7V1NavigationTests: R7UITestCase {
    override var scenario: String { "v1-unpaired" }

    func testV1RetainsOriginalTabsAndRelaySettings() {
        verifyOriginalTabs()
        let save = app.buttons["保存 Relay 地址"]
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        capture("v1-relay-settings")
    }
}

final class R7DarkAppearanceTests: R7UITestCase {
    override var presentationArguments: [String] { ["-airsim.appearance", "dark"] }

    func testDarkAppearanceNavigationScreenshots() { verifyOriginalTabs() }
}

final class R7LargeTextTests: R7UITestCase {
    override var presentationArguments: [String] {
        ["-airsim.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }

    func testLargeTextNavigationRemainsReachable() { verifyOriginalTabs() }
}
