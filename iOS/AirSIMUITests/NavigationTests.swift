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

    func mainTab(_ title: String) -> XCUIElement {
        let tab = app.tabBars.buttons[title]
        return tab.exists ? tab : app.buttons[title].firstMatch
    }

    func verifyMainTabStructure(file: StaticString = #filePath, line: UInt = #line) {
        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.tabBars.buttons.count, 5, file: file, line: line)
        }
        let titles = ["通话", "联系人", "短信", "拨号键盘", "号卡"]
        for (index, title) in titles.enumerated() {
            let tab = mainTab(title)
            XCTAssertTrue(tab.exists, "缺少标签：\(title)", file: file, line: line)
            XCTAssertTrue(tab.isEnabled, "标签不可选择：\(title)", file: file, line: line)
            if index > 0 {
                let previous = mainTab(titles[index - 1]).frame
                if abs(previous.midY - tab.frame.midY) > 15 {
                    XCTAssertLessThan(previous.midY, tab.frame.midY, file: file, line: line)
                } else {
                    XCTAssertLessThan(previous.midX, tab.frame.midX, file: file, line: line)
                }
            }
        }
    }

    var messageBackButton: XCUIElement {
        let back = app.descendants(matching: .any).matching(identifier: "BackButton").firstMatch
        return back.exists ? back : app.navigationBars.buttons["短信"].firstMatch
    }
    var contactBackButton: XCUIElement { app.navigationBars.buttons["联系人"].firstMatch }

    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        if messageBackButton.exists { messageBackButton.tap() }
        if contactBackButton.exists { contactBackButton.tap() }
        let destination = title
        let tab = mainTab(destination)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "缺少标签：\(destination)", file: file, line: line)
        guard tab.exists else { return }
        tab.tap()
        XCTAssertTrue(tab.isSelected, file: file, line: line)

    }

    func keepEditing(in title: String) {
        let keep = app.buttons["继续编辑"]
        if keep.exists { keep.tap() }
        else { app.navigationBars[title].staticTexts[title].tap() }
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func verifyMainTabs() {
        for title in ["通话", "联系人", "短信", "拨号键盘", "号卡"] {
            openTab(title)
            capture("\(scenario)-\(title)")
        }
        verifyMainTabStructure()
    }
}

final class NavigationTests: UITestCase {
    func testV2UsesFiveMainTabs() {
        verifyMainTabs()
        XCTAssertFalse(mainTab("模块与通话").exists)
    }

    func testV2SettingsDoNotExposeLegacyPairingOrRelaySelfTest() {
        openTab("号卡")
        XCTAssertFalse(app.staticTexts["连接版本"].exists)
        XCTAssertFalse(app.buttons["云端 v1（现有版本）"].exists)
        XCTAssertFalse(app.buttons["仅本地 VoWLAN"].exists)
        XCTAssertFalse(app.buttons["配对三星手机"].exists)
        XCTAssertFalse(app.buttons["运行云端模式自检"].exists)
        XCTAssertFalse(app.buttons["保存 Relay 地址"].exists)
        capture("v2-settings")
        for label in ["导入连接文件", "重新连接", "断开连接", "连接与音频诊断", "重新登记后台推送"] {
            XCTAssertFalse(app.buttons[label].exists)
        }
        for label in ["权限与后台通知", "系统通话", "关于"] {
            XCTAssertFalse(app.staticTexts[label].exists)
        }
        XCTAssertTrue(app.buttons["v2-add-device"].exists)
        XCTAssertFalse(app.collectionViews.buttons["短信"].exists)
    }

    func testV2CanReturnToDialAfterBrowsingMessagesAndRecents() {
        openTab("短信")
        openTab("通话")
        openTab("拨号键盘")
        XCTAssertFalse(mainTab("模块与通话").exists)
        capture("v2-dial-return")
    }
}

final class FreshInstallTests: UITestCase {
    override var scenario: String { "fresh" }

