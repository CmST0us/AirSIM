import XCTest
@testable import AirSIM

private actor OutgoingCallServiceProbe: OutgoingCallServicing {
    private let dialError: Error?
    private var actions: [String] = []

    init(dialError: Error? = nil) {
        self.dialError = dialError
    }

    func warmAudioHost() async throws { actions.append("warm") }
    func setAudioHostEnabled(_ enabled: Bool) async throws { actions.append("enable:\(enabled)") }
    func dial(number: String) async throws {
        actions.append("dial:\(number)")
        if let dialError { throw dialError }
    }

    func recordedActions() -> [String] { actions }
}

private struct LegacyAgentSMSProbe: LegacyAgentPolling {
    let pending: Int?
    let smsStatusAvailable: Bool

    func callStatus() async throws -> CallStatus {
        CallStatus(active: nil, history: [], polling: true, eventDriven: false,
                   pollIntervalSeconds: 1, lastPollError: "", revision: nil)
    }

    func smsStatus() async throws -> SMSStatus {
        if !smsStatusAvailable { throw URLError(.badServerResponse) }
        return SMSStatus(autoCleanupME: true, count: pending, lastPollError: nil)
    }
}

private struct AgentSMSInboxProbe: AgentSMSInboxServicing {
    let name: String
    let inbox: [SMSMessage]

    func messages() async throws -> [SMSMessage] { inbox }
}

final class AirSIMTests: XCTestCase {
    @MainActor
    func testRejectIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let previous = LegacyRuntimeGate.allowed
        LegacyRuntimeGate.configure(true)
        defer { LegacyRuntimeGate.configure(previous) }
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "reject was not attempted"

        await model.reject()

