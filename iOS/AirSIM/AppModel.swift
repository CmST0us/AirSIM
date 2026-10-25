import Foundation
import UIKit
import Combine

enum AppRefreshPolicy {
    static func shouldRefreshSupplementalState(appIsActive: Bool) -> Bool { appIsActive }

    static func shouldQueryCloudStatus(
        cloudModeEnabled: Bool,
        lastAttempt: Date,
        appIsForeground: Bool,
        beforeLiveActivityCall: Bool = false
    ) -> Bool {
        guard cloudModeEnabled, appIsForeground || beforeLiveActivityCall else { return false }
        // Foreground entry explicitly re-arms this sentinel. Elapsed time alone never polls Relay.
        return lastAttempt == .distantPast
    }
}

/// Serializes first-launch permission prompts so the microphone request cannot be
/// displaced by notification or local-network authorization.
@MainActor
final class InitialPermissionCoordinator {
    private(set) var didStartDiscovery = false
    private var didRequestNotifications = false

    func requestIfNeeded(
        isForeground: () -> Bool,
        microphoneIsUndetermined: () -> Bool,
        requestMicrophone: () async -> Void,
        startDiscovery: () -> Void,
        requestNotifications: () -> Void
    ) async {
        guard isForeground() else { return }
        if microphoneIsUndetermined() { await requestMicrophone() }
        // If iOS deferred the prompt while the app was inactive, the next foreground
        // transition retries it instead of recording a request that never happened.
        guard isForeground(), !microphoneIsUndetermined() else { return }
        if !didStartDiscovery {
            didStartDiscovery = true
            startDiscovery()
        }
        if !didRequestNotifications {
            didRequestNotifications = true
            requestNotifications()
        }
    }
}

enum CallPresentationSurface: Equatable, Sendable {
    case system
    case app
}

enum CallPresentationPolicy {
    static func inAppCall(
        surface: CallPresentationSurface?,
        local: CallRecord?,
        remote: CallRecord?,
        pending: CallRecord? = nil
    ) -> CallRecord? {
        guard surface == .app else { return nil }
        return local ?? remote ?? pending
    }

    static func shouldPresentWhenAppBecomesActive(
        managesSystemCall: Bool,
        hasLocalCall: Bool,
        hasRemoteCall: Bool
    ) -> Bool {
        managesSystemCall || hasLocalCall || hasRemoteCall
    }
}

enum CallAnswerConfirmationPolicy {
    static func shouldMarkActiveImmediately(transport: CallTransport?) -> Bool {
        transport == .moduleLocal || transport == .vowlan
    }
}

enum CallKitEndDecision {
    enum Route: Equatable {
        case cloudReject
        case cloudEnd
        case localReject
        case localHangup
    }

    static func route(
        transport: CallTransport?,
        cloudSessionPrepared: Bool,
        hasIncomingPush: Bool,
        systemCallAnswered: Bool,
        activeIncomingRinging: Bool
    ) -> Route {
        if hasIncomingPush, !systemCallAnswered,
           transport != .vowlan, transport != .moduleLocal {
            return .cloudReject
        }
        if transport == .cloud || cloudSessionPrepared { return .cloudEnd }
        return activeIncomingRinging || (hasIncomingPush && !systemCallAnswered)
            ? .localReject : .localHangup
    }
}

enum LocalCallControlTarget {
    static func select<Service>(
        locked: Service?,
        observed: (callID: String, service: Service)?,
        fallback: Service?,
        targetCallID: String?
    ) -> Service? {
        if let locked { return locked }
        guard let targetCallID, !targetCallID.isEmpty else { return nil }
        if let observed {
            return observed.callID == targetCallID ? observed.service : nil
        }
        return fallback
    }
}

enum CallAnswerCompletionCoordinator {
    @MainActor
    static func complete(
        transport: CallTransport?,
        confirmActive: () -> Void,
        startAudio: () async -> Void
    ) async {
        guard CallAnswerConfirmationPolicy.shouldMarkActiveImmediately(
            transport: transport
        ) else { return }
        confirmActive()
        await startAudio()
    }
}

enum LocalControlReachability {
    static func moduleLocal(
        isOnline: Bool,
        isReconnecting: Bool,
        lastSuccessfulRoute: LocalAgentRoute?
    ) -> Bool {
        guard isOnline, !isReconnecting, let lastSuccessfulRoute else { return false }
        if case .moduleLocal = lastSuccessfulRoute { return true }
        return false
    }
}

enum AgentEventPollingPolicy {
    static func timeout(hasActiveCall: Bool) -> TimeInterval {
        hasActiveCall ? 3 : 15
    }

    static func shouldFetchSMS(pending: Int, eventRevision: UInt64, observedSMSRevision: UInt64) -> Bool {
        // An earlier fetch or local save may have failed after this revision was observed.
        // The Agent's unacknowledged queue is authoritative, including after a restart.
        pending > 0
    }
}

protocol AgentSMSInboxServicing: Sendable {
    func messages() async throws -> [SMSMessage]
}

extension AirSIMAPI: AgentSMSInboxServicing {}

enum AgentSMSInboxFetch {
    static func fetch<Service: AgentSMSInboxServicing>(
        reportingAgent: Service?, discoveredAgent: Service
    ) async throws -> (agent: Service, messages: [SMSMessage]) {
        let agent = reportingAgent ?? discoveredAgent
        return (agent, try await agent.messages())
    }
}

protocol LegacyAgentPolling: Sendable {
    func callStatus() async throws -> CallStatus
    func smsStatus() async throws -> SMSStatus
}

extension AirSIMAPI: LegacyAgentPolling {}

struct LegacyAgentPollResult: Sendable {
    let call: CallStatus
    let smsChanged: Bool
}

enum LegacyAgentPoller {
    static func next(_ api: some LegacyAgentPolling) async throws -> LegacyAgentPollResult {
        let call = try await api.callStatus()
        let sms = try? await api.smsStatus()
        // Older Agents may not expose /api/sms/status. In that case, fetch the
        // inbox directly instead of silently missing messages.
        return LegacyAgentPollResult(call: call, smsChanged: sms.map { ($0.count ?? 0) > 0 } ?? true)
    }
}

enum AgentEventCursor {
    /// 不可能由正常计数器产生，用于首次连接时要求 Agent 立即返回当前快照。
    static let initial = UInt64.max

    static func advanced(from _: UInt64, to incoming: UInt64) -> UInt64 {
        // Agent 重启后 revision 会回到 0，不能使用 max，否则会持续立即返回形成空转。
        incoming
    }
}

enum ModuleConnectivityPolicy {
    static let offlineFailureThreshold = 3
    static let callTransitionGraceInterval: TimeInterval = 8

    static func shouldConfirmOffline(
        consecutiveFailures: Int,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        consecutiveFailures >= offlineFailureThreshold && now >= protectedUntil
    }

    static func shouldMarkOffline(
        consecutiveFailures: Int,
        healthRequestSucceeded: Bool,
        now: Date,
        protectedUntil: Date
    ) -> Bool {
        shouldConfirmOffline(
            consecutiveFailures: consecutiveFailures,
            now: now,
            protectedUntil: protectedUntil
        ) && !healthRequestSucceeded
    }
}

/// 移动端 App 的主状态中心：前台轮询模块代理并驱动五个主要页面。
@MainActor
final class AppModel: ObservableObject {
    @Published var activeCall: CallRecord?
    @Published var callHistory: [CallRecord] = []
    @Published var messages: [SMSMessage] = []
    @Published var numberInput = ""
    @Published var isOnline = false
    @Published private(set) var isReconnecting = false
    @Published var connectionMessage: String?
    @Published var isBusy = false
    @Published var isMuted = false
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published private(set) var modemStatus: ModemStatus?
    @Published private(set) var agentVersion: String?
    @Published private(set) var connectionSummary: ModuleConnectionSummary = .offline
    @Published private(set) var cloudAgentStatus: CloudAgentStatus?
    @Published private(set) var cloudAgentDirectory: CloudAgentStatus?
    @Published private(set) var remoteCall: CallRecord?
    @Published private(set) var pendingOutgoingCall: CallRecord?
    @Published private(set) var callPresentationSurface: CallPresentationSurface?
    @Published private(set) var cloudCallAudioState: CloudCallAudioState = .idle
    @Published private(set) var callLifecycleSnapshot: CallLifecycleSnapshot = .idle

    let cloudV2: CloudV2Model?
    private var cloudObservation: AnyCancellable?
    private var cloudProjectionTask: Task<Void, Never>?
    var isV2: Bool { cloudV2 != nil }
    var messageScope: String { cloudV2.map { ($0.configuration?.identity.account ?? "") + ($0.selectedModuleID ?? "") } ?? "legacy" }
    var speakerEnabled: Bool { cloudV2?.media.speaker ?? audio.speakerEnabled }

    let api: AirSIMAPI
    let contacts = ContactStore()
    let audio = AudioSessionController()
    lazy var callKit = CallKitController.shared
    lazy var backgroundStandby = BackgroundStandbyController()
    lazy var vowlan = VoWLANController()
    lazy var incomingNotifier = IncomingCallNotifier()
    lazy var incomingSMSNotifier = IncomingSMSNotifier()
    lazy var liveActivity = LiveActivityController()

    private lazy var historyStore = LocalHistoryStore()

    private var pollingTask: Task<Void, Never>?
    private var moduleMetadataTask: Task<Void, Never>?
    private var activeOperationCount = 0
    private var startingCallAudio = false
    private var currentCallTransport: CallTransport?
    private var lockedCallTransport: LockedCallTransport?
    private var currentLocalAPI: AirSIMAPI?
    private var currentPCMRoute: PCMRoute?
    private var lastSuccessfulLocalAPI: AirSIMAPI?
    private var observedCallLocalAPI: (callID: String, service: AirSIMAPI)?
    private var callLifecycleStore = CallLifecycleStore()
    private var appIsActive = true
    private let initialPermissionCoordinator = InitialPermissionCoordinator()
    private var initialPermissionTask: Task<Void, Never>?
    private var eventRevision: UInt64 = AgentEventCursor.initial
    private var smsRevision: UInt64 = 0
    private var eventStreamSupported: Bool?
    private var pollingGeneration = 0
    private var hasStarted = false
    private var consecutivePollFailures = 0
    private var callTransitionProtectedUntil = Date.distantPast
    private var nextAudioDiagnosticRefresh = Date.distantPast
    private var nextModuleMetadataRefresh = Date.distantPast
    private var lastCloudStatusRefresh = Date.distantPast
    private var cloudStatusRefreshTask: Task<Void, Never>?
    private var cloudStatusRefreshGeneration = 0
    private var audioWarmupCallID: String?
    private var lowPowerModeEnabled = true
    private let backgroundStandbyKey = "airsim.background-standby-enabled"
    private let lowPowerModeKey = "airsim.low-power-mode-enabled"
    private let maxCallHistoryCount = 500
    private let maxMessageCount = 2_000

    var inAppPresentedCall: CallRecord? {
        if isV2 { return activeCall }
        return CallPresentationPolicy.inAppCall(
            surface: callPresentationSurface,
            local: lifecycleRecord(from: activeCall),
            remote: lifecycleRecord(from: remoteCall),
            pending: pendingOutgoingCall
        )
    }