    func testFreshInstallOpensDeviceSetupDirectly() {
        XCTAssertTrue(app.buttons["添加设备"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["云端 v1（现有版本）"].exists)
        XCTAssertFalse(app.buttons["仅本地 VoWLAN"].exists)
        capture("fresh-device-setup")
        let finish = app.buttons["完成，进入 AirSIM"]
        for _ in 0..<8 where !finish.isHittable { app.swipeUp() }
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        openTab("号卡")
        XCTAssertTrue(app.buttons["v2-add-device"].exists)
        XCTAssertFalse(app.staticTexts["连接版本"].exists)
    }
}

class LegacySelectionNavigationTests: UITestCase {
    override var scenario: String { "v1-unpaired" }

    func testSavedLegacySelectionOpensV2DeviceSetup() {
        openTab("号卡")
        XCTAssertTrue(app.buttons["v2-add-device"].exists)
        XCTAssertFalse(app.staticTexts["连接版本"].exists)
        XCTAssertFalse(app.buttons["配对三星手机"].exists)
        XCTAssertFalse(app.buttons["保存 Relay 地址"].exists)
        capture("legacy-selection-device-setup")
    }
}

final class LocalSelectionNavigationTests: LegacySelectionNavigationTests {
    override var scenario: String { "local-unpaired" }
}

final class DarkAppearanceTests: UITestCase {
    override var presentationArguments: [String] { ["-airsim.appearance", "dark"] }

    func testDarkAppearanceNavigationScreenshots() { verifyMainTabs() }
}

final class LargeTextTests: UITestCase {
    override var presentationArguments: [String] {
        ["-airsim.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }

    func testLargeTextNavigationRemainsReachable() { verifyMainTabs() }
}

final class LivePairingTests: UITestCase {
    override var scenario: String { "v2-pairing-live" }

    func testLivePairingThroughWebCode() throws {
        guard let code = ProcessInfo.processInfo.environment["PAIRING_CODE"], code.count == 8 else {
            throw XCTSkip("PAIRING_CODE is supplied by the physical web pairing run")
        }
        openTab("号卡")
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

        let module = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "module-")).firstMatch
        XCTAssertTrue(module.waitForExistence(timeout: 20))
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
        XCTAssertFalse(app.buttons["恢复音频"].exists)
        XCTAssertFalse(app.buttons["系统权限设置"].exists)
        XCTAssertFalse(mainTab("模块与通话").exists)
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
        XCTAssertFalse(app.buttons["恢复音频"].exists)
        XCTAssertFalse(app.buttons["系统权限设置"].exists)
        capture("v2-active-original-controls")
        app.buttons["键盘"].tap()
        XCTAssertTrue(app.navigationBars["通话键盘"].waitForExistence(timeout: 5))
        capture("v2-active-original-keypad")
        app.buttons["完成"].tap()
        XCTAssertTrue(hangup.waitForExistence(timeout: 5))
        XCTAssertTrue(hangup.isHittable)
    }
}

final class RealRuntimeDiagnosticTests: XCTestCase {
    func testModuleSignalOnDevice() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a paired physical device")
#else
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRSIM_LIVE_DEVICE_TESTS"] == "1", "Explicit live-device test invocation required")
        let app = XCUIApplication(bundleIdentifier: "com.eric3u.airsim2")
        app.launchArguments = ["-airsim.selected-tab", "拨号键盘"]
        app.launch()
        let selector = app.buttons["module-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 20), "Paired module selector did not load")
        let available = NSPredicate(format: "value CONTAINS %@", "蜂窝信号，")
        let expectation = XCTNSPredicateExpectation(predicate: available, object: selector)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 40), .completed, "Live module signal did not reach the App")
        let value = selector.value as? String ?? ""
        let level = (0...4).first { value.contains("蜂窝信号，\($0) 格，共 4 格") }
        XCTAssertNotNil(level, "Unexpected signal level")
        print("AIRSIM_SIGNAL_DEVICE_VERIFIED bars=\(level ?? -1)")
#endif
    }

    func testV2OnlySettingsOnDevice() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a paired physical device")