        XCTAssertNotEqual(model.errorMessage, "reject was not attempted")
    }

    @MainActor
    func testHangupIsNotSilentlyDroppedWhileAnotherActionIsBusy() async {
        let previous = LegacyRuntimeGate.allowed
        LegacyRuntimeGate.configure(true)
        defer { LegacyRuntimeGate.configure(previous) }
        let model = AppModel()
        model.isBusy = true
        model.errorMessage = "hangup was not attempted"

        await model.hangup()

        XCTAssertNotEqual(model.errorMessage, "hangup was not attempted")
    }

    func testLocalCallControlBodyCarriesCallIdentity() throws {
        let targeted = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: "visible-call-7"))
        ) as? [String: String]
        XCTAssertEqual(targeted, ["call_id": "visible-call-7"])
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LocalCallControlBody(callID: nil))
        ) as? [String: String]
        XCTAssertEqual(legacy, [String: String]())
    }

    func testUnansweredPushRejectRoutesToRelayEvenWithoutPreparedMedia() {
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .cloud, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: false
        ), .cloudReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: .vowlan, cloudSessionPrepared: false,
            hasIncomingPush: true, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
        XCTAssertEqual(CallKitEndDecision.route(
            transport: nil, cloudSessionPrepared: false,
            hasIncomingPush: false, systemCallAnswered: false,
            activeIncomingRinging: true
        ), .localReject)
    }

    func testLateEndCallbackDoesNotReachBackendAfterCallAlreadyEnded() {
        XCTAssertFalse(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: false
        ))
        XCTAssertTrue(CallKitEndActionPolicy.shouldForwardToBackend(
            systemCallWasCurrent: true
        ))
    }

    func testLocalRejectKeepsObservedAgentDuringReconnect() {
        XCTAssertEqual(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: "call-on-samsung"
        ), "三星")
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "call-on-samsung", service: "三星"),
            fallback: "小米",
            targetCallID: nil
        ))
        XCTAssertNil(LocalCallControlTarget.select(
            locked: Optional<String>.none,
            observed: (callID: "old-call", service: "三星"),
            fallback: "小米",
            targetCallID: "new-call"
        ))
    }

    @MainActor
    func testInitialPermissionsWaitForMicrophoneDecisionBeforeOtherPrompts() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var events: [String] = []

        await coordinator.requestIfNeeded(
            isForeground: { true },
            microphoneIsUndetermined: { microphoneUndetermined },
            requestMicrophone: {
                events.append("microphone")
                await Task.yield()
                microphoneUndetermined = false
            },
            startDiscovery: { events.append("discovery") },
            requestNotifications: { events.append("notifications") }
        )

        XCTAssertEqual(events, ["microphone", "discovery", "notifications"])
        XCTAssertTrue(coordinator.didStartDiscovery)
    }

    @MainActor
    func testInitialPermissionsRetryWhenMicrophonePromptWasDeferred() async {
        let coordinator = InitialPermissionCoordinator()
        var microphoneUndetermined = true
        var requestCount = 0
        var notifications = 0
        var discovery = 0

        func request() async {
            await coordinator.requestIfNeeded(
                isForeground: { true },
                microphoneIsUndetermined: { microphoneUndetermined },
                requestMicrophone: { requestCount += 1 },
                startDiscovery: { discovery += 1 },
                requestNotifications: { notifications += 1 }
            )
        }

        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 0)
        XCTAssertEqual(notifications, 0)

        microphoneUndetermined = false
        await request()
        await request()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(discovery, 1)
        XCTAssertEqual(notifications, 1)
    }

    func testRelayRetryDoesNotRepeatSuccessfulAgentRegistration() {
        XCTAssertFalse(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "samsung",
            lastFingerprint: "same-token",
            lastRoute: "samsung"
        ))
    }

    func testNewAgentRouteRequiresRegistrationEvenWithSameToken() {
        XCTAssertTrue(PushRegistrationAttemptPolicy.shouldRegisterAgent(
            fingerprint: "same-token",
            route: "new-samsung",
            lastFingerprint: "same-token",
            lastRoute: "old-samsung"
        ))
    }

    func testRelayQuotaPausesOnlyRelayRegistrationUntilRetryTime() {
        let now = Date(timeIntervalSince1970: 43_200)
        let retryAfter = Date(timeIntervalSince1970: 43_500)
        XCTAssertFalse(PushRegistrationRetryPolicy.shouldAttemptRelay(now: now, retryAfter: retryAfter))
        XCTAssertTrue(PushRegistrationRetryPolicy.shouldAttemptRelay(now: retryAfter, retryAfter: retryAfter))
        XCTAssertEqual(PushRegistrationRetryPolicy.quotaRetryDate(now: now), retryAfter)
        XCTAssertEqual(
            PushRegistrationRetryPolicy.quotaRetryDate(now: Date(timeIntervalSince1970: 86_280)),
            Date(timeIntervalSince1970: 86_410)
        )
    }

    func testCloudStatusRefreshDoesNotRepeatJustBecauseTimeElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: false, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast, appIsForeground: false))
        XCTAssertTrue(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: .distantPast,
            appIsForeground: false, beforeLiveActivityCall: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-5), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-30), appIsForeground: true))
        XCTAssertFalse(AppRefreshPolicy.shouldQueryCloudStatus(
            cloudModeEnabled: true, lastAttempt: now.addingTimeInterval(-3_600),
            appIsForeground: false, beforeLiveActivityCall: true))
    }

    func testLegacyAgentPollFetchesPendingSMSWithoutEventEndpoint() async throws {
        let withMessage = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 1, smsStatusAvailable: true))
        XCTAssertTrue(withMessage.smsChanged)

        let empty = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: 0, smsStatusAvailable: true))
        XCTAssertFalse(empty.smsChanged)

        let unavailableStatus = try await LegacyAgentPoller.next(
            LegacyAgentSMSProbe(pending: nil, smsStatusAvailable: false))
        XCTAssertTrue(unavailableStatus.smsChanged)
    }

    func testPendingSMSIsFetchedEvenWhenRevisionWasAlreadyObserved() {
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 7, observedSMSRevision: 7))
        XCTAssertTrue(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 1, eventRevision: 0, observedSMSRevision: 7))
        XCTAssertFalse(AgentEventPollingPolicy.shouldFetchSMS(
            pending: 0, eventRevision: 8, observedSMSRevision: 7))
    }

    func testSMSFetchUsesReportingAgentAfterDiscoverySwitchesPhones() async throws {
        let samsung = AgentSMSInboxProbe(name: "三星", inbox: [SMSMessage(
            sender: "10086", content: "来自三星", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "samsung-sms-1", direction: .incoming
        )])
        let xiaomi = AgentSMSInboxProbe(name: "小米", inbox: [])

        let fetched = try await AgentSMSInboxFetch.fetch(
            reportingAgent: samsung, discoveredAgent: xiaomi
        )

        XCTAssertEqual(fetched.messages.map(\.content), ["来自三星"])
        XCTAssertEqual(fetched.agent.name, "三星")
    }

    func testPCMReconnectCreatesFreshHandshakeForEveryAttempt() throws {
        var generated = 0
        let handshakes = PCMHandshakeSequence {
            generated += 1
            return Data("handshake-\(generated)".utf8)
        }

        XCTAssertEqual(try handshakes.next(), Data("handshake-1".utf8))
        XCTAssertEqual(try handshakes.next(), Data("handshake-2".utf8))
        XCTAssertEqual(generated, 2)
    }

    func testIncomingSMSPushAcceptsAgentNanosecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-nano-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12.123456789Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-nano-1")
        XCTAssertEqual(pushed.message.content, "短信正文")
        XCTAssertEqual(pushed.timestamp.timeIntervalSince1970, 1_791_448_212.123456789, accuracy: 0.001)
    }

    func testIncomingSMSPushAcceptsWholeSecondTimestamp() throws {
        let pushed = try IncomingRemoteSMS(userInfo: [
            "event": "incoming_sms",
            "delivery_id": "sms-second-1",
            "sender": "10086",
            "content": "短信正文",
            "timestamp": "2026-10-08T08:30:12Z",
        ])
        XCTAssertEqual(pushed.deliveryID, "sms-second-1")
    }

    func testColdLaunchSMSNavigationRequestIsConsumedOnce() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        IncomingSMSPresentationRequest.markPending(sender: "10086", defaults: defaults)
        XCTAssertEqual(IncomingSMSPresentationRequest.consume(defaults: defaults), "10086")
        XCTAssertNil(IncomingSMSPresentationRequest.consume(defaults: defaults))
    }

    func testSMSDeliveryIDDeduplicatesPushAndAgentCopies() {
        let pushed = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        let synchronized = SMSMessage(
            sender: "10086", content: "短信正文", code: nil,
            timestamp: Date(timeIntervalSince1970: 1_791_448_212.123456789),
            deliveryID: "sms-stable-1", direction: .incoming
        )
        XCTAssertEqual(pushed.id, synchronized.id)
    }

    func testCloudUplinkNeverBurstsAfterBlockedSend() {
        var queue = CloudPCMUplinkSendQueue()
        for index in 0..<20 {
            queue.enqueue(Data(repeating: UInt8(index), count: 320), at: Double(index) * 0.02)
        }
        XCTAssertEqual(queue.next(at: 0.4)?.first, 0)
        XCTAssertNil(queue.next(at: 0.6))
        queue.complete()
        XCTAssertEqual(queue.next(at: 0.61)?.first, 1)
        queue.complete()
        XCTAssertNil(queue.next(at: 0.611))
        XCTAssertEqual(queue.next(at: 0.631)?.first, 2)
    }

    func testCloudUplinkDropsStaleBacklog() {
        var queue = CloudPCMUplinkSendQueue()
        for _ in 0..<200 { queue.enqueue(Data(repeating: 1, count: 320), at: 0) }
        XCTAssertEqual(queue.pendingPackets, 50)
        XCTAssertNil(queue.next(at: 2))
        XCTAssertEqual(queue.pendingPackets, 0)
        XCTAssertEqual(queue.droppedPackets, 200)
    }

    func testCloudDownlinkPrimesAndReordersBurst() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in [0, 2, 1, 3, 4, 5, 6, 7, 8, 9] {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: UInt8(sequence), count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.dequeue(maxFrames: 10).map(\.sequence), Array(0..<10).map(UInt32.init))
        buffer.notePlaybackUnderrun()
        XCTAssertFalse(buffer.isPrimed)
    }

    func testCloudDownlinkLimitsLateBurstLatency() {
        var buffer = CloudPCMAdaptiveJitterBuffer()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        for sequence in 0..<75 {
            buffer.enqueue(sequence: UInt32(sequence),
                           pcm: Data(repeating: 1, count: 320),
                           arrivedAt: epoch.addingTimeInterval(Double(sequence) * 0.02))
        }
        XCTAssertEqual(buffer.bufferedFrameCount, 50)
        XCTAssertEqual(buffer.droppedFrameCount, 25)
        XCTAssertEqual(buffer.dequeue(maxFrames: 50).map(\.sequence), Array(25..<75).map(UInt32.init))
    }

    func testCloudPlaybackReserveRefillsOnRenderedFrames() {
        var window = CloudPCMPlaybackWindow()
        for _ in 0..<12 { window.schedulePacket() }
        XCTAssertEqual(window.availablePackets, 0)
        window.didRenderPacket()
        XCTAssertEqual(window.availablePackets, 1)
        window.schedulePacket()
        XCTAssertEqual(window.scheduledPackets, 12)
    }

    func testOnlySamsungPrivateEndpointsAreAccepted() throws {
        let endpoint = try VoWLANEndpoint(host: "192.168.43.1", controlPort: 7575, pcmPort: 7576)
        XCTAssertEqual(endpoint.controlBaseURL.absoluteString, "http://192.168.43.1:7575/")
        XCTAssertThrowsError(try VoWLANEndpoint(host: "8.8.8.8", controlPort: 7575, pcmPort: 7576))
        XCTAssertFalse(AirSIMRoutePolicy.permits(.moduleLocal))
    }

    func testLegacyModuleRequestIsRejectedBeforeNetworkAccess() async {
        do {
            _ = try await AirSIMAPI().health()
            XCTFail("旧模块路线不应发出请求")
        } catch APIError.disabledLegacyRoute {
            // Expected: the old module route is blocked at the transport boundary.
        } catch {
            XCTFail("预期得到旧路线已停用错误，实际为 \(error)")
        }
    }

    func testLegacyModulePCMHandshakeIsRejected() {
        XCTAssertThrowsError(try PCMRoute.moduleLocal.handshake()) { error in
            guard case APIError.disabledLegacyRoute = error else {
                return XCTFail("预期旧模块 PCM 被拦截，实际为 \(error)")
            }
        }
    }

    func testDialTransportPrefersVoWLANOverCloud() {
        let route = DialPadTransportPresentation.make(
            vowlanOnline: true,
            moduleLocalReachable: false,
            cloudOnline: true
        )
        XCTAssertEqual(route?.transport, .vowlan)
    }

    func testCloudStatusDecodesMultipleAndroidAgentsAndCurrentRoute() throws {
        let data = Data(#"""
        {
            "cloud_online": true,
            "active_agent_id": "samsung-standalone",
            "agents": [
                {
                    "agent_id": "xiaomi-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Xiaomi 15",
                    "phone_number": "+8613800000001",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": false
                },
                {
                    "agent_id": "samsung-standalone",
                    "agent_kind": "standalone",
                    "device_name": "Samsung Flip7",
                    "phone_number": "+8613800000002",
                    "agent_version": "standalone-0.1.0",
                    "cloud_online": true
                }
            ]
        }
        """#.utf8)
        let status = try JSONDecoder().decode(CloudAgentStatus.self, from: data)
        XCTAssertEqual(status.activeAgentID, "samsung-standalone")
        XCTAssertEqual(status.agents.count, 2)
        XCTAssertEqual(status.agents.last?.deviceName, "Samsung Flip7")
        XCTAssertEqual(status.agents.last?.phoneNumber, "+8613800000002")
    }

    func testCloudModeCanBeDisabledWithoutDisablingLocalCalls() {
        let suite = "airsim-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudModePreference.key)
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
        XCTAssertTrue(OutgoingCommandAvailability.isAvailable(
            localControlReachable: true,
            cloudModeEnabled: false,
            cloudHeartbeatFresh: false
        ))
    }

    @MainActor
    func testVoWLANTransportFailureFallsBackOnceToCloud() async throws {
        let local = OutgoingCallServiceProbe(dialError: URLError(.timedOut))
        var cloudAttempts = 0

        let result = try await OutgoingCallRouteCoordinator.start(
            number: "10086",
            vowlanService: local,
            cloudModeEnabled: true
        ) {
            cloudAttempts += 1
            return "cloud-call"
        }

        XCTAssertEqual(result, .cloud("cloud-call"))
        XCTAssertEqual(cloudAttempts, 1)
        let localActions = await local.recordedActions()
        XCTAssertEqual(localActions, ["warm", "dial:10086"])
    }

    @MainActor
    func testVoWLANAgentRejectionDoesNotReplayDialThroughCloud() async {
        let local = OutgoingCallServiceProbe(
            dialError: APIError.http(502, "Android Telecom 拒绝拨号")
        )
        var cloudAttempts = 0

        do {
            _ = try await OutgoingCallRouteCoordinator.start(
                number: "10086",
                vowlanService: local,
                cloudModeEnabled: true
            ) {
                cloudAttempts += 1
                return "cloud-call"
            }
            XCTFail("Agent 已明确拒绝时不得通过云端重放非幂等拨号")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("预期保留 Agent HTTP 错误，实际为 \(error)")
        }

        XCTAssertEqual(cloudAttempts, 0)
    }

    func testVoWLANDialWaitsPastSamsungTelecomAcknowledgementWindow() {
        XCTAssertGreaterThan(AirSIMAPI.voWLANDialTimeout, 12)
    }

    func testMaintainerBundleUsesDedicatedRelayFallback() {
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: nil,
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            ""
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "com.eric3u.airsim"
            ),
            "https://airsim-push.remotepilot.site"
        )
        XCTAssertEqual(
            RelayConfiguration.effectiveURL(
                stored: "https://push.remotepilot.site/",
                buildSetting: "",
                bundleID: "org.example.airsim"
            ),
            "https://push.remotepilot.site/"
        )
    }

    func testRelayHealthRequiresAirSIMServiceIdentity() {
        let airSIM = Data(#"{"ok":true,"service":"airsim-push-relay","version":"0.2.1"}"#.utf8)
        let djonehub = Data(#"{"ok":true,"service":"djonehub-push-relay","version":"1.0.0"}"#.utf8)
        XCTAssertTrue(RelayHealthValidation.accepts(statusCode: 200, data: airSIM))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 200, data: djonehub))
        XCTAssertFalse(RelayHealthValidation.accepts(statusCode: 503, data: airSIM))
    }

    func testRelayQuotaResponseExplainsRegistrationFailure() {
        let response = Data("error code: 1027".utf8)
        let error = CloudAgentStatusError.relayFailure(statusCode: 429, data: response)
        guard case .requestLimitExceeded = error else {
            return XCTFail("Cloudflare 1027 must not be reported as an invalid Relay response")
        }
        XCTAssertTrue(error.localizedDescription.contains("额度"))
    }

    func testCurrentModePrefersVoWLANAndReportsCloudFailure() {
        XCTAssertEqual(
            ConnectionModePresentation.make(
                vowlanOnline: true,
                cloudModeEnabled: true,
                cloudOnline: true
            ).mode,
            .vowlan
        )
        let cloud = ConnectionModePresentation.make(
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: true
        )
        XCTAssertEqual(cloud.mode, .cloud)
        XCTAssertEqual(cloud.status, "已连接")

        let unreachable = ConnectionModePresentation.make(
            vowlanOnline: false,
            cloudModeEnabled: true,
            cloudOnline: false
        )
        XCTAssertEqual(unreachable.mode, .cloud)
        XCTAssertEqual(unreachable.status, "不可达")
    }

    func testCloudSelfTestReportOnlyPassesWhenEveryStagePasses() {
        var report = CloudSelfTestReport.initial
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.steps.map(\.id), CloudSelfTestStepID.allCases)

        for id in CloudSelfTestStepID.allCases {
            report.update(id, state: .passed, detail: "通过")
        }
        report.completedAt = Date()
        XCTAssertTrue(report.allPassed)

        report.update(.agentHeartbeat, state: .failed, detail: "无心跳")
        XCTAssertFalse(report.allPassed)
    }

    func testLiveActivityIncludesCurrentAndroidAgentIdentity() {
        let agent = AndroidAgentPresentation(
            id: "samsung-1",
            deviceName: "samsung SM-F766U",
            phoneNumber: "+8615502030017",
            agentKind: "standalone",
            cloudOnline: true,
            vowlanOnline: true,
            isCurrent: true
        )
        let state = LiveActivityStateBuilder.make(
            call: nil,
            callerName: nil,
            moduleOnline: true,
            transport: .vowlan,
            radio: nil,
            agent: LiveActivityAgentSnapshot(agent: agent, pairedAgentCount: 2),
            idleStartedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(state.agentDeviceName, "samsung SM-F766U")
        XCTAssertEqual(state.agentPhoneNumber, "+8615502030017")
        XCTAssertEqual(state.agentKind, "standalone")
        XCTAssertEqual(state.pairedAgentCount, 2)
        XCTAssertEqual(state.vowlanOnline, true)
        XCTAssertEqual(state.cloudOnline, true)
    }

    func testHiddenLiveActivityDoesNotRegisterPushToStartToken() {
        let suiteName = "AirSIMTests.live-activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            "abc123"
        )
        defaults.set(false, forKey: LiveActivityVisibilityPreference.key)
        XCTAssertEqual(
            LiveActivityVisibilityPreference.registrationToken("abc123", defaults: defaults),
            ""
        )
    }

    func testLocalModeLiveActivityDoesNotRequestRemotePushUpdates() {
        XCTAssertNil(LiveActivityCreationPolicy.pushType(localModeEnabled: true))
        XCTAssertNotNil(LiveActivityCreationPolicy.pushType(localModeEnabled: false))
    }

    func testVoWLANRecoveryRetriesAfterTemporaryVPNRouteLoss() {
        var recovery = VoWLANRecoveryGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = VoWLANAvailability.unavailable("VPN 路由切换")

        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start))
        XCTAssertFalse(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(3)))
        XCTAssertTrue(recovery.shouldAttempt(for: unavailable, at: start.addingTimeInterval(10)))
        XCTAssertFalse(recovery.shouldAttempt(for: .unpaired, at: start.addingTimeInterval(20)))
    }

    func testIslandCallActionsReserveOnlyRightSideButtonWidth() {
        typealias Phase = AirSIMCallActivityAttributes.ContentState.Phase
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.incoming), 96)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.active), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.held), 44)
        XCTAssertEqual(IslandActionLayout.reservedWidth(for: Phase.standby), 0)
    }

    func testLiveActivityStateDecodesLegacyPayloadWithoutAgentFields() throws {
        let state = AirSIMCallActivityAttributes.ContentState(
            callID: "",
            number: "",
            displayName: "等待模块来电",
            phase: .standby,
            startedAt: Date(timeIntervalSince1970: 1),
            transport: .vowlan
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AirSIMCallActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertNil(decoded.agentDeviceName)
        XCTAssertNil(decoded.agentPhoneNumber)
        XCTAssertNil(decoded.pairedAgentCount)
    }

    func testLocalModeForcesEffectiveCloudModeOff() {
        let suiteName = "AirSIMTests.local-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: LocalModePreference.key)
        defaults.set(true, forKey: CloudModePreference.key)

        XCTAssertTrue(LocalModePreference.isEnabled(defaults: defaults))
        XCTAssertFalse(CloudModePreference.isEnabled(defaults: defaults))
    }

    func testLocalPairingPayloadOmitsRelayAndPushCredentials() throws {
        let registration = AgentPushRegistration.local(vowlanSecret: "local-vowlan-secret")
        let data = try JSONEncoder().encode(registration)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["local_mode"] as? Bool, true)
        XCTAssertEqual(payload["cloud_enabled"] as? Bool, false)
        XCTAssertEqual(payload["vowlan_secret"] as? String, "local-vowlan-secret")
        XCTAssertNil(payload["relay_url"])
        XCTAssertNil(payload["device_id"])
        XCTAssertNil(payload["device_secret"])
        XCTAssertNil(payload["voip_token"])
        XCTAssertNil(payload["alert_token"])
    }
}