    var callAudioIsActive: Bool {
        if let cloudV2 { return cloudV2.media.state == .paired }
        return audio.active || cloudCallAudioState.isConnected || VirtualCallTTSController.shared.isPrepared
    }

    var connectionModePresentation: ConnectionModePresentation {
        if let cloudV2 { return ConnectionModePresentation(mode: .cloud, title: "云端 v2", status: cloudV2.connected ? "已连接" : "未连接", detail: cloudV2.userStatus) }
        return ConnectionModePresentation.make(
            vowlanOnline: vowlan.availability.isOnlineForDisplay,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudOnline: cloudAgentStatus?.cloudOnline == true
        )
    }

    var pairedAndroidAgents: [AndroidAgentPresentation] {
        if let cloudV2 { return cloudV2.modules.enumerated().map { index, module in AndroidAgentPresentation(id: module.module_id, deviceName: "模块 · \(module.module_id.prefix(8))", phoneNumber: nil, agentKind: "v2", cloudOnline: module.online, vowlanOnline: false, isCurrent: module.module_id == cloudV2.selectedModuleID) } }
        let cloudStatus = cloudAgentDirectory ?? cloudAgentStatus
        let cloudStatusIsFresh = Date().timeIntervalSince(lastCloudStatusRefresh) <= 90
        var values: [String: AndroidAgentPresentation] = [:]

        for agent in cloudStatus?.agents ?? [] {
            let name = agent.deviceName?.isEmpty == false
                ? agent.deviceName!
                : [agent.manufacturer, agent.model].compactMap { $0 }.joined(separator: " ")
            values[agent.id] = AndroidAgentPresentation(
                id: agent.id,
                deviceName: name.isEmpty ? "Android 手机" : name,
                phoneNumber: agent.phoneNumber?.isEmpty == false ? agent.phoneNumber : nil,
                agentKind: agent.agentKind,
                cloudOnline: cloudStatusIsFresh && agent.cloudOnline,
                vowlanOnline: false,
                isCurrent: false
            )
        }

        for local in vowlan.discoveredAgents {
            let previous = values[local.id]
            values[local.id] = AndroidAgentPresentation(
                id: local.id,
                deviceName: local.deviceName,
                phoneNumber: local.phoneNumber?.isEmpty == false ? local.phoneNumber : previous?.phoneNumber,
                agentKind: local.agentKind ?? previous?.agentKind,
                cloudOnline: previous?.cloudOnline ?? false,
                vowlanOnline: true,
                isCurrent: false
            )
        }

        if values.isEmpty, let cloudStatus, cloudStatusIsFresh, cloudStatus.cloudOnline {
            let fallbackID = cloudStatus.activeAgentID ?? "cloud-agent"
            values[fallbackID] = AndroidAgentPresentation(
                id: fallbackID,
                deviceName: "Android 手机",
                phoneNumber: nil,
                agentKind: nil,
                cloudOnline: true,
                vowlanOnline: false,
                isCurrent: false
            )
        }

        let currentID: String? = {
            if vowlan.availability.isOnlineForDisplay, let endpoint = vowlan.availability.endpoint {
                return vowlan.discoveredAgents.first(where: { $0.endpoint == endpoint })?.id
            }
            guard CloudModePreference.isEnabled(), cloudStatusIsFresh,
                  cloudStatus?.cloudOnline == true else { return nil }
            return cloudStatus?.activeAgentID
                ?? cloudStatus?.agents.first(where: \.cloudOnline)?.id
        }()

        return values.values.map { item in
            AndroidAgentPresentation(
                id: item.id,
                deviceName: item.deviceName,
                phoneNumber: item.phoneNumber,
                agentKind: item.agentKind,
                cloudOnline: item.cloudOnline,
                vowlanOnline: item.vowlanOnline,
                isCurrent: item.id == currentID
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            let leftOnline = $0.vowlanOnline || $0.cloudOnline
            let rightOnline = $1.vowlanOnline || $1.cloudOnline
            if leftOnline != rightOnline { return leftOnline }
            return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
        }
    }

    var currentAndroidAgent: AndroidAgentPresentation? {
        pairedAndroidAgents.first(where: \.isCurrent)
    }

    private func startCloudStatusQueryIfNeeded(beforeBackgroundCall: Bool = false) {
        let isForeground = appIsActive
        guard AppRefreshPolicy.shouldQueryCloudStatus(
                cloudModeEnabled: CloudModePreference.isEnabled(),
                lastAttempt: lastCloudStatusRefresh,
                appIsForeground: isForeground,
                beforeLiveActivityCall: beforeBackgroundCall
              ) else { return }
        lastCloudStatusRefresh = Date()
        // A previous foreground's online result must not become fresh again while this request is pending.
        cloudAgentDirectory = nil
        cloudAgentStatus = nil
        let generation = cloudStatusRefreshGeneration
        cloudStatusRefreshTask = Task { [weak self] in
            let status = try? await VoIPPushController.shared.fetchCloudAgentStatus()
            guard let self, !Task.isCancelled,
                  generation == self.cloudStatusRefreshGeneration else { return }
            self.cloudAgentDirectory = status
            self.cloudAgentStatus = status
            if !self.isOnline && !self.vowlan.availability.isOnlineForDisplay {
                self.connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: status?.cloudOnline == true,
                    cellularState: status?.cellularState
                )
            }
        }
    }

    private func awaitCloudStatusForLiveActivity(call: CallRecord?) async {
        // An incoming call can update an existing Live Activity while the App is backgrounded.
        // Query once before that update, but never poll Relay for idle background updates.
        startCloudStatusQueryIfNeeded(beforeBackgroundCall: call != nil)
        await cloudStatusRefreshTask?.value
    }