#endif
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRSIM_LIVE_DEVICE_TESTS"] == "1", "Explicit live-device test invocation required")
        let app = XCUIApplication(bundleIdentifier: "com.eric3u.airsim2")
        app.launch()
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "号卡")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertFalse(app.staticTexts["连接版本"].exists)
        XCTAssertFalse(app.buttons["云端 v1（现有版本）"].exists)
        XCTAssertFalse(app.buttons["仅本地 VoWLAN"].exists)
        XCTAssertTrue(app.buttons["v2-add-device"].exists)
        let module = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "module-")).firstMatch
        XCTAssertTrue(module.waitForExistence(timeout: 20), "Paired module directory did not load")
        for label in ["导入连接文件", "重新连接", "断开连接", "连接与音频诊断"] {
            XCTAssertFalse(app.buttons[label].exists)
        }
        for label in ["权限与后台通知", "系统通话", "关于"] {
            XCTAssertFalse(app.staticTexts[label].exists)
        }
        let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "rename-")).firstMatch
        XCTAssertTrue(rename.exists)
        rename.tap()
        XCTAssertTrue(app.navigationBars["号卡名称"].waitForExistence(timeout: 5))
        app.navigationBars["号卡名称"].buttons["取消"].tap()
        print("AIRSIM_SETTINGS_VERIFIED")
    }

    func testIncomingCallControlsOnDevice() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a paired physical device and an incoming test call")
#endif
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRSIM_LIVE_DEVICE_TESTS"] == "1", "Explicit live-device test invocation required")
        let app = XCUIApplication(bundleIdentifier: "com.eric3u.airsim2")
        app.launch()
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(5)
        let backgroundCall = ProcessInfo.processInfo.environment["AIRSIM_BACKGROUND_CALL_TEST"] == "1"
        if !backgroundCall { app.activate() }
        let surfaces = backgroundCall ? [XCUIApplication(bundleIdentifier: "com.apple.InCallService")] : [app]
        let predicate = NSPredicate(format: "label IN %@", ["接听", "接受", "Answer", "Accept"])
        print("AIRSIM_INCOMING_TEST_READY")
        if backgroundCall { sleep(20) }
        let deadline = Date().addingTimeInterval(180)
        var answer: XCUIElement?
        while Date() < deadline, answer == nil {
            for surface in surfaces {
                let candidate = surface.buttons.matching(predicate).firstMatch
                if candidate.exists && candidate.isHittable { answer = candidate; break }
            }
            if answer == nil { sleep(1) }
        }
        let incomingAnswer = try XCTUnwrap(answer, "No incoming system call")
        if backgroundCall {
            sleep(3)
            XCTAssertTrue(incomingAnswer.exists && incomingAnswer.isHittable, "System incoming call disappeared before answering")
        }
        incomingAnswer.tap()
        sleep(20)
        app.activate()
        let end = app.buttons["挂断"]
        if end.waitForExistence(timeout: 5) { end.tap() }
        sleep(3)
        XCTAssertFalse(app.buttons["接听"].exists)
    }

    func testRealV2Dial() throws {
        guard let number = ProcessInfo.processInfo.environment["AIRSIM_DIAGNOSTIC_NUMBER"], !number.isEmpty else {
            throw XCTSkip("AIRSIM_DIAGNOSTIC_NUMBER is required")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        app.tabBars.buttons["号卡"].tap()
        let module = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "module-")).firstMatch
        for _ in 0..<5 where !module.exists { app.swipeUp() }
        XCTAssertTrue(module.waitForExistence(timeout: 10))
        if !app.buttons.matching(NSPredicate(format: "identifier == %@", module.identifier)).firstMatch.isSelected {
            module.tap()
            sleep(2)
        }

        for _ in 0..<5 { app.swipeDown() }
        app.tabBars.buttons["拨号键盘"].tap()
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


final class ModuleNamingTests: UITestCase {
    override var scenario: String { "v2-ready-fixture" }

    func testRenameAppearsInSettingsAndDialModuleList() {
        openTab("号卡")
        let rename = app.buttons["rename-00112233-4455-4677-8899-aabbccddeeff"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        rename.tap()
        let editor = app.navigationBars["号卡名称"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let field = app.textFields["module-name"]
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "旅行卡")
        XCTAssertEqual(field.value as? String, "旅行卡")
        editor.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["旅行卡"].waitForExistence(timeout: 5))
        openTab("拨号键盘")
        XCTAssertTrue(app.staticTexts["旅行卡"].waitForExistence(timeout: 5))
        capture("renamed-module")
    }
}

