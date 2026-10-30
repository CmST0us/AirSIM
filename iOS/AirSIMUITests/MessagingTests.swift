import XCTest

final class MessagingTests: UITestCase {
    func testEmptyMessageCannotBeSentAndComposerCanBeCancelled() {
        openTab("短信")
        let recovery = app.buttons["连接设置"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        XCTAssertTrue(recovery.isHittable)
        capture("v2-unconfigured-message-recovery")
        recovery.tap()
        XCTAssertTrue(mainTab("号卡").isSelected)
        XCTAssertTrue(app.buttons["添加设备"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["导入连接文件"].exists)
        openTab("短信")
        let compose = app.buttons["新信息"]
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        guard compose.exists else { return }
        compose.tap()
        let send = app.buttons["message-send"]
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

    func testModuleSwitchSeparatesMessagesAndDraftWhileKeepingAccountCalls() {
        openConversation("QA甲消息")
        enterReply("QA甲未发送草稿")
        messageBackButton.tap()
        openTab("号卡")
        let second = app.buttons["module-10112233-4455-4677-8899-aabbccddeeff"]
        for _ in 0..<5 where !second.isHittable { app.swipeUp() }
        XCTAssertTrue(second.isHittable)
        second.tap()
        openConversation("QA乙消息")
        XCTAssertFalse(app.staticTexts["QA甲消息"].exists)
        XCTAssertNotEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, "QA甲未发送草稿")
        capture("module-b-conversation")
        openTab("通话")
        XCTAssertTrue(app.staticTexts["QA乙通话"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["QA甲通话"].exists)
        capture("account-call-history")
    }

    func testContactMessageActionOpensOriginalComposer() {
        openTab("联系人")
        let contact = app.staticTexts["QA虚构联系人"].firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        contact.tap()
        for attempt in 1...2 {
            app.buttons["a1-contact-message"].tap()
            XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["输入号码或姓名"].value as? String, "00000000001")
            XCTAssertFalse(app.buttons["message-send"].isEnabled)
            capture("contact-message-composer-\(attempt)")
            app.navigationBars.buttons["取消"].tap()
            XCTAssertTrue(app.buttons["新信息"].waitForExistence(timeout: 5))
            if attempt == 1 {
                openTab("联系人")
                contact.tap()
            }
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
        XCTAssertTrue(app.staticTexts["未发送，草稿已保留"].waitForExistence(timeout: 10))
        capture("reply-rejected")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch.value as? String, draft)
        capture("reply-preserved")
    }
}

final class UnknownCommandTests: ConversationTestCase {
    override var scenario: String { "v2-command-unknown" }

    func testUnknownCommandBlocksSendingAndPairingUntilAutomaticRecovery() {
        openConversation("QA甲消息")
        XCTAssertFalse(app.alerts["错误"].exists)
        enterReply("QA未知结果不重发")
        XCTAssertFalse(app.buttons["message-send"].isEnabled)
        XCTAssertFalse(app.alerts["错误"].exists)
        messageBackButton.tap()
        openTab("号卡")
        XCTAssertFalse(app.buttons["添加设备"].isEnabled)
        XCTAssertFalse(app.buttons["command-recover"].exists)
        capture("unknown-command-awaits-automatic-confirmation")
    }
}


class A1MessagingDesignTests: ConversationTestCase {
    override var scenario: String { "design-messages" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }
    let work = "00112233-4455-4677-8899-aabbccddeeff"
    let personal = "10112233-4455-4677-8899-aabbccddeeff"

    func testMessageListThreadSearchAndOriginalLineDraft() {
        openTab("短信")
        let workThread = app.buttons["sms-thread-\(work)-00000000001"]
        let personalThread = app.buttons["sms-thread-\(personal)-00000000001"]
        XCTAssertTrue(workThread.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["顺丰速运"].exists)
        capture("a1-sms-list")
        app.buttons["sms-filter-" + work].tap()
        XCTAssertTrue(workThread.exists)
        XCTAssertFalse(app.buttons["sms-thread-\(personal)-00000000003"].exists)
        workThread.tap()
        XCTAssertTrue(app.staticTexts["方案已发你邮箱，方便时看一下。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["发送自 工作 · 4821"].firstMatch.exists)
        capture("a1-sms-thread")
        enterReply("只保留在工作号卡的草稿")
        messageBackButton.tap()
        app.buttons["sms-filter-" + personal].tap()
        for _ in 0..<3 where !personalThread.isHittable { app.swipeUp() }
        XCTAssertTrue(personalThread.isHittable)
        personalThread.tap()
        let reply = app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch
        XCTAssertNotEqual(reply.value as? String, "只保留在工作号卡的草稿")
        XCTAssertTrue(app.staticTexts["发送自 生活 · 9066"].firstMatch.exists)
        messageBackButton.tap()
        app.buttons["sms-filter-" + work].tap()
        workThread.tap()
        XCTAssertEqual(reply.value as? String, "只保留在工作号卡的草稿")
        messageBackButton.tap()
        app.buttons["sms-filter-all"].tap()
        app.buttons["搜索短信"].tap()
        let search = app.textFields["a1-message-search"]
        search.tap()
        search.typeText("顺丰")
        XCTAssertTrue(app.staticTexts["顺丰速运"].exists)
        XCTAssertFalse(workThread.exists)
        capture("a1-sms-search")
    }

    func testComposerCanSelectContactAndCancelWithoutSending() {
        openTab("短信")
        app.buttons["a1-message-compose"].tap()
        XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["message-send"].isEnabled)
        app.buttons["从通讯录选择"].tap()
        XCTAssertTrue(app.navigationBars["选择联系人"].waitForExistence(timeout: 5))
        let recipient = app.buttons["a1-sms-recipient-00000000003"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        XCTAssertTrue(app.navigationBars["新信息"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["输入号码或姓名"].value as? String, "00000000003")
        capture("a1-sms-compose")
        enterReply("工作号卡的新信息草稿")
        app.buttons["sms-compose-line-picker"].tap()
        app.buttons["sms-compose-line-" + personal].tap()
        let reply = app.descendants(matching: .any).matching(identifier: "message-reply").firstMatch
        XCTAssertNotEqual(reply.value as? String, "工作号卡的新信息草稿")
        app.buttons["sms-compose-line-picker"].tap()
        app.buttons["sms-compose-line-" + work].tap()
        XCTAssertEqual(reply.value as? String, "工作号卡的新信息草稿")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["a1-message-compose"].waitForExistence(timeout: 5))
    }
}

final class A1SMSFailureDesignTests: ConversationTestCase {
    override var scenario: String { "design-messages-failure" }
    override var presentationArguments: [String] { ["-airsim.appearance", "light"] }

    func testFailedMessageOffersOriginalLineRetry() {
        openTab("短信")
        app.buttons["sms-thread-00112233-4455-4677-8899-aabbccddeeff-00000000001"].tap()
        let retry = app.buttons["a1-message-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "使用工作 · 4821重试")
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(app.staticTexts["未发送"].exists)
        capture("a1-sms-failure")
    }
}