    @discardableResult
    func refreshCloudStatusForDiagnostics() async -> CloudAgentStatus? {
        if isV2 || R7UITestScenario.active { return nil }
        guard CloudModePreference.isEnabled() else {
            cloudAgentStatus = nil
            return nil
        }
        do {
            let status = try await VoIPPushController.shared.fetchCloudAgentStatusForDiagnostics()
            cloudAgentStatus = status
            cloudAgentDirectory = status
            lastCloudStatusRefresh = Date()
            if !vowlan.availability.isOnlineForDisplay {
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: status.cloudOnline,
                    cellularState: status.cellularState
                )
            }
            return status
        } catch {
            cloudAgentStatus = nil
            if !vowlan.availability.isOnlineForDisplay {
                connectionSummary = .offline
            }
            return nil
        }
    }

    var callUsesVoWLAN: Bool { currentCallTransport == .vowlan }

    var dialPadTransportPresentation: DialPadTransportPresentation? {
        if isV2 { return nil }
        return DialPadTransportPresentation.make(
            vowlanOnline: vowlan.availability.isOnlineForDisplay,
            moduleLocalReachable: false,
            cloudOnline: CloudModePreference.isEnabled()
                && (cloudAgentStatus?.cloudOnline == true || connectionSummary == .cloudOnly)
        )
    }

    /// 拨号页不能只依赖 `isOnline`：该字段代表 USB 本地控制链路，模块仅通过
    /// Relay 保持心跳时会刻意为 false。云端模式开启且心跳新鲜时，同样允许
    /// 用户发起拨号，实际执行仍会在 CallKit action 中再次鉴权和确认状态。
    var canStartOutgoingCommand: Bool {
        if let cloudV2 { return cloudV2.canAct && cloudV2.telephonyReady && cloudV2.activeCall == nil }
        return OutgoingCommandAvailability.isAvailable(
            localControlReachable: vowlan.availability.allowsCallAttempt,
            cloudModeEnabled: CloudModePreference.isEnabled(),
            cloudHeartbeatFresh: cloudAgentStatus?.cloudOnline == true || connectionSummary == .cloudOnly
        )
    }

    var callAudioStatusText: String {
        if let cloudV2 { return cloudV2.media.state.title }
        switch cloudCallAudioState {
        case .idle:
            return audio.active ? "语音链路已连接" : "正在建立语音链路"
        case let .connecting(attempt, maximum):
            return "正在重试云端语音 \(attempt)/\(maximum)"
        case .connected:
            return "云端语音已连接"
        case let .failed(message):
            return message
        }
    }

    init(api: AirSIMAPI = AirSIMAPI(), cloudV2: CloudV2Model? = nil) {
        self.api = api
        self.cloudV2 = cloudV2
        if let cloudV2 {
            cloudObservation = cloudV2.objectWillChange.sink { [weak self] _ in
                guard let self, self.cloudProjectionTask == nil else { return }
                self.cloudProjectionTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.projectCloudState()
                    self?.cloudProjectionTask = nil
                }
            }
            projectCloudState()
            return
        }
        if R7UITestScenario.active { return }
        if LocalModePreference.isEnabled() {
            UserDefaults.standard.set(false, forKey: CloudModePreference.key)
        }
        callKit.handler = self
        callKit.setEnabled(!LocalModePreference.isEnabled())
        WatchCallCoordinator.shared.configure(model: self)
        WatchCallCoordinator.shared.start()
        IPhoneCloudCallSession.shared.onAudioStateChange = { [weak self] state in
            self?.cloudCallAudioState = state
            if state.isConnected { self?.audio.retryRequestedSpeakerRoute() }
        }
        IPhoneCloudCallSession.shared.onLifecycleEvent = { [weak self] event in
            guard let self else { return }
            guard self.applyCallLifecycle(event) else { return }
            if event.state == .active {
                self.callKit.reportCurrentOutgoingConnected()
                self.updateRemoteCallState("active")
                Task { @MainActor [weak self] in await self?.startCallAudioIfReady() }
            } else if event.state.isTerminal {
                self.callPresentationSurface = nil
            }
        }
        vowlan.onAvailabilityChange = { [weak self] availability in
            guard let self else { return }
            self.objectWillChange.send()
            if case let .verified(endpoint, _) = availability,
               let credential = VoWLANCredentialStore.load() {
                let vowlanAPI = AirSIMAPI(route: .vowlan(
                    endpoint: endpoint,
                    credential: credential
                ))
                Task {
                    await VoIPPushController.shared.syncRegistration(with: vowlanAPI)
                }
            }
            guard self.currentCallTransport == .vowlan,
                  case .unavailable = availability,
                  self.callLifecycleSnapshot.state.representsCall else { return }
            Task { @MainActor [weak self] in await self?.endVoWLANCallAfterPathLoss() }
        }
        vowlan.onDiscoveredAgentsChange = { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func start(sceneIsActive: Bool) {
        if let cloudV2 { Task { await contacts.loadIfAuthorized(); await cloudV2.sceneChanged(sceneIsActive ? .active : .inactive) }; return }
        guard LegacyRuntimeGate.allowed else { return }
        guard !hasStarted else { return }
        hasStarted = true
        appIsActive = sceneIsActive
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        let storedValue = UserDefaults.standard.object(forKey: backgroundStandbyKey) as? Bool
        let storedLowPowerValue = UserDefaults.standard.object(forKey: lowPowerModeKey) as? Bool
        lowPowerModeEnabled = storedLowPowerValue ?? true
        liveActivity.setEnabled(LiveActivityVisibilityPreference.isEnabled())
        backgroundStandby.setEnabled(storedValue ?? true)
        // 先加载手机副本，再启动轮询，避免模块暂时离线时界面显示为空。
        restoreLocalHistory()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    /// 每次从锁屏或后台回来都舍弃旧连接，避免休眠前的超时结果覆盖新状态。
    func didBecomeActive() {
        if R7UITestScenario.active && !isV2 { return }
        if let cloudV2 { Task { await cloudV2.sceneChanged(.active) }; return }
        appIsActive = true
        let discoveryWasAlreadyStarted = initialPermissionCoordinator.didStartDiscovery
        requestMicrophoneOnForegroundIfNeeded()
        startCloudStatusQueryIfNeeded()
        if discoveryWasAlreadyStarted {
            vowlan.restartBrowsing()
            Task { await vowlan.probeNow() }
        }
        eventStreamSupported = nil
        consecutivePollFailures = 0
        isReconnecting = false
        backgroundStandby.setApplicationIsBackground(false)
        guard hasStarted else {
            start(sceneIsActive: true)
            return
        }
        // App 可能在首次解锁前被 PushKit/后台任务唤醒，此时受保护文件会暂时读成空。
        // 回到前台重新做并集合并，不能让早期空读取覆盖手机里的持久化记录。
        restoreLocalHistory()
        Task { await contacts.loadIfAuthorized() }
        if IncomingCallPresentationRequest.isPending() { presentCurrentCallInApp() }
        presentManagedCallAfterForegroundTransition()
        restartPolling()
    }

    func willResignActive() {
        if R7UITestScenario.active && !isV2 { return }
        if isV2 { return }
        backgroundStandby.prepareForBackground()
    }

    func didEnterBackground() {
        if R7UITestScenario.active && !isV2 { return }
        if let cloudV2 { Task { await cloudV2.sceneChanged(.background) }; return }
        appIsActive = false
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        backgroundStandby.setApplicationIsBackground(true)
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        restartPolling()
    }

    private func requestMicrophoneOnForegroundIfNeeded() {
        guard initialPermissionTask == nil,
              appIsActive else { return }
        initialPermissionTask = Task { [weak self] in
            guard let self else { return }
            await self.initialPermissionCoordinator.requestIfNeeded(
                isForeground: { self.appIsActive && LegacyRuntimeGate.allowed && !Task.isCancelled },
                microphoneIsUndetermined: { self.audio.microphonePermissionIsUndetermined },
                requestMicrophone: { _ = await self.audio.requestMicrophonePermission() },
                startDiscovery: { self.vowlan.startBrowsing() },
                requestNotifications: { self.incomingNotifier.requestAuthorization() }
            )
            self.initialPermissionTask = nil
        }
    }

    func setBackgroundStandbyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundStandbyKey)
        backgroundStandby.setEnabled(enabled)
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowPowerModeKey)
        lowPowerModeEnabled = enabled
        // 立即重建轮询任务，让用户切换后无需等待旧睡眠周期结束。
        if hasStarted { restartPolling() }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LiveActivityVisibilityPreference.key)
        liveActivity.setEnabled(enabled)
        VoIPPushController.shared.setLiveActivityEnabled(enabled)
        if enabled {
            cloudStatusRefreshTask?.cancel()
            cloudStatusRefreshTask = nil
            cloudStatusRefreshGeneration &+= 1
            lastCloudStatusRefresh = .distantPast
            startCloudStatusQueryIfNeeded()
            Task { [weak self] in
                guard let self else { return }
                await self.cloudStatusRefreshTask?.value
                guard LiveActivityVisibilityPreference.isEnabled() else { return }
                let call = self.lifecycleRecord(from: self.activeCall ?? self.remoteCall)
                await self.liveActivity.update(
                    call: call,
                    callerName: call.map { self.contacts.displayName(for: $0.number) },
                    moduleOnline: self.isOnline,
                    cloudOnline: CloudModePreference.isEnabled()
                        && self.cloudAgentStatus?.cloudOnline == true,
                    transport: self.liveActivityTransport,
                    radio: self.modemStatus,
                    agent: self.liveActivityAgentSnapshot,
                    appIsActive: self.appIsActive
                )
            }
        }
    }

    func setLocalModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LocalModePreference.key)
        cloudStatusRefreshTask?.cancel()
        cloudStatusRefreshTask = nil
        cloudStatusRefreshGeneration &+= 1
        lastCloudStatusRefresh = .distantPast
        if enabled {
            UserDefaults.standard.set(false, forKey: CloudModePreference.key)
            cloudAgentStatus = nil
            cloudAgentDirectory = nil
        }
        callKit.setEnabled(!enabled)
        VoIPPushController.shared.setLocalModeEnabled(enabled)
        WatchCallCoordinator.shared.refreshMediaPolicy()
        if enabled {
            Task { [weak self] in
                guard let self, let (api, _) = await self.readyVoWLANRoute() else { return }
                try? await api.setPushCloudEnabled(false)
            }
        }
        objectWillChange.send()
        if hasStarted { restartPolling() }
    }

    private func restartPolling() {
        pollingGeneration &+= 1
        let generation = pollingGeneration
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(generation: generation)
                guard let delay = self?.nextPollingDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 模块在线时与其 1 秒 AT 轮询对齐；离线后退避，避免断开模块时持续唤醒手机和 USB 栈。
    private var nextPollingDelay: TimeInterval {
        if consecutivePollFailures > 0 {
            let maximumDelay: TimeInterval = appIsActive ? 3 : 30
            return min(maximumDelay, pow(2, Double(consecutivePollFailures - 1)))
        }
        if !appIsActive {
            // 长轮询本身已经等待最多 15 秒；返回后只需短暂让出执行权再继续等待。
            if eventStreamSupported == true { return 0.1 }
            return lowPowerModeEnabled ? 10 : 2
        }
        if eventStreamSupported == true { return 0.1 }
        return 1
    }

    var blocksRuntimeSwitch: Bool {
        if let cloudV2 { return cloudV2.blocksSwitch }
        if R7UITestScenario.active { return false }
        return LegacyBusinessReservations.pending || LegacySwitchFence.shared.blocked || activeOperationCount > 0 || isBusy || pendingOutgoingCall != nil || callLifecycleSnapshot.state.representsCall
            || activeCall != nil || remoteCall != nil || callAudioIsActive || callKit.managesCurrentCall
            || IPhoneCloudCallSession.shared.hasActiveCall || WatchCallCoordinator.shared.hasPendingBusiness
    }

    func stopRuntime() async {
        if let cloudV2 { await cloudV2.stop(); return }
        hasStarted = false; appIsActive = false
        pollingGeneration &+= 1; cloudStatusRefreshGeneration &+= 1
        let tasks = [pollingTask, moduleMetadataTask, initialPermissionTask, cloudStatusRefreshTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        pollingTask = nil; moduleMetadataTask = nil; initialPermissionTask = nil; cloudStatusRefreshTask = nil
        vowlan.onAvailabilityChange = nil; vowlan.onDiscoveredAgentsChange = nil; vowlan.stopBrowsing()
        backgroundStandby.setEnabled(false); audio.deactivate()
        await IPhoneCloudCallSession.shared.waitForPersistentControls()
        await IPhoneCloudCallSession.shared.stopRuntimeAndWait(); VirtualCallTTSController.shared.stop()
        for task in tasks { await task.value }
        await liveActivity.stop()
        callKit.handler = nil
    }

    func stop() {
        if let cloudV2 { Task { await cloudV2.stop() }; return }
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        audio.deactivate()
        backgroundStandby.setEnabled(false)
        Task { await liveActivity.stop() }
        if let samsungAPI = verifiedVoWLANAPI() {
            Task { try? await samsungAPI.setAudioHostEnabled(false) }
        }
    }

    private func poll(generation: Int) async {
        do {
            let result = try await nextAgentEvent()
            let status = result.call
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            let previousCall = activeCall
            let history = await mergeCallHistory(status.history ?? [])
            let confirmedEndedCall = previousCall.flatMap { previous in
                status.history?.first { $0.id == previous.id && $0.endedAt != nil }
            }
            let acceptedActiveLifecycle: Bool
            if let active = status.active {
                acceptedActiveLifecycle = applyAgentCallRecord(active)
            } else if let ended = confirmedEndedCall {
                acceptedActiveLifecycle = false
                _ = applyAgentCallRecord(ended, forcedState: .ended)
            } else {
                acceptedActiveLifecycle = false
            }
            if let active = status.active {
                observedCallLocalAPI = (callID: active.id, service: result.api)
                // Agent 状态与统一生命周期真正汇合后才能撤掉临时呼出页。
                // 否则上一通 ending 的晚到事件会让用户在几秒后掉回拨号页。
                if acceptedActiveLifecycle || callLifecycleSnapshot.callID == active.id {
                    pendingOutgoingCall = nil
                }
                if activeCall != active { activeCall = active }
            } else if confirmedEndedCall != nil, activeCall != nil {
                activeCall = nil
                observedCallLocalAPI = nil
            }
            if let active = status.active {
                if remoteCall?.id == active.id { remoteCall = nil }
                if callPresentationSurface == nil {
                    callPresentationSurface = appIsActive ? .app : .system
                }
            } else if previousCall != nil,
                      callLifecycleSnapshot.state.isTerminal,
                      !IPhoneCloudCallSession.shared.hasActiveCall {
                callPresentationSurface = nil
                remoteCall = nil
            }
            if callHistory != history { callHistory = history }
            consecutivePollFailures = 0
            if isReconnecting { isReconnecting = false }
            lastSuccessfulLocalAPI = result.api

            if let call = status.active,
               ["dialing", "alerting", "incoming", "waiting"].contains(call.state),
               audioWarmupCallID != call.id {
                audioWarmupCallID = call.id
                // 预热只加载驱动和校准，把最慢的冷启动提前到接通之前。
                Task { [weak self] in
                    guard let self else { return }
                    try? await AgentPollingRouteSelector.select(
                        primary: result.api,
                        lockedLocal: self.currentLocalAPI,
                        transport: self.currentCallTransport
                    ).warmAudioHost()
                }
            } else if status.active == nil, previousCall != nil {
                audioWarmupCallID = nil
            }
            // HTTP 已成功返回就说明 USB 模块代理在线。last_poll_error 只是模块内部 AT+CLCC
            // 的最近轮询结果，通话建立期间可能短暂非空，不能据此把整条 USB 链路判为离线。
            if !isOnline { isOnline = true }
            cloudAgentStatus = nil
            updateLocalConnectionSummary(cellularState: modemStatus?.cellularState)
            // PushKit token 必须写入当前真正可达的 Agent。热点场景不能再固定访问 USB 地址。
            await VoIPPushController.shared.syncRegistration(with: result.api)
            if AppRefreshPolicy.shouldRefreshSupplementalState(appIsActive: appIsActive) {
                scheduleModuleMetadataRefresh(generation: generation, api: result.api)
            }
            let lifecycleCall = lifecycleRecord(from: status.active ?? previousCall)
            let systemCall = status.active
            let callerName = (systemCall ?? lifecycleCall).map { contacts.displayName(for: $0.number) }
            // 必须先请求 CallKit，再决定是否发送本地通知。否则后台来电会同时出现
            // 系统通话界面和一条带接听按钮的通知；CallKit 上报失败时下一轮再自动降级。
            if !WatchCallCoordinator.shared.ownsMedia(callID: systemCall?.id) {
                callKit.synchronize(
                    // CallKit 要直接消费 Agent 的事实状态。即使 App 展示层正在处理
                    // 乱序生命周期，也不能把真实 active 误传成 nil 并提前结束系统通话。
                    call: systemCall,
                    previous: confirmedEndedCall ?? previousCall,
                    callerName: callerName
                )
            }
            WatchCallCoordinator.shared.publish(
                call: lifecycleCall,
                previous: confirmedEndedCall ?? previousCall,
                callerName: callerName ?? previousCall.map { contacts.displayName(for: $0.number) }
            )
            await awaitCloudStatusForLiveActivity(call: lifecycleCall)
            await liveActivity.update(
                call: lifecycleCall,
                callerName: callerName,
                moduleOnline: true,
                transport: liveActivityTransport,
                radio: modemStatus,
                agent: liveActivityAgentSnapshot,
                appIsActive: appIsActive
            )
            // CallKit 成功后由系统负责锁屏来电界面；仅在 CallKit 不可用或上报失败时发普通通知兜底。
            if !callKit.suppressesInAppIncomingRingtone {
                incomingNotifier.update(
                    call: lifecycleCall,
                    callerName: callerName,
                    appIsActive: appIsActive
                )
            }
            if lifecycleCall?.direction == "incoming", callKit.suppressesInAppIncomingRingtone {
                // CallKit 已负责系统铃声，不能再叠加应用内铃声。
                audio.stopCallTone()
            } else {
                audio.updateCallTone(for: lifecycleCall)
            }

            // 已完成首次向导的旧用户也要获得模块更新；仅在无通话时后台检查，避免中断基带媒体。
            // AirSIM 不内置、也不自动刷写 QDC507 Agent。

            // 接通期间持续确认本地音频仍在工作。CallKit 或系统音频服务重置后，
            // 即使模块状态没有发生变化，下一轮也必须能够重建网络 PCM。
            if status.active?.state == "active" {
                await startCallAudioIfReady()
            } else if status.active == nil, previousCall != nil {
                // 远端挂断不会经过 App 的挂断按钮；同样开启切换保护，避免媒体路由
                // 退出时的短暂 ECM/AT 抖动被误报为整台模块离线。
                beginCallTransitionProtection()
                // 云端回退通话可能在本地模块状态消失后仍然有效；不能让本地轮询
                // 清除共享 AVAudioSession 的扬声器覆盖或打断公网 PCM。
                if currentCallTransport != .cloud,
                   !IPhoneCloudCallSession.shared.hasActiveCall {
                    audio.deactivate()
                }
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                backgroundStandby.resumeAfterCall()
                isMuted = false
                isRecording = false
            }
            if appIsActive, status.active?.state == "active",
               Date() >= nextAudioDiagnosticRefresh,
               let audioConfig = try? await AgentPollingRouteSelector.select(
                   primary: result.api,
                   lockedLocal: currentLocalAPI,
                   transport: currentCallTransport
               ).audioHostConfig() {
                // 诊断统计无需跟随每次通话轮询，降低额外 TCP 建连和 JSON 解码频率。
                nextAudioDiagnosticRefresh = Date().addingTimeInterval(3)
                audio.updateModuleDiagnostics(audioConfig)
            }
            if result.smsChanged {
                await loadMessagesFromAgent(
                    silently: true, notifyIfBackground: true, reportingAgent: result.api
                )
            }
        } catch {
            guard !Task.isCancelled, generation == pollingGeneration else { return }
#if DEBUG
            print("[AirSIM Poll] module status failed: \(error.localizedDescription)")
#endif
            consecutivePollFailures += 1
            isReconnecting = true
            let failedRouteName: String = {
                guard let route = lastSuccessfulLocalAPI?.route else { return "本地控制链路" }
                if case .vowlan = route { return "VoWLAN" }
                return "模块本地链路"
            }()
            connectionMessage = "正在重新连接\(failedRouteName)：\(error.localizedDescription)"

            // 一次长轮询中断不能代表 USB ECM 已离线。通话动作后的 8 秒保护期内
            // 保留最后一次在线状态；其后也必须连续失败三次并让独立 health 请求失败。
            guard ModuleConnectivityPolicy.shouldConfirmOffline(
                consecutiveFailures: consecutivePollFailures,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else { return }

            // 用最后实际成功的本地路线复核健康状态。VoWLAN 的长轮询偶发断开时，
            // 不能再转去探测 USB 默认地址并据此把三星 Agent 判为离线。
            let healthAPI = lastSuccessfulLocalAPI ?? verifiedVoWLANAPI()
            let health = try? await healthAPI?.health()
            guard ModuleConnectivityPolicy.shouldMarkOffline(
                consecutiveFailures: consecutivePollFailures,
                healthRequestSucceeded: health != nil,
                now: Date(),
                protectedUntil: callTransitionProtectedUntil
            ) else {
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                consecutivePollFailures = 0
                isReconnecting = health?.ok == false
                if !isOnline { isOnline = true }
                cloudAgentStatus = nil
                updateLocalConnectionSummary(cellularState: health?.cellularState)
                if health?.ok == false {
                    connectionMessage = health?.cellularRecovery?.isEmpty == false
                        ? "模块已连接，AT 通道恢复中 · \(health!.cellularRecovery!)"
                        : "模块已连接，AT 通道正在自动恢复"
                }
                return
            }

            guard !Task.isCancelled, generation == pollingGeneration else { return }
            if IPhoneCloudCallSession.shared.hasActiveCall || IPhoneCloudCallSession.shared.isRecovering {
                // 已建立的公网媒体会话本身就是独立的云端在线证据。接听时 USB/ECM
                // 路由短暂抖动不能把整台模块标成离线，也不能结束灵动岛状态。
                consecutivePollFailures = 0
                if isOnline { isOnline = false }
                isReconnecting = true
                connectionSummary = ModuleConnectionPolicy.summary(
                    localControlReachable: false,
                    cloudHeartbeatFresh: true,
                    cellularState: cloudAgentStatus?.cellularState ?? modemStatus?.cellularState
                )
                connectionMessage = IPhoneCloudCallSession.shared.isRecovering
                    ? "云端通话在线，公网 PCM 正在重新连接"
                    : "云端通话在线，USB ECM 正在重新连接"
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await awaitCloudStatusForLiveActivity(call: lifecycleCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
                return
            }
            if isOnline { isOnline = false }
            lastSuccessfulLocalAPI = nil
            audio.stopCallTone()
            await awaitCloudStatusForLiveActivity(call: nil)
            let cloudStatus = CloudModePreference.isEnabled() &&
                Date().timeIntervalSince(lastCloudStatusRefresh) <= 90
                ? (cloudAgentDirectory ?? cloudAgentStatus) : nil
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            cloudAgentStatus = cloudStatus
            connectionSummary = ModuleConnectionPolicy.summary(
                localControlReachable: false,
                cloudHeartbeatFresh: cloudStatus?.cloudOnline == true,
                cellularState: cloudStatus?.cellularState
            )
            if cloudStatus?.cloudOnline == true {
                isReconnecting = true
                if let version = cloudStatus?.agentVersion, !version.isEmpty { agentVersion = version }
                connectionMessage = cloudConnectionMessage(for: cloudStatus!)
                // USB 本地控制不可达不等于模块离线。Relay 心跳新鲜时保留灵动岛待机，
                // 来电仍可由 PushKit 唤醒并走公网 PCM。
                let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
                await liveActivity.update(
                    call: lifecycleCall,
                    callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
                    moduleOnline: false,
                    cloudOnline: true,
                    transport: .cloud,
                    radio: modemStatus,
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            } else {
                isReconnecting = false
                connectionMessage = "模块本地与云端均不可达：\(error.localizedDescription)"
                await liveActivity.markOffline(
                    agent: liveActivityAgentSnapshot,
                    appIsActive: appIsActive
                )
            }
        }

    }

    private struct AgentPollResult {
        let call: CallStatus
        let smsChanged: Bool
        let api: AirSIMAPI
    }

    private func nextAgentEvent() async throws -> AgentPollResult {
        if verifiedVoWLANAPI() == nil {
            await vowlan.recoverIfNeeded()
        }
        guard let samsungAPI = verifiedVoWLANAPI() else {
            throw CallKitBridgeError.noReachableTransport
        }
        let pollingAPI = AgentPollingRouteSelector.select(
            primary: samsungAPI,
            lockedLocal: currentLocalAPI,
            transport: currentCallTransport
        )
        if eventStreamSupported != false {
            do {
                let event = try await pollingAPI.waitForAgentEvent(
                    after: eventRevision,
                    timeout: AgentEventPollingPolicy.timeout(hasActiveCall: callLifecycleSnapshot.state.representsCall)
                )
                eventStreamSupported = true
                eventRevision = AgentEventCursor.advanced(from: eventRevision, to: event.revision)
                let shouldFetchSMS = AgentEventPollingPolicy.shouldFetchSMS(
                    pending: event.smsPending,
                    eventRevision: event.smsRevision,
                    observedSMSRevision: smsRevision
                )
                smsRevision = event.smsRevision
                return AgentPollResult(
                    call: event.call,
                    smsChanged: shouldFetchSMS,
                    api: pollingAPI
                )
            } catch APIError.http(404, _) {
                // 0.3.18 等旧 Agent 没有统一事件接口；保留兼容轮询直到模块升级。
                eventStreamSupported = false
            }
        }
        let legacy = try await LegacyAgentPoller.next(pollingAPI)
        return AgentPollResult(call: legacy.call, smsChanged: legacy.smsChanged, api: pollingAPI)
    }

    private func verifiedVoWLANAPI() -> AirSIMAPI? {
        guard vowlan.availability.isOnlineForDisplay,
              let endpoint = vowlan.availability.endpoint,
              let credential = VoWLANCredentialStore.load() else { return nil }
        return AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential))
    }

    private var moduleLocalIsReachable: Bool {
        false
    }

    private var reachableLocalAPI: AirSIMAPI? {
        if let currentLocalAPI, AirSIMRoutePolicy.permits(currentLocalAPI.route) {
            return currentLocalAPI
        }
        guard isOnline, !isReconnecting else { return nil }
        guard let lastSuccessfulLocalAPI,
              AirSIMRoutePolicy.permits(lastSuccessfulLocalAPI.route) else { return nil }
        return lastSuccessfulLocalAPI
    }

    private var localCallControlAPI: AirSIMAPI? {
        LocalCallControlTarget.select(
            locked: currentLocalAPI,
            observed: observedCallLocalAPI,
            fallback: reachableLocalAPI,
            targetCallID: activeCall?.id
        )
    }

    private var liveActivityTransport: AirSIMCallActivityAttributes.ContentState.Transport? {
        switch currentCallTransport {
        case .vowlan: return .vowlan
        case .cloud: return .cloud
        case .moduleLocal: return .moduleLocal
        case nil: break
        }
        if let route = lastSuccessfulLocalAPI?.route {
            switch route {
            case .vowlan: return .vowlan
            case .moduleLocal: return .moduleLocal
            }
        }
        return connectionSummary == .cloudOnly ? .cloud : nil
    }

    private var liveActivityAgentSnapshot: LiveActivityAgentSnapshot? {
        let agents = pairedAndroidAgents
        guard !agents.isEmpty else { return nil }
        return LiveActivityAgentSnapshot(
            agent: agents.first(where: \.isCurrent),
            pairedAgentCount: agents.count
        )
    }

    private static func pcmRoute(for route: LocalAgentRoute) -> PCMRoute {
        switch route {
        case .moduleLocal:
            return .moduleLocal
        case let .vowlan(endpoint, credential):
            return .vowlan(endpoint: endpoint, credential: credential)
        }
    }

    /// 蜂窝状态和版本不必跟随每秒通话轮询；独立刷新避免慢 AT 状态接口拖住来电检测。
    private func scheduleModuleMetadataRefresh(generation: Int, api: AirSIMAPI) {
        guard moduleMetadataTask == nil, Date() >= nextModuleMetadataRefresh else { return }
        nextModuleMetadataRefresh = Date().addingTimeInterval(10)
        moduleMetadataTask = Task { [weak self] in
            await self?.refreshModuleMetadata(generation: generation, api: api)
        }
    }

    private func refreshModuleMetadata(generation: Int, api: AirSIMAPI) async {
        defer { moduleMetadataTask = nil }
        async let radioRequest = try? api.modemStatus()
        let radio = await radioRequest
        guard !Task.isCancelled, generation == pollingGeneration, isOnline, appIsActive else { return }
        if let radio, modemStatus != radio { modemStatus = radio }
        updateLocalConnectionSummary(cellularState: radio?.cellularState ?? modemStatus?.cellularState)
        let lifecycleCall = lifecycleRecord(from: activeCall ?? remoteCall)
        await awaitCloudStatusForLiveActivity(call: lifecycleCall)
        await liveActivity.update(
            call: lifecycleCall,
            callerName: lifecycleCall.map { contacts.displayName(for: $0.number) },
            moduleOnline: true,
            transport: liveActivityTransport,
            radio: modemStatus,
            agent: liveActivityAgentSnapshot,
            appIsActive: appIsActive
        )
    }

    private func updateLocalConnectionSummary(cellularState: String?) {
        connectionSummary = ModuleConnectionPolicy.summary(
            localControlReachable: true,
            cloudHeartbeatFresh: false,
            cellularState: cellularState
        )
        switch connectionSummary {
        case .localOnline:
            connectionMessage = nil
        case .localOnlineNoService:
            let detail = modemStatus?.cellularRecovery ?? modemStatus?.registrationText
            connectionMessage = detail?.isEmpty == false
                ? "USB ECM 已连接 · \(detail!)"
                : "USB ECM 已连接，蜂窝网络正在恢复"
        case .cloudOnly, .offline:
            break
        }
    }

    private func cloudConnectionMessage(for status: CloudAgentStatus) -> String {
        let local = "USB ECM 本地连接中断，模块云端在线"
        if status.cellularState == "registered" {
            return local + "，来电将通过云端接听"
        }
        let detail = status.cellularRecovery?.isEmpty == false
            ? status.cellularRecovery!
            : (status.cellularRegistration?.isEmpty == false ? status.cellularRegistration! : "蜂窝网络恢复中")
        return local + " · " + detail
    }

    func dial() async {
        if let cloudV2 {
            if cloudV2.systemCalls != nil {
                do { try await callKit.startOutgoingCall(number: numberInput) } catch { errorMessage = "无法发起系统通话，请检查权限与连接。" }
            } else { cloudV2.number = numberInput; await cloudV2.dial() }
            projectCloudState(); return
        }
        let number = Self.validatedNumber(numberInput)
        guard !number.isEmpty else { return }
        callPresentationSurface = .app
        let now = Date()
        pendingOutgoingCall = CallRecord(
            id: "pending-\(UUID().uuidString.lowercased())",
            index: 0,
            direction: "outgoing",
            state: "dialing",
            number: number,
            startedAt: now,
            updatedAt: now,
            endedAt: nil,
            missed: false
        )
        debugDialLog(LocalModePreference.isEnabled() ? "本地模式直接呼出" : "开始提交 CallKit 系统呼出")
        await perform {
            if LocalModePreference.isEnabled() {
                try await self.callKitStart(number: number)
                return
            }
            do {
                try await self.callKit.startOutgoingCall(number: number)
                debugDialLog("CallKit 呼出事务已提交")
            } catch CallKitBridgeError.unavailable {
                // 受限签名或系统禁用 CallKit 时仍允许用户拨出，但不伪造系统 UUID。
                // 仍复用标准路由选择，确保 VoWLAN 在线时控制与 PCM 都锁定到热点。
                try await self.callKitStart(number: number)
                debugDialLog("CallKit 不可用，已按当前传输路由直拨")
            }
        }
    }

    func answer() async {
        if let cloudV2 {
            if cloudV2.systemCalls != nil {
                do { try await callKit.answerCurrentCall(presentInApp: true) } catch { errorMessage = "系统来电尚未就绪，请等待核对。" }
            } else if let call = cloudV2.activeCall { await cloudV2.answer(call) }
            projectCloudState(); return
        }
        beginCallTransitionProtection()
        audio.stopCallTone()
        callPresentationSurface = .app
        applyCurrentCallIntent(.connecting, source: .app)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.answerCurrentCall(presentInApp: true)
                } catch CallKitBridgeError.staleSystemCall {
                    // 系统界面重建期间仍复用标准路线选择，不能回退到 USB 默认地址。
                    try await self.callKitAnswer(origin: .app)
                }
            }
        } else {
            await perform { try await self.callKitAnswer(origin: .app) }
        }
    }

    func presentCurrentCallInApp() {
        if isV2 { return }
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(from: incoming, state: "incoming")
        }
        guard callLifecycleSnapshot.state.representsCall else { return }
        _ = IncomingCallPresentationRequest.consume()
        callPresentationSurface = .app
    }

    /// 正常情况下系统接听会停留在 CallKit。若 iOS、普通 APNs 或用户手势实际把
    /// AirSIM 拉到前台，则必须展示同一通电话，而不是让用户掉回拨号/设置页面。
    private func presentManagedCallAfterForegroundTransition() {
        guard appIsActive,
              CallPresentationPolicy.shouldPresentWhenAppBecomesActive(
                  managesSystemCall: callKit.managesCurrentCall,
                  hasLocalCall: lifecycleRecord(from: activeCall) != nil,
                  hasRemoteCall: lifecycleRecord(from: remoteCall) != nil
              ) else { return }
        if remoteCall == nil, let incoming = callKit.currentIncomingPush {
            remoteCall = Self.remoteCallRecord(
                from: incoming,
                state: callKit.currentCallIsAnswered ? "active" : "incoming"
            )
        } else if callKit.currentCallIsAnswered {
            updateRemoteCallState("active")
        }
        callPresentationSurface = .app
    }

    func reject() async {
        if let cloudV2 {
            if cloudV2.systemCalls != nil { do { try await callKit.endCurrentCall() } catch { errorMessage = "系统通话尚未就绪。" } }
            else if let call = cloudV2.activeCall { await cloudV2.reject(call) }
            projectCloudState(); return
        }
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.rejectUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.rejectUsingAvailableTransport() }
        }
    }

    func hangup() async {
        if let cloudV2 {
            if cloudV2.systemCalls?.hasSystemCall == true { do { try await callKit.endCurrentCall() } catch { errorMessage = "无法结束系统通话，请核对原操作。" } }
            else { await cloudV2.hangup() }
            projectCloudState(); return
        }
        beginCallTransitionProtection()
        audio.stopCallTone()
        applyCurrentCallIntent(.ending, source: .app)
        if callKit.managesCurrentCall {
            await perform(allowWhileBusy: true) {
                do {
                    try await self.callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.hangupUsingAvailableTransport()
                }
            }
        } else {
            await perform(allowWhileBusy: true) { try await self.hangupUsingAvailableTransport() }
        }
    }

    private func rejectUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        if let localAPI = reachableLocalAPI {
            _ = try await localAPI.rejectCall(callID: activeCall?.id)
            return
        }
        if let pushedCall = callKit.currentIncomingPush,
           pushedCall.authenticatedMediaURL != nil {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            return
        }
        throw CallKitBridgeError.noReachableTransport
    }

    private func hangupUsingAvailableTransport() async throws {
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            await IPhoneCloudCallSession.shared.end()
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.hangupCall(callID: activeCall?.id)
    }

    private func beginCallTransitionProtection() {
        callTransitionProtectedUntil = Date().addingTimeInterval(
            ModuleConnectivityPolicy.callTransitionGraceInterval
        )
    }
    func sendDTMF(_ digit: String) async {
        if let cloudV2 {
            if cloudV2.systemCalls != nil { do { try await callKit.playDTMF(digit) } catch { errorMessage = "无法发送按键。" } }
            else { cloudV2.tones = digit; await cloudV2.dtmf() }; return
        }
        await perform {
            if self.callKit.managesCurrentCall {
                do {
                    // App 内键盘与系统通话页共用 CallKit 事务，避免两边的 DTMF 顺序不一致。
                    try await self.callKit.playDTMF(digit)
                } catch CallKitBridgeError.staleSystemCall {
                    try await self.sendDTMFUsingAvailableTransport(digit)
                }
            } else {
                try await self.sendDTMFUsingAvailableTransport(digit)
            }
        }
    }

    private func sendDTMFUsingAvailableTransport(_ digit: String) async throws {
        if currentCallTransport == .cloud {
            try await VoIPPushController.shared.sendCloudDTMF(digit)
            return
        }
        guard let localAPI = reachableLocalAPI else {
            throw CallKitBridgeError.noReachableTransport
        }
        try await localAPI.sendDTMF(digit)
    }

    func toggleMute() async {
        if let cloudV2 {
            if cloudV2.systemCalls != nil { do { try await callKit.setMuted(!cloudV2.media.muted) } catch { errorMessage = "无法切换系统静音。" } }
            else { cloudV2.media.setMuted(!cloudV2.media.muted) }; projectCloudState(); return
        }
        let target = !isMuted
        if callKit.managesCurrentCall {
            do {
                try await callKit.setMuted(target)
                errorMessage = nil
            } catch {
                // CallKit UUID 可能因系统重置而短暂失效；本地 PCM 仍可可靠控制麦克风。
                if case CallKitBridgeError.staleSystemCall = error {
                    isMuted = target
                    audio.setMuted(target)
                    errorMessage = nil
                } else {
                    errorMessage = "系统静音切换失败：\(error.localizedDescription)"
                }
            }
            return
        }
        // 移动端上行语音由本地 PCM 管线产生，必须先本地静音，不能依赖模块 AT 命令成功。
        isMuted = target
        audio.setMuted(target)
        // QDC507 部分固件不实现 AT+CMUT；本地 PCM 已经是移动端的权威静音状态，
        // 后台同步失败不能阻断通话或弹出误导性的“麦克风已静音”错误。
        if let localAPI = reachableLocalAPI {
            Task { try? await localAPI.setAudioMuted(target) }
        }
        errorMessage = nil
    }

    func toggleSpeaker() {
        if let cloudV2 { cloudV2.media.setSpeaker(!cloudV2.media.speaker); projectCloudState(); return }
        // 扬声器切换只作用于当前系统音频会话；如果 CallKit 尚未完成激活，
        // AudioSessionController 会保留请求并短暂重试，不弹出 OSStatus -50。
        audio.toggleSpeakerRoute()
        errorMessage = nil
    }

    func toggleRecording() async {
        guard !isV2 else { return }
        let target = !isRecording
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            let response = try await samsungAPI.setCallRecording(target)
            isRecording = response.recording
            errorMessage = nil
        } catch {
            debugDialLog("操作失败：\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// 真机联调阶段输出拨号链路，不记录电话号码；Release 构建会完全移除。
    private func debugDialLog(_ message: String) {
#if DEBUG
        print("[AirSIM Dial] \(message)")
#endif
    }

    func sendSMS(to phone: String, content: String) async -> Bool {
        if let cloudV2 { cloudV2.smsNumber = phone; cloudV2.smsText = content; let sent = await cloudV2.sendSMS(); projectCloudState(); return sent }
        let target = Self.validatedNumber(phone)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty, body.count <= 2_000 else { return false }
        do {
            let localAPI = verifiedVoWLANAPI()
            let localReachable = localAPI != nil && isOnline && !isReconnecting
            let result: SMSSendResult
            if localReachable {
                result = try await localAPI!.sendSMS(to: target, message: body)
            } else if CloudModePreference.isEnabled() {
                let status: CloudAgentStatus
                if let cloudAgentStatus {
                    status = cloudAgentStatus
                } else {
                    status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                }
                guard status.cloudOnline else { throw CloudCommandError.unavailable }
                result = try await VoIPPushController.shared.sendCloudSMS(to: target, message: body)
            } else {
                throw CloudCommandError.cloudModeDisabled
            }
            if result.sent {
                saveSentMessage(recipient: target, content: body)
            }
            if localReachable { await refreshMessages(silently: true) }
            return result.sent
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshMessages(silently: Bool = false) async {
        if let cloudV2 { await cloudV2.refreshReadOnly(); return }
        do {
            guard let samsungAPI = verifiedVoWLANAPI() else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await samsungAPI.refreshSMS()
            await loadMessagesFromAgent(silently: silently, reportingAgent: samsungAPI)
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    /// URC 已经让 Agent 读取了单条短信；事件路径只取交付队列，不再触发全量 CMGL。
    func loadMessagesFromAgent(
        silently: Bool = false,
        notifyIfBackground: Bool = false,
        reportingAgent: AirSIMAPI? = nil
    ) async {
        if isV2 { projectCloudState(); return }
        do {
            guard let currentAgent = verifiedVoWLANAPI() ?? reportingAgent else {
                throw CallKitBridgeError.noReachableTransport
            }
            let fetched = try await AgentSMSInboxFetch.fetch(
                reportingAgent: reportingAgent, discoveredAgent: currentAgent
            )
            let remoteMessages = fetched.messages
            let existingIDs = Set(messages.map(\.id))
            let newlyReceived = remoteMessages
                .filter { !existingIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            let mergedMessages = await mergeMessages(remoteMessages, acknowledgingOn: fetched.agent)
            if messages != mergedMessages { messages = mergedMessages }
            if notifyIfBackground {
                for message in newlyReceived.suffix(3) {
                    incomingSMSNotifier.notify(
                        message: message,
                        displayName: contacts.displayName(for: message.sender),
                        appIsActive: appIsActive
                    )
                }
            }
            if !silently { errorMessage = nil }
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
    }

    func messageDeliveryText(_ message: SMSMessage) -> String {
        guard let cloudV2, let item = cloudV2.visibleMessages.first(where: { $0.id == message.deliveryID }) else { return "已发送" }
        switch item.message.state {
        case "sent": return "已发送（不代表已送达）"
        case "failed", "rejected": return "发送失败"
        default: return "发送结果待核对"
        }
    }

    func clearMessages() async {
        if isV2 { clearLocalMessages(); return }
        do { try await api.clearModuleSMS(); clearLocalMessages() }
        catch { errorMessage = "删除失败，已保留本机短信。" }
    }

    func projectCloudState() {
        guard let cloudV2 else { return }
        let oldActive = activeCall
        func record(_ item: V2StoredCall) -> CallRecord {
            let call = item.call
            return CallRecord(id: item.id, index: 0, direction: call.direction,
                state: call.state == "disconnected" ? "ended" : call.state == "ringing" ? "incoming" : call.state,
                number: call.number, startedAt: oldActive?.id == item.id ? oldActive!.startedAt : call.observedAt,
                updatedAt: call.observedAt, endedAt: call.state == "disconnected" ? call.observedAt : nil,
                missed: call.direction == "incoming" && call.disconnect_reason == "missed")
        }
        callHistory = cloudV2.visibleCalls.map(record)
        activeCall = cloudV2.visibleCalls.first { $0.call.call_id == cloudV2.activeCall?.call_id && $0.domain.bootID == cloudV2.snapshot?.snapshot?.agent_boot_id && $0.domain.backendEpoch == cloudV2.snapshot?.snapshot?.backend_epoch && $0.call.state != "disconnected" }.map(record)
        messages = cloudV2.visibleMessages.map { item in
            SMSMessage(sender: item.message.direction == "incoming" ? item.message.sender : item.message.recipient,
                content: item.message.text, code: nil, timestamp: item.message.observedAt,
                deliveryID: item.id, direction: item.message.direction == "incoming" ? .incoming : .outgoing)
        }
        isOnline = cloudV2.freshBinding != nil
        isBusy = cloudV2.busy
        isMuted = cloudV2.media.muted
        connectionMessage = cloudV2.userStatus
        if let error = cloudV2.error { errorMessage = error; cloudV2.error = nil }
    }

    func clearLocalMessages() {
        if let cloudV2 { cloudV2.clearCurrentMessages(); projectCloudState(); return }
        guard historyStore.saveMessages([]) else {
            errorMessage = "无法清空本机短信，请稍后重试"
            return
        }
        messages = []
        errorMessage = nil
    }

    func reloadMessagesFromLocalStore() {
        if isV2 { projectCloudState(); return }
        restoreLocalHistory()
    }

    /// 将磁盘副本并入当前内存，只增加或更新记录，绝不以空读取清掉界面数据。
    private func restoreLocalHistory() {
        let storedCalls = historyStore.loadCallHistory()
        if !storedCalls.isEmpty {
            var callsByID: [String: CallRecord] = [:]
            for record in callHistory { callsByID[record.id] = record }
            for record in storedCalls {
                if let existing = callsByID[record.id], existing.updatedAt >= record.updatedAt {
                    continue
                }
                callsByID[record.id] = record
            }
            callHistory = normalizedCallHistory(Array(callsByID.values))
        }

        let storedMessages = historyStore.loadMessages()
        if !storedMessages.isEmpty {
            var messagesByID: [String: SMSMessage] = [:]
            for message in messages { messagesByID[message.id] = message }
            for message in storedMessages { messagesByID[message.id] = message }
            messages = normalizedMessages(Array(messagesByID.values))
        }
    }

    /// 远端列表可能因模块重启、自动清理或离线而变短，因此只做并集，不删除手机副本。
    private func mergeCallHistory(_ remote: [CallRecord]) async -> [CallRecord] {
        var byID: [String: CallRecord] = [:]
        for record in callHistory {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt { continue }
            byID[record.id] = record
        }
        for record in remote {
            if let local = byID[record.id], local.updatedAt > record.updatedAt {
                continue
            }
            byID[record.id] = record
        }
        let merged = normalizedCallHistory(Array(byID.values))
        if !remote.isEmpty, historyStore.saveCallHistory(merged) {
            // 只有手机副本写入成功才确认模块，断线时模块仍会保留未交付队列。
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote.map(\.id).filter { persistedIDs.contains($0) }
            if let samsungAPI = verifiedVoWLANAPI() {
                try? await samsungAPI.acknowledgeCallHistory(ids: acknowledgedIDs)
            }
        }
        return merged
    }

    private func mergeMessages(
        _ remote: [SMSMessage], acknowledgingOn source: AirSIMAPI
    ) async -> [SMSMessage] {
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for var message in remote {
            // 旧版模块没有 delivery_id 时保留手机已有标识，避免新旧版本来回覆盖。
            if message.deliveryID == nil { message.deliveryID = byID[message.id]?.deliveryID }
            byID[message.id] = message
        }
        let merged = normalizedMessages(Array(byID.values))
        if !remote.isEmpty, historyStore.saveMessages(merged) {
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = remote
                .filter { persistedIDs.contains($0.id) }
                .compactMap(\.deliveryID)
            try? await source.acknowledgeMessages(ids: acknowledgedIDs)
        }
        return merged
    }

    /// 模块不会在收件箱接口回传已发送短信，因此发送成功后立即写入手机本地历史。
    private func saveSentMessage(recipient: String, content: String) {
        let updatedMessages = SMSHistoryPolicy.appendingSentMessage(
            recipient: recipient,
            content: content,
            at: .now,
            to: messages,
            limit: maxMessageCount
        )
        messages = updatedMessages
        if !historyStore.saveMessages(updatedMessages) {
            errorMessage = "短信已发送，但保存到本机失败，请稍后刷新确认"
        }
    }

    private func normalizedCallHistory(_ records: [CallRecord]) -> [CallRecord] {
        Array(records
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxCallHistoryCount))
    }

    private func normalizedMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        Array(records
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxMessageCount))
    }

    private func perform(
        allowWhileBusy: Bool = false,
        _ operation: () async throws -> Void
    ) async {
        guard LegacyRuntimeGate.allowed, allowWhileBusy || !isBusy else { return }
        activeOperationCount += 1
        isBusy = true
        defer {
            activeOperationCount -= 1
            isBusy = activeOperationCount > 0
        }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCallAudioIfReady() async {
        if WatchCallCoordinator.shared.ownsMedia(callID: activeCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: remoteCall?.id)
            || WatchCallCoordinator.shared.ownsMedia(callID: callLifecycleSnapshot.callID) {
            return
        }
        let managedByCallKit = callKit.managesCurrentCall
        let cloudSession = IPhoneCloudCallSession.shared
        if cloudSession.call != nil, cloudSession.answered {
            if CloudCallAudioStartupPolicy.shouldStart(
                answered: true,
                mediaPrepared: cloudSession.isPrepared,
                lifecycleState: cloudSession.lifecycleState,
                isOutgoing: cloudSession.call?.isOutgoing == true,
                managedByCallKit: managedByCallKit,
                callKitAudioSessionActive: callKit.audioSessionIsActive
            ) {
                backgroundStandby.suspendForCall()
                currentCallTransport = .cloud
                cloudSession.startAudioWithRetry()
            }
            return
        }
        guard !managedByCallKit || callKit.audioSessionIsActive else { return }
        guard callLifecycleSnapshot.state == .active, !audio.active, !startingCallAudio else { return }
        startingCallAudio = true
        defer { startingCallAudio = false }
        backgroundStandby.suspendForCall()

        do {
            guard let localAPI = reachableLocalAPI else {
                backgroundStandby.resumeAfterCall()
                errorMessage = "本地语音路由尚未锁定"
                return
            }
            let pcmRoute = currentPCMRoute ?? Self.pcmRoute(for: localAPI.route)
            // 先完成麦克风授权和 AVAudioEngine 启动，再让 Agent 开始等待 PCM
            // 客户端。否则首次授权停留超过 Agent 的等待窗口时，helper 会被提前杀死。
            let outcome = try await LocalCallAudioStartupCoordinator.start(
                activatePhoneAudio: { [audio] in
                    await audio.activateForCall(route: pcmRoute, sessionAlreadyActive: managedByCallKit)
                },
                registerAgentAudio: {
                    try await CallAudioRegistrationCoordinator.register(service: localAPI)
                },
                rollbackPhoneAudio: { [audio] in
                    audio.deactivate()
                    try? await localAPI.setAudioHostEnabled(false)
                }
            )
            guard outcome == .started else {
                backgroundStandby.resumeAfterCall()
                return
            }
            if currentCallTransport == nil {
                let transport: CallTransport
                switch localAPI.route {
                case .moduleLocal: transport = .moduleLocal
                case .vowlan: transport = .vowlan
                }
                lockLocalTransport(transport, api: localAPI, pcmRoute: pcmRoute)
            }
        } catch {
            audio.deactivate()
            if let localAPI = reachableLocalAPI {
                try? await localAPI.setAudioHostEnabled(false)
            }
            backgroundStandby.resumeAfterCall()
            errorMessage = "无法登记通话音频：\(error.localizedDescription)"
            return
        }
    }

    func readyVoWLANRoute() async -> (AirSIMAPI, PCMRoute)? {
        vowlan.startBrowsing()
        await vowlan.probeNow()
        if vowlan.availability.isReady(),
           let endpoint = vowlan.availability.endpoint,
           let credential = VoWLANCredentialStore.load() {
            return (
                AirSIMAPI(route: .vowlan(endpoint: endpoint, credential: credential)),
                .vowlan(endpoint: endpoint, credential: credential)
            )
        }
        // PushKit 可在后台先于 Bonjour 浏览器恢复。最近一次成功轮询若明确来自
        // VoWLAN，就复用同一已鉴权端点；绝不能把通用 isOnline 误当成 USB ECM。
        guard isOnline, !isReconnecting, let cached = lastSuccessfulLocalAPI,
              case let .vowlan(endpoint, credential) = cached.route else { return nil }
        return (cached, .vowlan(endpoint: endpoint, credential: credential))
    }

    private func lockLocalTransport(
        _ transport: CallTransport,
        api: AirSIMAPI,
        pcmRoute: PCMRoute
    ) {
        currentCallTransport = transport
        currentLocalAPI = api
        currentPCMRoute = pcmRoute
        lockedCallTransport = LockedCallTransport(
            transport: transport,
            generation: callLifecycleSnapshot.generation
        )
        // 取消仍绑定旧 USB 路由的长轮询，让 active 状态立即从 VoWLAN 返回。
        restartPolling()
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "call_transport", phase: "locked",
                title: transport == .vowlan ? "本通已锁定 VoWLAN" : "本通已锁定模块本地链路",
                fields: ["generation": String(callLifecycleSnapshot.generation)]
            )
        }
    }

    private func clearLockedTransport() {
        currentCallTransport = nil
        currentLocalAPI = nil
        currentPCMRoute = nil
        lockedCallTransport = nil
    }

    private func endVoWLANCallAfterPathLoss() async {
        guard currentCallTransport == .vowlan else { return }
        let localAPI = currentLocalAPI
        audio.deactivate()
        try? await localAPI?.hangupCall(callID: activeCall?.id)
        errorMessage = "VoWLAN 局域网已断开；当前通话已结束，下一通将自动选择云端"
        await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "ios", category: "call_transport", phase: "ended",
            title: "hotspot_lost_no_midcall_handover",
            detail: "VoWLAN 局域网路径丢失，结束当前通话；未迁移到云端",
            fields: ["generation": String(lockedCallTransport?.generation ?? 0)],
            isFailure: true
        )
        try? await callKit.endCurrentCall()
    }

    /// 仅允许电话网络常见字符，防止意外把 AT 控制字符传入模块代理。
    private static func validatedNumber(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard trimmed.count <= 82,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return trimmed
    }

    private static func remoteCallRecord(
        from incoming: IncomingVoIPCall,
        state: String,
        startedAt: Date = Date()
    ) -> CallRecord {
        CallRecord(
            id: incoming.callID,
            index: 0,
            direction: "incoming",
            state: state,
            number: incoming.number,
            startedAt: startedAt,
            updatedAt: Date(),
            endedAt: nil,
            missed: false
        )
    }

    private func updateRemoteCallState(_ state: String) {
        guard let incoming = callKit.currentIncomingPush else { return }
        remoteCall = Self.remoteCallRecord(
            from: incoming,
            state: state,
            startedAt: remoteCall?.startedAt ?? Date()
        )
    }

    @discardableResult
    private func applyCallLifecycle(_ event: CallLifecycleEvent) -> Bool {
        guard callLifecycleStore.apply(event) else { return false }
        callLifecycleSnapshot = callLifecycleStore.snapshot
        return true
    }

    private func applyCurrentCallIntent(_ state: CallLifecycleState, source: CallLifecycleSource) {
        guard let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID,
              callLifecycleSnapshot.generation > 0 else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID,
            callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: state,
            source: source,
            timestamp: Date(),
            traceID: "app-\(UUID().uuidString.lowercased())",
            failure: nil
        ))
    }

    @discardableResult
    private func applyAgentCallRecord(
        _ call: CallRecord,
        forcedState: CallLifecycleState? = nil
    ) -> Bool {
        let incoming = callKit.currentIncomingPush
        let sameSnapshot = callLifecycleSnapshot.callID == call.id
        let callUUID = (incoming?.callID == call.id ? incoming?.uuid : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.callUUID : nil)
            ?? callKit.watchCallUUID(for: call.id)
            ?? UUID()
        let generation = (incoming?.callID == call.id ? incoming?.generation : nil)
            ?? (sameSnapshot ? callLifecycleSnapshot.generation : nil)
            ?? max(1, callLifecycleSnapshot.generation &+ 1)
        let state = forcedState ?? Self.lifecycleState(for: call.state)
        return applyCallLifecycle(CallLifecycleEvent(
            callID: call.id,
            callUUID: callUUID,
            generation: generation,
            state: state,
            source: .agent,
            timestamp: call.updatedAt,
            traceID: "agent-poll-\(call.id)-\(generation)",
            failure: state == .failed ? "Agent 报告通话失败" : nil
        ))
    }

    private func lifecycleRecord(from record: CallRecord?) -> CallRecord? {
        guard let record,
              callLifecycleSnapshot.callID == record.id,
              callLifecycleSnapshot.state.representsCall else { return nil }
        return CallRecord(
            id: record.id,
            index: record.index,
            direction: record.direction,
            state: callLifecycleSnapshot.state.callRecordState,
            number: record.number,
            startedAt: record.startedAt,
            updatedAt: callLifecycleSnapshot.timestamp ?? record.updatedAt,
            endedAt: nil,
            missed: record.missed
        )
    }

    private static func lifecycleState(for agentState: String) -> CallLifecycleState {
        switch agentState {
        case "incoming", "waiting": return .ringing
        case "dialing", "alerting": return .connecting
        case "active", "held": return .active
        case "ending": return .ending
        case "ended": return .ended
        default: return .connecting
        }
    }
}