final class A1DesignTests: UITestCase {
    override var scenario: String { "design-a1" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testDefaultModuleMenuKeepsSignalWithSelection() {
        openTab("号卡")
        let selector = app.buttons["a1-card-default-line"]
        for _ in 0..<4 where !selector.isHittable { app.swipeUp() }
        XCTAssertTrue(selector.isHittable)
        selector.tap()
        let personal = app.buttons["生活 · 9066"].firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        capture("a1-signal-default-menu")
        personal.tap()
        openTab("拨号键盘")
        let dialSelector = app.buttons["module-selector"]
        XCTAssertTrue(dialSelector.waitForExistence(timeout: 5))
        let selected = expectation(
            for: NSPredicate(format: "value == %@", "生活 · 9066，蜂窝信号，1 格，共 4 格"),
            evaluatedWith: dialSelector
        )
        wait(for: [selected], timeout: 5)
        dialSelector.tap()
        XCTAssertTrue(app.buttons["a1-dial-line-00112233-4455-4677-8899-aabbccddeeff"].exists)
        XCTAssertTrue(app.buttons["a1-dial-line-10112233-4455-4677-8899-aabbccddeeff"].exists)
        capture("a1-signal-dial-lines")
    }

    func testDesignScreenshotsAndFiveTabs() {
        openTab("通话")
        XCTAssertTrue(app.staticTexts["常用联系人"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["未接"].firstMatch)
        reveal(app.buttons["周宁的通话详情"])
        reveal(app.buttons["全部常用联系人"], up: false)
        app.swipeDown()
        capture("a1-01-calls")
        openTab("联系人")
        XCTAssertTrue(app.staticTexts["陈默"].waitForExistence(timeout: 5))
        capture("a1-02-contacts")
        app.staticTexts["陈默"].firstMatch.tap()
        XCTAssertTrue(contactBackButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["a1-contact-message"].exists)
        XCTAssertTrue(app.buttons["编辑"].exists)
        capture("a1-03-contact-detail")
        openTab("拨号键盘")
        capture("a1-04-keypad")
        openTab("号卡")
        XCTAssertTrue(app.buttons["添加设备"].waitForExistence(timeout: 5))
        capture("a1-05-lines")
        verifyMainTabStructure()
        XCTAssertTrue(mainTab("短信").exists)
    }

    func testContactSearchFavoriteAndCancelledEditors() {
        openTab("联系人")
        let search = app.textFields["搜索姓名或号码"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("陈默")
        XCTAssertTrue(app.staticTexts["陈默"].exists)
        XCTAssertFalse(app.staticTexts["林晓"].exists)
        capture("a1-contact-search")
        app.staticTexts["陈默"].firstMatch.tap()
        let removeFavorite = app.buttons["移出常用联系人"]
        reveal(removeFavorite)
        removeFavorite.tap()
        let addFavorite = app.buttons["加入常用联系人"]
        XCTAssertTrue(addFavorite.waitForExistence(timeout: 5))
        addFavorite.tap()
        XCTAssertTrue(removeFavorite.waitForExistence(timeout: 5))
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["编辑联系人"].waitForExistence(timeout: 5))
        capture("a1-contact-editor")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(contactBackButton.waitForExistence(timeout: 5))
        contactBackButton.tap()
        app.buttons["新增联系人"].tap()
        XCTAssertTrue(app.navigationBars["新增联系人"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["保存"].isEnabled)
        capture("a1-contact-create")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["新增联系人"].waitForExistence(timeout: 5))
    }

    func testCallSearchHistoryAndDetails() {
        openTab("通话")
        app.buttons["搜索通话和联系人"].tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("陈默")
        let results = app.descendants(matching: .any).matching(identifier: "a1-call-search-results").firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(results.staticTexts["陈默"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(results.staticTexts["林晓"].exists)
        capture("a1-call-search")
        let cancelSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "取消"])).firstMatch
        XCTAssertTrue(cancelSearch.waitForExistence(timeout: 5))
        cancelSearch.tap()
        let finishSearch = app.navigationBars["搜索"].buttons["完成"]
        XCTAssertTrue(finishSearch.waitForExistence(timeout: 5))
        finishSearch.tap()
        let allCalls = app.buttons["全部最近通话"]
        reveal(allCalls)
        allCalls.tap()
        XCTAssertTrue(app.navigationBars["最近通话"].waitForExistence(timeout: 5))
        capture("a1-full-call-history")
        let details = app.buttons["周宁的通话详情"]
        reveal(details)
        details.tap()
        XCTAssertTrue(app.navigationBars["通话详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["开始时间"].exists)
        reveal(app.buttons["使用原线路回拨"])
        capture("a1-call-detail")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["最近通话"].waitForExistence(timeout: 5))
    }

    func testSearchCallDetailOpensCancellableMessageComposer() {
        openTab("通话")
        app.buttons["搜索通话和联系人"].tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("陈默")
        let results = app.descendants(matching: .any).matching(identifier: "a1-call-search-results").firstMatch
        let details = results.buttons["陈默的通话详情"]
        reveal(details)
        details.tap()
        XCTAssertTrue(app.navigationBars["通话详情"].waitForExistence(timeout: 5))
        let message = app.buttons["发送短信"]
        for _ in 0..<3 where !message.isHittable { app.swipeUp() }
        XCTAssertTrue(message.isHittable)
        message.tap()
        XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["输入号码或姓名"].value as? String, "00000000001")
        XCTAssertFalse(app.buttons["message-send"].isEnabled)
        XCTAssertFalse(app.navigationBars["搜索"].exists)
        XCTAssertFalse(app.navigationBars["通话详情"].exists)
        capture("a1-search-call-message-composer")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["a1-message-compose"].waitForExistence(timeout: 5))
        openTab("通话")
        XCTAssertTrue(app.buttons["搜索通话和联系人"].waitForExistence(timeout: 5))
    }

