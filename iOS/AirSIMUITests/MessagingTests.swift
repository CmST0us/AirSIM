import XCTest

final class MessagingTests: UITestCase {
    func testEmptyMessageCannotBeSentAndComposerCanBeCancelled() {
        openTab("短信")
        let recovery = app.buttons["连接设置"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        XCTAssertTrue(recovery.isHittable)
        capture("v2-unconfigured-message-recovery")
        recovery.tap()
        XCTAssertTrue(app.tabBars.buttons["设置"].isSelected)
        let legacy = app.buttons["其他方式"]
        XCTAssertTrue(legacy.waitForExistence(timeout: 5))
        legacy.tap()
        XCTAssertTrue(app.buttons["导入旧版连接文件"].waitForExistence(timeout: 5))
        openTab("短信")
        let compose = app.buttons["新信息"]
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        guard compose.exists else { return }
        compose.tap()
        let send = app.navigationBars.buttons["发送"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
        capture("v2-empty-composer")
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertFalse(send.exists)
    }
}

class ConversationTestCase: UITestCase {
    func openConversation(_ text: String) {
        openTab("短信")
        let message = app.staticTexts[text].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        guard message.exists else { return }
        message.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.waitForExistence(timeout: 5))
    }

    func enterReply(_ text: String) {
        let reply = app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch
        reply.tap()
        reply.typeText(text)
    }
}

final class ModuleIsolationTests: ConversationTestCase {
    override var scenario: String { "v2-ready-fixture" }

    func testModuleSwitchSeparatesMessagesRecentsAndReplyDraft() {
        openConversation("QA甲消息")
        enterReply("QA甲未发送草稿")
        app.navigationBars.buttons.firstMatch.tap()
        openTab("设置")
        let second = app.buttons["module-10112233-4455-4677-8899-aabbccddeeff"]
        for _ in 0..<5 where !second.isHittable { app.swipeUp() }
        XCTAssertTrue(second.isHittable)
        second.tap()
        openConversation("QA乙消息")
        XCTAssertFalse(app.staticTexts["QA甲消息"].exists)
        XCTAssertNotEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, "QA甲未发送草稿")
        capture("module-b-conversation")
        openTab("最近")
        XCTAssertTrue(app.staticTexts["QA乙通话"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["QA甲通话"].exists)
        capture("module-b-recents")
    }

    func testContactMessageActionOpensOriginalComposer() {
        openTab("联系人")
        let contact = app.staticTexts["QA虚构联系人"].firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        contact.tap()
        for attempt in 1...2 {
            app.buttons["发短信"].tap()
            XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["输入号码或姓名"].value as? String, "00000000001")
            XCTAssertFalse(app.navigationBars.buttons["发送"].isEnabled)
            capture("contact-message-composer-\(attempt)")
            app.navigationBars.buttons["取消"].tap()
            XCTAssertTrue(app.buttons["新信息"].waitForExistence(timeout: 5))
            if attempt == 1 { openTab("联系人") }
        }
    }
}

final class SendFailureTests: ConversationTestCase {
    override var scenario: String { "v2-send-failure" }

    func testRejectedReplyPreservesText() {
        openConversation("QA甲消息")
        let draft = "QA发送失败应保留正文"
        enterReply(draft)
        app.buttons["message-send"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        capture("reply-rejected")
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, draft)
        capture("reply-preserved")
    }
}

final class UnknownCommandTests: ConversationTestCase {
    override var scenario: String { "v2-command-unknown" }

    func testUnknownCommandBlocksSendingAndVersionSwitchButAllowsRecoveryQuery() {
        openConversation("QA甲消息")
        XCTAssertFalse(app.alerts["错误"].exists)
        enterReply("QA未知结果不重发")
        XCTAssertFalse(app.buttons["message-send"].isEnabled)
        XCTAssertFalse(app.alerts["错误"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        openTab("设置")
        let local = app.buttons["仅本地 VoWLAN"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        XCTAssertTrue(app.staticTexts["仍有通话、媒体或未确认操作，请先结束通话并确认操作结果。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法切换"].exists)
        capture("unknown-blocks-switch")
        let recover = app.buttons["command-recover"]
        for _ in 0..<6 where !recover.isHittable { app.swipeUp() }
        XCTAssertTrue(recover.isHittable)
        XCTAssertTrue(recover.isEnabled)
        capture("unknown-recovery")
    }
}