protocol OutgoingCallServicing: Sendable {
    func warmAudioHost() async throws
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func dial(number: String) async throws
}

extension AirSIMAPI: OutgoingCallServicing {}

protocol CallAudioRegistrationServicing: Sendable {
    func setAudioHostEnabled(_ enabled: Bool) async throws
    func callStatus() async throws -> CallStatus
}

extension AirSIMAPI: CallAudioRegistrationServicing {}

enum CallAudioRegistrationOutcome: Equatable, Sendable {
    case registered
    case callNoLongerActive
    case temporarilyUnavailable
}

enum CallAudioRegistrationCoordinator {
    static func register(
        service: any CallAudioRegistrationServicing,
        retryDelay: Duration = .milliseconds(250)
    ) async throws -> CallAudioRegistrationOutcome {
        do {
            try await service.setAudioHostEnabled(true)
            return .registered
        } catch APIError.http(409, _) {
            // 通话事件与媒体注册是两个请求。旧 Agent 在其间完成 CLCC 刷新时，
            // 重新读取状态，避免把短暂竞争当成致命拨号错误。
            let latest = try await service.callStatus()
            guard latest.active?.state == "active" else {
                return .callNoLongerActive
            }
            if retryDelay > .zero {
                try await Task.sleep(for: retryDelay)
            }
            do {
                try await service.setAudioHostEnabled(true)
                return .registered
            } catch APIError.http(409, _) {
                // 0.3.39 的 DSCI 与 CLCC 会在接通瞬间短暂交错。此时保持
                // CallKit 通话并交给下一轮事件重试，不能把媒体尚未就绪显示成拨号失败。
                return .temporarilyUnavailable
            }
        }
    }
}

