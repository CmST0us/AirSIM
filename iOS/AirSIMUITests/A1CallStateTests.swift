import XCTest

final class A1CallStateTests: UITestCase {
    override var scenario: String { "v2-incoming-fixture" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testIncomingCallLayout() {
        let answer = callButton("answer")
        let decline = callButton("decline")
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        assertVisibleControls([decline, answer])
        XCTAssertLessThan(decline.frame.midX, answer.frame.midX)
        XCTAssertFalse(callButton("mute").exists)
        capture("a1-incoming-call")
    }

    func testActiveCallLayoutAndKeypadDismissal() {
        launchCallScenario("v2-active-fixture")
        let hangup = callButton("hangup")
        XCTAssertTrue(hangup.waitForExistence(timeout: 15))
        let mute = callButton("mute")
        let keypad = callButton("keypad")
        let speaker = callButton("speaker")
        assertVisibleControls([mute, keypad, speaker, hangup], disabled: [mute, speaker])
        XCTAssertLessThan(mute.frame.midX, keypad.frame.midX)
        XCTAssertLessThan(keypad.frame.midX, speaker.frame.midX)
        XCTAssertFalse(callButton("answer").exists)
        capture("a1-active-call")
        keypad.tap()
        XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["发送 DTMF 1"].isHittable)
        XCTAssertTrue(app.buttons["发送 DTMF #"].isHittable)
        capture("a1-call-keypad")
        app.buttons["完成"].tap()
        XCTAssertTrue(hangup.waitForExistence(timeout: 5))
        XCTAssertTrue(hangup.isHittable)
    }

    func testDialingCallLayout() {
        launchCallScenario("v2-dialing-fixture")
        let cancel = callButton("hangup")
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        assertVisibleControls([cancel])
        XCTAssertEqual(cancel.label, "取消呼叫")
        XCTAssertTrue(app.staticTexts["正在呼叫…"].exists)
        XCTAssertFalse(callButton("mute").exists)
        XCTAssertFalse(callButton("answer").exists)
        capture("a1-dialing-call")
    }

    private func launchCallScenario(_ name: String) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--ui-scenario", name] + presentationArguments
        app.launch()
    }

    private func callButton(_ name: String) -> XCUIElement {
        app.buttons["a1-call-state-" + name]
    }

    private func assertVisibleControls(_ controls: [XCUIElement], disabled: [XCUIElement] = [],
                                       file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        for (index, control) in controls.enumerated() {
            XCTAssertTrue(control.exists, file: file, line: line)
            XCTAssertTrue(screen.contains(control.frame), "通话按钮超出窗口", file: file, line: line)
            if !disabled.contains(where: { $0.identifier == control.identifier }) {
                XCTAssertTrue(control.isHittable, file: file, line: line)
            }
            for other in controls.dropFirst(index + 1) {
                XCTAssertFalse(control.frame.intersects(other.frame), "通话按钮重叠", file: file, line: line)
            }
        }
    }
}

final class A1EmptyStateTests: UITestCase {
    override var scenario: String { "design-empty" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testEmptyCallsAndContactsAndOfflineDial() {
        openTab("通话")
        let firstCall = app.buttons["拨打第一个电话"]
        XCTAssertTrue(firstCall.waitForExistence(timeout: 10))
        XCTAssertTrue(firstCall.isHittable)
        XCTAssertTrue(app.staticTexts["还没有通话记录"].exists)
        capture("a1-empty-calls")
        firstCall.tap()
        XCTAssertTrue(mainTab("拨号键盘").isSelected)
        XCTAssertTrue(app.buttons["a1-dial-key-1"].exists)
        XCTAssertFalse(app.buttons["a1-dial-call"].isEnabled)

        openTab("联系人")
        let addContact = app.buttons["添加联系人"].firstMatch
        XCTAssertTrue(addContact.waitForExistence(timeout: 5))
        XCTAssertTrue(addContact.isHittable)
        XCTAssertTrue(app.staticTexts["还没有联系人"].exists)
        capture("a1-empty-contacts")
        addContact.tap()
        XCTAssertTrue(app.navigationBars["新增联系人"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()

        openTab("短信")
        XCTAssertTrue(app.staticTexts["暂无短信"].waitForExistence(timeout: 5))
        capture("a1-empty-messages")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--ui-scenario", "v2-offline-fixture"] + presentationArguments
        app.launch()
        openTab("拨号键盘")
        XCTAssertTrue(app.staticTexts["号卡暂不可用"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["连接将自动恢复"].exists)
        XCTAssertFalse(app.buttons["a1-dial-call"].exists)
        for title in ["重试", "重新连接", "断开连接"] {
            XCTAssertFalse(app.buttons[title].exists)
        }
        capture("a1-offline-dial")
    }
}

final class A1AccessibleCallTests: UITestCase {
    override var scenario: String { "v2-active-fixture" }
    override var presentationArguments: [String] {
        ["-airsim.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }

    func testLargestTextCallControlsAndKeypadRemainReachable() {
        let keypad = app.buttons["a1-call-state-keypad"]
        XCTAssertTrue(keypad.waitForExistence(timeout: 10))
        for _ in 0..<6 where !keypad.isHittable || !app.scrollViews.firstMatch.frame.insetBy(dx: 0, dy: 44).contains(keypad.frame) { app.swipeUp() }
        XCTAssertTrue(keypad.isHittable)
        capture("hig-ax5-active-call")
        keypad.tap()
        XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
        let lastKey = app.buttons["发送 DTMF #"]
        for _ in 0..<4 where !lastKey.isHittable { app.swipeUp() }
        XCTAssertTrue(lastKey.isHittable)
        XCTAssertTrue(app.scrollViews.firstMatch.frame.contains(lastKey.frame))
        capture("hig-ax5-dtmf")
        app.buttons["完成"].tap()
        let hangup = app.buttons["a1-call-state-hangup"]
        for _ in 0..<6 where !hangup.isHittable || !app.scrollViews.firstMatch.frame.insetBy(dx: 0, dy: 44).contains(hangup.frame) { app.swipeUp() }
        XCTAssertTrue(hangup.isHittable)
    }
}