    func testContactDetailOpensCancellableMessageComposer() {
        openTab("联系人")
        app.staticTexts["陈默"].firstMatch.tap()
        XCTAssertTrue(app.buttons["a1-contact-message"].waitForExistence(timeout: 5))
        app.buttons["a1-contact-message"].tap()
        XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["输入号码或姓名"].value as? String, "00000000001")
        XCTAssertFalse(app.buttons["message-send"].isEnabled)
        capture("a1-contact-message-composer")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["a1-message-compose"].waitForExistence(timeout: 5))
        openTab("通话")
        XCTAssertTrue(app.buttons["搜索通话和联系人"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, up: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 where !element.exists || !element.isHittable {
            if up { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

}


final class A1DialDesignTests: UITestCase {
    override var scenario: String { "design-a1" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testDialStatesAndOneCallLineSelection() {
        openTab("拨号键盘")
        let call = app.buttons["a1-dial-call"]
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertFalse(call.isEnabled)
        capture("a1-dial-empty")
        for digit in "00000000888" { app.buttons["a1-dial-key-" + String(digit)].tap() }
        XCTAssertEqual(app.staticTexts["a1-dial-number"].label, "00000000888")
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: call)
        wait(for: [ready], timeout: 10)
        capture("a1-dial-entered")
        let selector = app.buttons["module-selector"]
        XCTAssertEqual(selector.value as? String, "工作 · 4821，蜂窝信号，4 格，共 4 格")
        selector.tap()
        XCTAssertTrue(app.staticTexts["仅用于本次呼叫"].waitForExistence(timeout: 5))
        capture("a1-dial-lines")
        app.buttons["a1-dial-line-10112233-4455-4677-8899-aabbccddeeff"].tap()
        XCTAssertEqual(selector.value as? String, "生活 · 9066，蜂窝信号，1 格，共 4 格")
        openTab("联系人")
        openTab("拨号键盘")
        XCTAssertEqual(selector.value as? String, "工作 · 4821，蜂窝信号，4 格，共 4 格")
        XCTAssertEqual(app.staticTexts["a1-dial-number"].label, "00000000888")
        app.buttons["a1-dial-add-contact"].tap()
        XCTAssertTrue(app.navigationBars["新增联系人"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "00000000888")).firstMatch.exists)
        app.navigationBars.buttons["取消"].tap()
        app.buttons["a1-dial-delete"].press(forDuration: 1.8)
        let remaining = app.staticTexts["a1-dial-number"].label
        XCTAssertTrue(remaining == "尚未输入号码" || remaining.count < 10)
        for _ in 0..<11 where app.staticTexts["a1-dial-number"].label != "尚未输入号码" {
            app.buttons["a1-dial-delete"].tap()
        }
        XCTAssertEqual(app.staticTexts["a1-dial-number"].label, "尚未输入号码")
        app.buttons["a1-dial-key-0"].press(forDuration: 0.6)
        XCTAssertEqual(app.staticTexts["a1-dial-number"].label, "+")
        app.buttons["a1-dial-delete"].tap()
        XCTAssertFalse(call.isEnabled)
    }
}


final class MessageTabNavigationTests: ConversationTestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testMessageTabFollowsContactsAndKeepsConversationDraft() {
        openTab("短信")
        verifyMainTabStructure()
        XCTAssertFalse(app.buttons["a1-messages-close"].exists)
        XCTAssertTrue(app.buttons["a1-message-compose"].exists)
        capture("five-tabs-messages")
        app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"].tap()
        enterReply("标签切换保留草稿")
        if messageBackButton.exists { messageBackButton.tap() }
        openTab("拨号键盘")
        openTab("短信")
        app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"].tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, "标签切换保留草稿")
    }
}


final class A1AdaptiveDesignTests: ConversationTestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testAdaptiveScreensAndConversationSelection() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openTab("通话")
        verifyMainTabStructure()
        let usesSplitView = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "a1-wide-call-row-")).firstMatch.exists
        capture("formal-wide-calls")
        openTab("联系人")
        let contact = app.buttons["a1-contact-row-design-contact-0"]
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        contact.tap()
        XCTAssertTrue(app.buttons["a1-contact-message"].waitForExistence(timeout: 5))
        capture("formal-wide-contacts")
        openTab("短信")
        let work = app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        enterReply("宽窄窗口草稿")
        if usesSplitView {
            let title = app.navigationBars.staticTexts["短信"].firstMatch
            let search = app.textFields["a1-message-search"]
            XCTAssertLessThanOrEqual(title.frame.maxY + 8, search.frame.minY)
        }
        capture("formal-wide-messages")
        XCUIDevice.shared.orientation = .portrait
        let draft = app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "宽窄窗口草稿")
        capture("formal-portrait-messages")
        let sidebar = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@ OR label CONTAINS %@", "ToggleSidebar", "边栏", "Sidebar")).firstMatch
        XCTAssertTrue(work.isHittable || messageBackButton.isHittable || sidebar.isHittable)
        if messageBackButton.exists { messageBackButton.tap() }
        else if !work.isHittable && sidebar.exists { sidebar.tap() }
        XCTAssertTrue(work.isHittable)
        openTab("拨号键盘")
        XCTAssertTrue(app.buttons["a1-dial-key-1"].waitForExistence(timeout: 5))
        capture("formal-dial")
        openTab("号卡")
        let module = app.buttons["module-00112233-4455-4677-8899-aabbccddeeff"]
        XCTAssertTrue(module.waitForExistence(timeout: 5))
        capture("formal-cards")
        module.tap()
        let rename = app.buttons["rename-00112233-4455-4677-8899-aabbccddeeff"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        capture("formal-card-detail")
        rename.tap()
        XCTAssertTrue(app.textFields["module-name"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["取消"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["rename-00112233-4455-4677-8899-aabbccddeeff"].waitForExistence(timeout: 5))
        if usesSplitView {
            XCTAssertTrue(module.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["a1-card-back"].exists)
        }
        capture("formal-wide-cards")
        openTab("短信")
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, "宽窄窗口草稿")
        XCUIDevice.shared.orientation = .portrait
    }
}