enum LocalCallAudioStartupOutcome: Equatable, Sendable {
    case started
    case phoneAudioUnavailable
    case callNoLongerActive
    case temporarilyUnavailable
}

@MainActor
enum LocalCallAudioStartupCoordinator {
    static func start(
        activatePhoneAudio: () async -> Bool,
        registerAgentAudio: () async throws -> CallAudioRegistrationOutcome,
        rollbackPhoneAudio: () async -> Void
    ) async rethrows -> LocalCallAudioStartupOutcome {
        guard await activatePhoneAudio() else { return .phoneAudioUnavailable }
        do {
            switch try await registerAgentAudio() {
            case .registered:
                return .started
            case .callNoLongerActive:
                await rollbackPhoneAudio()
                return .callNoLongerActive
            case .temporarilyUnavailable:
                await rollbackPhoneAudio()
                return .temporarilyUnavailable
            }
        } catch {
            await rollbackPhoneAudio()
            throw error
        }
    }
}

enum OutgoingCommandAvailability {
    static func isAvailable(
        localControlReachable: Bool,
        cloudModeEnabled: Bool,
        cloudHeartbeatFresh: Bool
    ) -> Bool {
        localControlReachable || (cloudModeEnabled && cloudHeartbeatFresh)
    }
}

enum OutgoingCallCoordinator {
    static func start(number: String, service: any OutgoingCallServicing) async throws {
        try? await service.warmAudioHost()
        try await service.dial(number: number)
    }
}

