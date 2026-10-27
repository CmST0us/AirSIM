import XCTest

class UITestCase: XCTestCase {
    let app = XCUIApplication()
    var scenario: String { "v2-unconfigured" }
    var presentationArguments: [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "--ui-scenario", scenario
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

final class NavigationTests: UITestCase {
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
        let diagnostics = app.buttons["连接与音频诊断"]
        for _ in 0..<5 where !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["诊断"].waitForExistence(timeout: 5))
        capture("v2-diagnostics")
    }

    func testV2CanReturnToDialAfterBrowsingMessagesAndRecents() {
        openTab("短信")
        openTab("最近")
        openTab("拨号")
        XCTAssertFalse(app.tabBars.buttons["模块与通话"].exists)
        capture("v2-dial-return")
    }
}

final class FreshInstallTests: UITestCase {
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

final class LocalNavigationTests: UITestCase {
    override var scenario: String { "local-unpaired" }

    func testLocalRetainsOriginalTabsAndPairingEntry() {
        verifyOriginalTabs()
        let pairing = app.buttons["配对三星手机"]
        for _ in 0..<4 where !pairing.isHittable { app.swipeUp() }
        XCTAssertTrue(pairing.isHittable)
        capture("local-pairing-settings")
    }
}

final class V1NavigationTests: UITestCase {
    override var scenario: String { "v1-unpaired" }

    func testV1RetainsOriginalTabsAndRelaySettings() {
        verifyOriginalTabs()
        let save = app.buttons["保存 Relay 地址"]
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        capture("v1-relay-settings")
    }
}

final class DarkAppearanceTests: UITestCase {
    override var presentationArguments: [String] { ["-airsim.appearance", "dark"] }

    func testDarkAppearanceNavigationScreenshots() { verifyOriginalTabs() }
}

final class LargeTextTests: UITestCase {
    override var presentationArguments: [String] {
        ["-airsim.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }

    func testLargeTextNavigationRemainsReachable() { verifyOriginalTabs() }
}

final class LivePairingTests: UITestCase {
    override var scenario: String { "v2-pairing-live" }

    func testLivePairingThroughWebCode() throws {
        guard let code = ProcessInfo.processInfo.environment["PAIRING_CODE"], code.count == 8 else {
            throw XCTSkip("PAIRING_CODE is supplied by the physical web pairing run")
        }
        openTab("设置")
        let add = app.buttons["v2-add-device"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isEnabled)
        add.tap()

        let field = app.textFields["v2-pairing-code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        let lookup = app.buttons["查找设备"]
        XCTAssertTrue(lookup.exists)
        lookup.tap()

        XCTAssertTrue(app.staticTexts["v2-pairing-device-name"].waitForExistence(timeout: 10))
        let confirm = app.buttons["v2-pairing-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let persistent = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "设备授权已安全保存在本机"
        )).firstMatch
        XCTAssertTrue(persistent.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "模块 · ")).firstMatch.exists)
        capture("live-pairing-complete")
    }
}

final class IncomingCallViewTests: UITestCase {
    override var scenario: String { "v2-incoming-fixture" }

    func testIncomingUsesOriginalAnswerAndRejectControls() {
        let answer = app.buttons["接听"]
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        XCTAssertTrue(answer.isHittable)
        XCTAssertTrue(app.buttons["拒接"].isHittable)
        XCTAssertFalse(app.buttons["录音"].exists)
        XCTAssertFalse(app.buttons["停止录音"].exists)
        XCTAssertFalse(app.tabBars.buttons["模块与通话"].exists)
        capture("v2-incoming-original-controls")
    }
}

final class ActiveCallViewTests: UITestCase {
    override var scenario: String { "v2-active-fixture" }

    func testActiveUsesOriginalControlsWithoutMediaOrRecording() {
        let hangup = app.buttons["挂断"]
        XCTAssertTrue(hangup.waitForExistence(timeout: 15))
        XCTAssertTrue(hangup.isHittable)
        XCTAssertTrue(app.buttons["键盘"].isHittable)
        XCTAssertTrue(app.buttons["静音"].exists)
        XCTAssertFalse(app.buttons["静音"].isEnabled)
        XCTAssertTrue(app.buttons["扬声器"].exists)
        XCTAssertFalse(app.buttons["扬声器"].isEnabled)
        XCTAssertFalse(app.buttons["录音"].exists)
        XCTAssertFalse(app.buttons["停止录音"].exists)
        capture("v2-active-original-controls")
        app.buttons["键盘"].tap()
        XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
        capture("v2-active-original-keypad")
        app.buttons["取消"].tap()
        XCTAssertTrue(hangup.waitForExistence(timeout: 5))
        XCTAssertTrue(hangup.isHittable)
    }
}

final class RealRuntimeDiagnosticTests: XCTestCase {
    func testReconnectRealRuntimeAndDumpUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let reconnect = app.buttons["重新连接"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        sleep(8)

        let dial = app.tabBars.buttons["拨号"]
        XCTAssertTrue(dial.waitForExistence(timeout: 10))
        dial.tap()
        sleep(1)
        print("AIRSIM_REAL_UI_BEGIN\n\(app.debugDescription)\nAIRSIM_REAL_UI_END")
    }

    func testRealV2Dial() throws {
        guard let number = ProcessInfo.processInfo.environment["AIRSIM_DIAGNOSTIC_NUMBER"], !number.isEmpty else {
            throw XCTSkip("AIRSIM_DIAGNOSTIC_NUMBER is required")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        app.tabBars.buttons["设置"].tap()
        let reconnect = app.buttons["重新连接"]
        if reconnect.exists { reconnect.tap(); sleep(6) }
        let module = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "module-")).firstMatch
        for _ in 0..<5 where !module.exists { app.swipeUp() }
        XCTAssertTrue(module.waitForExistence(timeout: 10))
        if !app.buttons.matching(NSPredicate(format: "identifier == %@", module.identifier)).firstMatch.isSelected {
            module.tap()
            sleep(2)
        }

        for _ in 0..<5 { app.swipeDown() }
        app.tabBars.buttons["拨号"].tap()
        let labels = [
            "0": "0 +", "1": "1", "2": "2 ABC", "3": "3 DEF", "4": "4 GHI",
            "5": "5 JKL", "6": "6 MNO", "7": "7 PQRS", "8": "8 TUV", "9": "9 WXYZ"
        ]
        for digit in number {
            let key = app.buttons[labels[String(digit)]!]
            XCTAssertTrue(key.waitForExistence(timeout: 3))
            key.tap()
        }
        var call: XCUIElement?
        for _ in 0..<30 {
            let candidate = app.buttons.matching(identifier: "phone.fill").firstMatch
            if candidate.exists, candidate.isEnabled {
                call = candidate
                break
            }
            sleep(1)
        }
        guard let call else {
            XCTFail("real v2 call did not become enabled")
            return
        }
        call.tap()
        print("AIRSIM_REAL_CALL_STARTED")
        let hangup = app.buttons["挂断"]
        XCTAssertTrue(hangup.waitForExistence(timeout: 12))
        sleep(5)
        hangup.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "phone.fill").firstMatch.waitForExistence(timeout: 12))
    }
}