final class A1AccessibilityDesignTests: UITestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] {
        ["-airsim.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }

    func testLargestTextContentAndFormsRemainReachable() {
        openTab("通话")
        let allFavorites = app.buttons["全部常用联系人"]
        reveal(allFavorites)
        let firstFavorite = app.staticTexts["陈默"].firstMatch
        reveal(firstFavorite)
        XCTAssertLessThanOrEqual(allFavorites.frame.maxY, firstFavorite.frame.minY)
        capture("hig-ax5-calls")
        reveal(app.buttons["全部最近通话"])
        reveal(app.buttons["周宁的通话详情"])
        openTab("联系人")
        let contact = app.buttons["a1-contact-row-design-contact-0"]
        reveal(contact)
        contact.tap()
        XCTAssertTrue(app.buttons["a1-contact-edit"].waitForExistence(timeout: 5))
        capture("hig-ax5-contact")
        XCTAssertTrue(contactBackButton.isHittable)
        contactBackButton.tap()

        openTab("短信")
        let thread = app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"]
        reveal(thread)
        capture("hig-ax5-messages")
        thread.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTab("联系人").isHittable)
        capture("hig-ax5-thread")
        messageBackButton.tap()
        app.buttons["a1-message-compose"].tap()
        let recipient = app.textFields["a1-message-recipient"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        recipient.typeText("00000000001")
        capture("hig-ax5-compose-keyboard")
        XCTAssertTrue(app.buttons["取消"].isHittable)
        app.buttons["取消"].tap()

        openTab("拨号键盘")
        let digit = app.buttons["a1-dial-key-1"]
        reveal(digit)
        XCTAssertGreaterThanOrEqual(digit.frame.height, 44)
        capture("hig-ax5-dial")
        app.swipeDown()
        let selector = app.buttons["module-selector"]
        reveal(selector, up: false)
        selector.tap()
        capture("hig-ax5-line-picker")
        XCTAssertTrue(app.buttons["取消"].isHittable)
        app.buttons["取消"].tap()

        openTab("号卡")
        let module = app.buttons["module-00112233-4455-4677-8899-aabbccddeeff"]
        reveal(module)
        module.tap()
        let rename = app.buttons["rename-00112233-4455-4677-8899-aabbccddeeff"]
        reveal(rename)
        capture("hig-ax5-card")
        rename.tap()
        XCTAssertTrue(app.textFields["module-name"].waitForExistence(timeout: 5))
        capture("hig-ax5-rename")
        app.buttons["取消"].tap()
    }

    private func reveal(_ element: XCUIElement, up: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            if up { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}

final class A1FoldContinuityTests: ConversationTestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] { ["-airsim.appearance", "dark"] }

    func testConversationRemainsSelectedAfterDisplayChange() throws {
        guard ProcessInfo.processInfo.environment["AIRSIM_FOLD_TEST"] == "1" else {
            throw XCTSkip("AIRSIM_FOLD_TEST enables the Device Hub fold interaction")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        openTab("短信")
        let work = app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        enterReply("fold-draft")
        capture("hig-duo-before-fold")
        let folded = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.descendants(matching: .any).matching(identifier: "BackButton").firstMatch)
        wait(for: [folded], timeout: 180)
        let draft = app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch
        XCTAssertEqual(draft.value as? String, "fold-draft")
        capture("hig-duo-after-fold")
        messageBackButton.tap()
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        XCTAssertEqual(draft.value as? String, "fold-draft")
    }
}

final class AppllamaContactInteractionTests: UITestCase {
    override var scenario: String { "design-a1" }