enum OutgoingCallRouteResult<CloudResult: Sendable>: Sendable {
    case vowlan
    case cloud(CloudResult)
}

extension OutgoingCallRouteResult: Equatable where CloudResult: Equatable {}

enum OutgoingCallFallbackPolicy {
    static func permitsCloudFallback(after error: Error, cloudModeEnabled: Bool) -> Bool {
        guard cloudModeEnabled, !(error is CancellationError) else { return false }
        // 收到 Agent HTTP 响应说明命令已到达执行边界。拨号是非幂等操作，
        // 明确拒绝或返回业务错误时不能再经 Relay 重放。
        if error is APIError { return false }
        return true
    }
}

@MainActor
enum OutgoingCallRouteCoordinator {
    static func start<CloudResult: Sendable>(
        number: String,
        vowlanService: (any OutgoingCallServicing)?,
        cloudModeEnabled: Bool,
        startCloud: () async throws -> CloudResult
    ) async throws -> OutgoingCallRouteResult<CloudResult> {
        if let vowlanService {
            do {
                try await OutgoingCallCoordinator.start(number: number, service: vowlanService)
                return .vowlan
            } catch {
                guard OutgoingCallFallbackPolicy.permitsCloudFallback(
                    after: error,
                    cloudModeEnabled: cloudModeEnabled
                ) else {
                    throw error
                }
            }
        } else if !cloudModeEnabled {
            throw CloudCommandError.cloudModeDisabled
        }

        return .cloud(try await startCloud())
    }
}