    func testContactSearchKeepsItsFrameWhenTypingAndClearing() {
        openTab("联系人")
        let search = app.textFields["搜索姓名或号码"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let emptyFrame = search.frame
        search.typeText("陈默")
        let clear = app.buttons["清除搜索"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(search.frame.minY, emptyFrame.minY, accuracy: 1)
        XCTAssertEqual(search.frame.height, emptyFrame.height, accuracy: 1)
        XCTAssertTrue(app.buttons["a1-contact-row-design-contact-0"].exists)
        XCTAssertFalse(app.buttons["a1-contact-row-design-contact-2"].exists)
        clear.tap()
        XCTAssertTrue(app.buttons["a1-contact-row-design-contact-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.frame.minY, emptyFrame.minY, accuracy: 1)
        XCTAssertEqual(search.frame.height, emptyFrame.height, accuracy: 1)
        capture("appllama-contact-search-cleared")
    }

    func testDirtyContactEditorKeepsChangesUntilExplicitDiscard() {
        openTab("联系人")
        let row = app.buttons["a1-contact-row-design-contact-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["a1-contact-edit"].tap()
        let editor = app.navigationBars["编辑联系人"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let name = app.textFields["姓名"]
        name.tap()
        name.typeText("测试")
        let editedName = name.value as? String
        XCTAssertTrue(editedName?.contains("测试") == true)
        editor.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["放弃更改"].waitForExistence(timeout: 5))
        keepEditing(in: "编辑联系人")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, editedName)
        editor.buttons["取消"].tap()
        let discard = app.buttons["放弃更改"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(app.buttons["a1-contact-edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.staticTexts["陈默"].exists)
        capture("appllama-contact-discarded")
    }
}

final class AppllamaCachedContactLoadTests: UITestCase {
    override var scenario: String { "design-a1" }
    override var presentationArguments: [String] { ["--ui-contacts-load-error"] }

    func testFailedRefreshKeepsCachedContactsAndCanRetry() {
        openTab("联系人")
        let error = app.staticTexts["无法读取通讯录，请重试"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let row = app.buttons["a1-contact-row-design-contact-0"]
        XCTAssertTrue(row.isHittable)
        capture("appllama-contacts-cached-error")
        app.buttons["a1-contacts-retry"].tap()
        let recovered = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: error)
        wait(for: [recovered], timeout: 5)
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.buttons["a1-contact-edit"].waitForExistence(timeout: 5))
    }
}

final class AppllamaEmptyContactLoadTests: UITestCase {
    override var scenario: String { "design-empty" }
    override var presentationArguments: [String] { ["--ui-contacts-load-error"] }

    func testFailedInitialLoadIsDistinctFromSuccessfulEmptyContacts() {
        openTab("联系人")
        let error = app.staticTexts["无法读取通讯录，请重试"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["还没有联系人"].exists)
        XCTAssertFalse(app.staticTexts["授权访问通讯录"].exists)
        capture("appllama-contacts-empty-error")
        app.buttons["a1-contacts-retry"].tap()
        XCTAssertTrue(app.staticTexts["还没有联系人"].waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        XCTAssertTrue(app.buttons["添加联系人"].isHittable)
    }
}

final class AppllamaCardInteractionTests: UITestCase {
    override var scenario: String { "design-messages" }

    func testRenamingKeepsEditsUntilExplicitDiscard() {
        openTab("号卡")
        let module = app.buttons["module-00112233-4455-4677-8899-aabbccddeeff"]
        XCTAssertTrue(module.waitForExistence(timeout: 5))
        module.tap()
        let rename = app.buttons["rename-00112233-4455-4677-8899-aabbccddeeff"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let editor = app.navigationBars["号卡名称"]
        let name = app.textFields["module-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let originalName = name.value as? String ?? ""
        name.typeText("测试")
        let editedName = name.value as? String
        XCTAssertTrue(editedName?.contains("测试") == true)
        editor.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["放弃更改"].waitForExistence(timeout: 5))
        keepEditing(in: "号卡名称")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, editedName)
        editor.buttons["取消"].tap()
        let discard = app.buttons["放弃更改"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists)
        rename.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, originalName)
        editor.buttons["取消"].tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        capture("appllama-card-rename-discarded")
    }

    func testPairingCodeKeyboardAndExpiredCodeFeedback() {
        openTab("号卡")
        let add = app.buttons["v2-add-device"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled)
        add.tap()
        let field = app.textFields["v2-pairing-code"]
        let lookup = app.buttons["v2-pairing-lookup"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(lookup.isEnabled)
        field.tap()
        field.typeText("1234567")
        XCTAssertFalse(lookup.isEnabled)
        field.typeText("8")
        XCTAssertTrue(lookup.isEnabled)
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let hiddenKeyboard = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hiddenKeyboard], timeout: 5)
        XCTAssertTrue(lookup.isHittable)
        lookup.tap()
        let error = app.staticTexts["连接码已过期，请在网页重新连接。"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "12345678")
        XCTAssertTrue(lookup.isEnabled)
        lookup.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        capture("appllama-pairing-expired")
        app.navigationBars["添加设备"].buttons["取消"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
    }

}

final class AppllamaAdaptiveSearchTests: UITestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testMessageSearchRemainsVisibleWhenWindowNarrows() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openTab("短信")
        let search = app.textFields["a1-message-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("顺丰")
        search.typeText("\n")
        XCTAssertTrue(app.staticTexts["顺丰速运"].waitForExistence(timeout: 5))
        capture("appllama-wide-search")
        XCUIDevice.shared.orientation = .portrait
        if messageBackButton.waitForExistence(timeout: 3) { messageBackButton.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "顺丰")
        XCTAssertTrue(app.buttons["结束搜索"].exists)
        capture("appllama-narrow-search")
        app.buttons["结束搜索"].tap()
        XCTAssertTrue(app.staticTexts["林晓"].waitForExistence(timeout: 5))
    }
}