enum AgentPollingRouteSelector {
    static func select<Service>(
        primary: Service,
        lockedLocal: Service?,
        transport: CallTransport?
    ) -> Service {
        if transport == .vowlan, let lockedLocal { return lockedLocal }
        return primary
    }
}

enum CallKitAudioPreparationCoordinator {
    static func prepare(
        suspendStandby: () -> Void,
        configureCallAudio: () throws -> Void,
        resumeStandby: () -> Void
    ) throws {
        suspendStandby()
        do {
            try configureCallAudio()
        } catch {
            resumeStandby()
            throw error
        }
    }
}

extension AppModel: CallKitActionHandling {
    func callKitPrepareAudioSession() throws {
        try CallKitAudioPreparationCoordinator.prepare(
            suspendStandby: { backgroundStandby.suspendForCall() },
            configureCallAudio: { try audio.prepareForCallKit() },
            resumeStandby: { backgroundStandby.resumeAfterCall() }
        )
    }

    func callKitStart(number: String) async throws {
        beginCallTransitionProtection()
        if callPresentationSurface == nil { callPresentationSurface = .system }
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            let vowlanRoute = await readyVoWLANRoute()
            let cloudModeEnabled = CloudModePreference.isEnabled()
            let routeResult = try await OutgoingCallRouteCoordinator.start(
                number: number,
                vowlanService: vowlanRoute?.0,
                cloudModeEnabled: cloudModeEnabled
            ) {
                // Dialing is an explicit event: check once immediately before cloud routing.
                let status = try await VoIPPushController.shared.fetchCloudAgentStatus()
                self.cloudAgentStatus = status
                self.cloudAgentDirectory = status
                self.lastCloudStatusRefresh = Date()
                guard status.cloudOnline else { throw CloudCommandError.unavailable }
                return try await VoIPPushController.shared.startCloudOutgoingCall(number: number)
            }

            switch routeResult {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CloudCommandError.unavailable
                }
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case let .cloud(outgoing):
                _ = applyCallLifecycle(CallLifecycleEvent(
                    callID: outgoing.callID, callUUID: outgoing.uuid,
                    generation: outgoing.generation, state: .connecting, source: .callKit,
                    timestamp: Date(), traceID: "callkit-start-\(outgoing.uuid.uuidString.lowercased())",
                    failure: nil
                ))
                try await IPhoneCloudCallSession.shared.answer(outgoing)
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                remoteCall = CallRecord(
                    id: outgoing.callID, index: 0, direction: "outgoing", state: "dialing",
                    number: number, startedAt: Date(), updatedAt: Date(), endedAt: nil, missed: false
                )
                pendingOutgoingCall = nil
                await startCallAudioIfReady()
            }
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitAnswer(origin: CallAnswerOrigin) async throws {
        beginCallTransitionProtection()
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        audio.resetSpeakerPreferenceForNewCall()
        callPresentationSurface = origin == .app ? .app : .system
        applyCurrentCallIntent(.connecting, source: origin == .app ? .app : .callKit)
        if origin == .system { _ = IncomingCallPresentationRequest.consume() }
        do {
            let pushedCall = callKit.currentIncomingPush
            if let pushedCall, pushedCall.isVirtual {
                try VirtualCallTTSController.shared.prepare(pushedCall)
                clearLockedTransport()
                updateRemoteCallState("active")
                return
            }
            let cloudMediaEnabled = CloudModePreference.isEnabled()
            let vowlanRoute = await readyVoWLANRoute()
            let moduleLocalReachable = false
            let transport = CallTransportPolicy.preferred(
                vowlanReady: vowlanRoute != nil,
                moduleLocalReachable: moduleLocalReachable,
                cloudMediaAvailable: pushedCall?.authenticatedMediaURL != nil,
                cloudMediaEnabled: cloudMediaEnabled
            )
            switch transport {
            case .vowlan:
                guard let (vowlanAPI, pcmRoute) = vowlanRoute else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try audio.prepareForCallKit()
                try await vowlanAPI.answerCall(callID: activeCall?.id)
                lockLocalTransport(.vowlan, api: vowlanAPI, pcmRoute: pcmRoute)
            case .moduleLocal:
                throw CallKitBridgeError.noReachableTransport
            case .cloud:
                guard let pushedCall else { throw CallKitBridgeError.noReachableTransport }
                try await IPhoneCloudCallSession.shared.answer(pushedCall)
                currentLocalAPI = nil
                currentPCMRoute = nil
                currentCallTransport = .cloud
                lockedCallTransport = LockedCallTransport(
                    transport: .cloud, generation: callLifecycleSnapshot.generation
                )
                await startCallAudioIfReady()
            case nil:
                if !moduleLocalReachable,
                   !cloudMediaEnabled,
                   pushedCall?.authenticatedMediaURL != nil {
                    throw CallKitBridgeError.cloudMediaDisabled
                }
                throw CallKitBridgeError.noReachableTransport
            }
            await CallAnswerCompletionCoordinator.complete(
                transport: currentCallTransport,
                confirmActive: {
                    self.applyCurrentCallIntent(
                        .active,
                        source: origin == .app ? .app : .callKit
                    )
                    self.updateRemoteCallState("active")
                },
                startAudio: { await self.startCallAudioIfReady() }
            )
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitEnd() async throws {
        beginCallTransitionProtection()
        audio.stopCallTone()
        let pushedCall = callKit.currentIncomingPush
        let endRoute = CallKitEndDecision.route(
            transport: currentCallTransport,
            cloudSessionPrepared: IPhoneCloudCallSession.shared.isPrepared,
            hasIncomingPush: pushedCall != nil,
            systemCallAnswered: callKit.currentCallIsAnswered,
            activeIncomingRinging: activeCall?.direction == "incoming"
                && ["incoming", "waiting"].contains(activeCall?.state ?? "")
        )
        applyCurrentCallIntent(.ending, source: .callKit)
        if VirtualCallTTSController.shared.isPrepared || callKit.currentIncomingPush?.isVirtual == true {
            VirtualCallTTSController.shared.stop()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudReject, let pushedCall {
            try await IPhoneCloudCallSession.shared.reject(pushedCall)
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .cloudEnd {
            await IPhoneCloudCallSession.shared.end()
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .vowlan,
           case .unavailable = vowlan.availability {
            // 三星端在热点接口消失时直接通过 Telecom 结束所属通话；这里让
            // CallKit 事务立即成功，避免因已断开的控制 socket 把系统界面卡住。
            clearLockedTransport()
            backgroundStandby.resumeAfterCall()
            return
        }
        if endRoute == .localReject {
            do {
                guard let localAPI = localCallControlAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                _ = try await localAPI.rejectCall(callID: activeCall?.id)
            } catch {
                guard let pushedCall else { throw error }
                try await IPhoneCloudCallSession.shared.reject(pushedCall)
            }
        } else {
            guard let localAPI = localCallControlAPI else {
                throw CallKitBridgeError.noReachableTransport
            }
            try await localAPI.hangupCall(callID: activeCall?.id)
        }
    }

    func callKitSetMuted(_ muted: Bool) async {
        isMuted = muted
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.setMuted(muted)
            errorMessage = nil
            return
        }
        audio.setMuted(muted)
        IPhoneCloudCallSession.shared.setMuted(muted)
        // CallKit 的静音动作直接作用于本地 PCM 编码器；模块 AT+CMUT 失败不应影响双向音频。
        if currentCallTransport != .cloud {
            if let localAPI = reachableLocalAPI {
                Task { try? await localAPI.setAudioMuted(muted) }
            }
        }
        errorMessage = nil
    }

    func callKitPlayDTMF(_ digits: String) async throws {
        if VirtualCallTTSController.shared.isPrepared { return }
        for digit in digits where "0123456789*#".contains(digit) {
            if currentCallTransport == .cloud {
                try await VoIPPushController.shared.sendCloudDTMF(String(digit))
            } else {
                guard let localAPI = reachableLocalAPI else {
                    throw CallKitBridgeError.noReachableTransport
                }
                try await localAPI.sendDTMF(String(digit))
            }
        }
    }

    func callKitAudioSessionDidActivate() async {
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.start()
            return
        }
        await startCallAudioIfReady()
    }

    func callKitAudioSessionDidDeactivate() {
        beginCallTransitionProtection()
        if VirtualCallTTSController.shared.isPrepared {
            VirtualCallTTSController.shared.stop()
            backgroundStandby.resumeAfterCall()
            return
        }
        if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
            return
        }
        audio.deactivate()
        audioWarmupCallID = nil
        backgroundStandby.resumeAfterCall()
    }

    func callKitProviderDidReset() async {
        beginCallTransitionProtection()
        // CXProvider reset 只代表系统通话界面失效，绝不等于用户挂断真实模块通话。
        // 清理本地音频后交给下一轮状态同步按 App 内通话模式自动恢复。
        let wasVirtual = VirtualCallTTSController.shared.isPrepared
        if wasVirtual {
            VirtualCallTTSController.shared.stop()
        } else if currentCallTransport == .cloud || IPhoneCloudCallSession.shared.isPrepared {
            IPhoneCloudCallSession.shared.stopAudio()
        } else {
            audio.deactivate()
        }
        if !callLifecycleSnapshot.state.representsCall { backgroundStandby.resumeAfterCall() }
    }

    func callKitDidFail(_ message: String) {
        errorMessage = message
        pendingOutgoingCall = nil
        guard callLifecycleSnapshot.state == .ending,
              let callID = callLifecycleSnapshot.callID,
              let callUUID = callLifecycleSnapshot.callUUID else { return }
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: callID, callUUID: callUUID,
            generation: callLifecycleSnapshot.generation,
            state: .failed, source: .callKit, timestamp: Date(),
            traceID: "callkit-failure-\(UUID().uuidString.lowercased())",
            failure: message
        ))
    }

    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {
        vowlan.startBrowsing()
        Task { await vowlan.probeNow() }
        remoteCall = Self.remoteCallRecord(from: call, state: "incoming")
        _ = applyCallLifecycle(CallLifecycleEvent(
            callID: call.callID, callUUID: call.uuid, generation: call.generation,
            state: .ringing, source: .relay, timestamp: Date(),
            traceID: "pushkit-\(call.uuid.uuidString.lowercased())", failure: nil
        ))
        // 后台 PushKit 来电由系统界面接管；只有 App 本来就在前台时才准备 App 内来电页。
        callPresentationSurface = appIsActive ? .app : .system
    }

    func callKitCallDidEnd() {
        // 远端挂断、系统通话页挂断以及 Provider 主动结束都会走这里。
        // Agent 已拥有唯一的通话结束媒体清理权；App 不再重复关闭 Audio Host。
        beginCallTransitionProtection()
        // CallKit 本地 UI 已结束不等于模块已挂机；最终 ended/failed 只能由 Agent/Relay 回执推进。
        applyCurrentCallIntent(.ending, source: .callKit)
        remoteCall = nil
        pendingOutgoingCall = nil
        callPresentationSurface = nil
        clearLockedTransport()
        cloudCallAudioState = .idle
        IPhoneCloudCallSession.shared.stop()
        VirtualCallTTSController.shared.stop()
        backgroundStandby.resumeAfterCall()
    }
}

private enum ModuleSetupError: LocalizedError {
    case notReady(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case let .notReady(message): return message
        case .timeout: return "模块重启后未重新上线，请重新插拔 USB 线"
        }
    }
}
