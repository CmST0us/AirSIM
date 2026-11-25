import AVFoundation
import CallKit
import Foundation
import UIKit

/// 把系统 CallKit 操作转发给模块控制层，协议限定在主线程以保护 AppModel 状态。
@MainActor
protocol CallKitActionHandling: AnyObject {
    func callKitPrepareAudioSession() throws
    func callKitStart(number: String) async throws
    func callKitAnswer(origin: CallAnswerOrigin) async throws
    func callKitEnd() async throws
    func callKitSetMuted(_ muted: Bool) async
    func callKitPlayDTMF(_ digits: String) async throws
    func callKitAudioSessionDidActivate() async
    func callKitAudioSessionDidDeactivate()
    func callKitProviderDidReset() async
    func callKitDidFail(_ message: String)
    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall)
    func callKitCallDidEnd()
}

enum CallAnswerOrigin: Equatable, Sendable {
    case system
    case app
}

/// CallKit 的系统事务必须先于慢速 Agent/Relay I/O 完成，系统才会及时激活
/// AVAudioSession。后端错误单独返回，由调用方结束已建立的系统通话。
enum CallKitActionCoordinator {
    static func perform(
        prepare: () throws -> Void,
        fulfill: () -> Void,
        backend: () async throws -> Void
    ) async throws -> Error? {
        try prepare()
        fulfill()
        do {
            try await backend()
            return nil
        } catch {
            return error
        }
    }
}

enum CallKitEndActionPolicy {
    static func shouldForwardToBackend(systemCallWasCurrent: Bool) -> Bool {
        systemCallWasCurrent
    }
}

extension CallKitActionHandling {
    func callKitPrepareAudioSession() throws {}
    func callKitDidReceiveIncoming(_ call: IncomingVoIPCall) {}
    func callKitCallDidEnd() {}
}

/// 挂断后 PushKit、USB 长轮询与系统回调可能乱序到达。短期保留已经结束的
/// call_id/UUID，避免同一通电话在 CallKit 关闭后被晚到事件重新拉起。
struct IncomingCallDeduplicator {
    let retention: TimeInterval
    private var endedCallIDs: [String: Date] = [:]
    private var endedUUIDs: [UUID: Date] = [:]

    init(retention: TimeInterval = 90) {
        self.retention = retention
    }

    mutating func recordEnded(callID: String?, uuid: UUID?, at date: Date = Date()) {
        purgeExpired(now: date)
        if let callID, !callID.isEmpty { endedCallIDs[callID] = date }
        if let uuid { endedUUIDs[uuid] = date }
    }

    mutating func shouldAccept(callID: String?, uuid: UUID?, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        if let callID, endedCallIDs[callID] != nil { return false }
        if let uuid, endedUUIDs[uuid] != nil { return false }
        return true
    }

    private mutating func purgeExpired(now: Date) {
        endedCallIDs = endedCallIDs.filter { now.timeIntervalSince($0.value) <= retention }
        endedUUIDs = endedUUIDs.filter { now.timeIntervalSince($0.value) <= retention }
    }
}

final class SystemCallActionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    func advance() { lock.lock(); epoch &+= 1; lock.unlock() }
    func accepts(_ value: UInt64) -> Bool { generation == value }
}

/// 维护模块通话与系统通话 UUID 的一一映射，并承接锁屏与系统通话界面的操作。
@MainActor
final class CallKitController: NSObject {
    static let shared = CallKitController()

    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var audioSessionIsActive = false
    private var entitlementAvailable = true
    private var featureEnabled = !LocalModePreference.isEnabled()
    weak var handler: (any CallKitActionHandling)? { didSet { actionGate.advance() } }
    private nonisolated let actionGate = SystemCallActionGate()
    private func acceptsAction(_ stamp: UInt64) -> Bool {
        actionGate.accepts(stamp) && isAvailable && handler != nil && (handler is V2SystemCallController || LegacyRuntimeGate.allowed)
    }

    private var currentUUID: UUID? { didSet { if oldValue != currentUUID { actionGate.advance() } } }
    private var currentBackendID: String?
    private var currentState: String?
    private var currentNumber: String?
    private var currentCallerName: String?
    private var currentDirection: String?
    private var incomingReportRequested = false
    private var incomingReportFailed = false
    private var systemCallReported = false
    private var endActionFulfilled = false
    private var endingActionUUID: UUID?
    private var dtmfQueue: [String] = []
    private var dtmfDrainTask: Task<Void, Never>?
    private var missingCallPolls = 0
    private var outgoingStartInFlight = false
    private var handledOutgoingActions: Set<ObjectIdentifier> = []
    private var dialedOutgoingUUIDs: Set<UUID> = []
    private var appAnswerRequestUUID: UUID?
    private var adoptingUUID: UUID?
    private var incomingReportCompletions: [(Error?) -> Void] = []
    private var incomingDeduplicator = IncomingCallDeduplicator()
    private(set) var currentIncomingPush: IncomingVoIPCall?

    override convenience init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = true
        self.init(configuration: configuration)
    }

    init(configuration: CXProviderConfiguration) {
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit {
        provider.invalidate()
    }

    var isAvailable: Bool { entitlementAvailable && featureEnabled }

    func setEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        actionGate.advance()
        guard !enabled else { return }
        if let uuid = currentUUID, systemCallReported {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        audioSessionIsActive = false
        resetCurrentCall()
#if DEBUG
        debugLog("本地模式已关闭 CallKit")
#endif
    }

    var managesCurrentCall: Bool {
        isAvailable && currentUUID != nil && (systemCallReported || currentDirection == "outgoing")
    }

    var currentCallIsAnswered: Bool {
        ["active", "held"].contains(currentState)
    }

    /// 只公开不可变身份，生命周期状态由 CallLifecycleStore 统一管理。
    var currentSystemCallUUID: UUID? { currentUUID }

    var suppressesInAppIncomingRingtone: Bool {
        incomingReportRequested && !incomingReportFailed
    }

    func watchCallUUID(for backendID: String?) -> UUID? {
        guard backendID == nil || backendID == currentBackendID else { return nil }
        return currentUUID
    }

    func matchesCurrentCall(callID: String?, uuid: UUID?) -> Bool {
        guard currentUUID != nil else { return false }
        let backendMatches = callID == nil || callID == currentBackendID
        let uuidMatches = uuid == nil || uuid == currentUUID
        return backendMatches && uuidMatches
    }

    /// 配对设备接管同一通电话后，立即结束本机 CallKit，避免双端同时响铃或抢占媒体。
    func reportCurrentCallEnded(reason: CXCallEndedReason) {
        finishCurrentCall(previous: nil, reason: reason)
    }

    func reportCurrentOutgoingConnected() {
        guard currentDirection == "outgoing", let uuid = currentUUID,
              currentState != "active", systemCallReported else { return }
        currentState = "active"
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// PushKit 冷启动必须立即把同一通真实来电交给系统。后续 USB 状态同步会复用
    /// call_id/UUID，不会再生成第二个系统来电。
    func reportIncomingPush(
        _ call: IncomingVoIPCall,
        callerName: String? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        let resolvedName = callerName ?? call.callerName
        guard isAvailable else {
            completion(CallKitBridgeError.unavailable)
            return
        }
        guard incomingDeduplicator.shouldAccept(callID: call.callID, uuid: call.uuid) else {
            debugLog("忽略已结束通话的晚到 PushKit 事件")
            completion(nil)
            return
        }
        // 模块在响铃期间重建通话对象会得到新的 call_id；未接听的 v2 来电由新推送接替，
        // 不保留已失效的旧 call_id。
        if currentUUID != nil, call.v2Push != nil, currentDirection == "incoming",
           ["incoming", "ringing", "waiting"].contains(currentState ?? ""),
           !call.matches(backendID: currentBackendID, uuid: currentUUID) {
            finishCurrentCall(previous: nil, reason: .unanswered)
        }
        if currentUUID != nil {
            guard call.matches(backendID: currentBackendID, uuid: currentUUID) else {
                completion(CallKitBridgeError.callInProgress)
                return
            }
            currentIncomingPush = call
            currentBackendID = call.callID
            currentNumber = call.number ?? currentNumber
            if let resolvedName, !resolvedName.isEmpty, resolvedName != currentCallerName {
                currentCallerName = resolvedName
                if systemCallReported, let uuid = currentUUID {
                    provider.reportCall(with: uuid, updated: update(number: currentNumber, callerName: resolvedName))
                }
            }
            if systemCallReported {
                handler?.callKitDidReceiveIncoming(call)
                completion(nil)
                return
            }
            incomingReportCompletions.append(completion)
            reportIncomingIfNeeded(number: currentNumber, callerName: currentCallerName, source: "PushKit 重投")
            handler?.callKitDidReceiveIncoming(call)
            return
        }

        currentUUID = call.uuid
        currentBackendID = call.callID
        currentIncomingPush = call
        currentDirection = "incoming"
        currentState = "incoming"
        currentNumber = call.number
        currentCallerName = resolvedName
        missingCallPolls = 0
        endActionFulfilled = false
        incomingReportCompletions.append(completion)
        reportIncomingIfNeeded(number: call.number, callerName: resolvedName, source: "PushKit")
        handler?.callKitDidReceiveIncoming(call)
    }

    /// 先让系统接管呼出事务；真正的模块 ATD 只能在 CXProvider delegate 回调中执行。
    func startOutgoingCall(number: String, callerName: String? = nil) async throws {
        guard isAvailable else { throw CallKitBridgeError.unavailable }
        guard currentUUID == nil else { throw CallKitBridgeError.callInProgress }

        let uuid = UUID()
        currentUUID = uuid
        currentDirection = "outgoing"
        currentNumber = number
        currentCallerName = callerName
        currentState = "dialing"
        missingCallPolls = 0
        endActionFulfilled = false

        do {
            let handle = CXHandle(type: .phoneNumber, value: number)
            let action = CXStartCallAction(call: uuid, handle: handle)
            if let callerName, !callerName.isEmpty, callerName != number {
                action.contactIdentifier = callerName
            }
            try await request(action)
        } catch {
            let unavailable = disableCallKitIfUnentitled(error)
            resetCurrentCall()
            if unavailable { throw CallKitBridgeError.unavailable }
            throw error
        }
    }

    /// Puts a call the App answered in its own interface under CallKit, so the
    /// system presents it once the App leaves the foreground. The App starts the
    /// transaction itself, so no system call interface covers it.
    func adoptAnsweredCall(callID: String, number: String?) async throws {
        guard isAvailable else { throw CallKitBridgeError.unavailable }
        guard currentUUID == nil else { throw CallKitBridgeError.callInProgress }
        let uuid = UUID()
        currentUUID = uuid
        currentDirection = "incoming"
        currentBackendID = callID
        currentNumber = number
        currentState = "active"
        missingCallPolls = 0
        endActionFulfilled = false
        adoptingUUID = uuid
        do {
            let handle = number.map { CXHandle(type: .phoneNumber, value: $0) } ?? CXHandle(type: .generic, value: "未知号码")
            try await request(CXStartCallAction(call: uuid, handle: handle))
        } catch {
            adoptingUUID = nil
            let unavailable = disableCallKitIfUnentitled(error)
            if currentUUID == uuid { resetCurrentCall() }
            if unavailable { throw CallKitBridgeError.unavailable }
            throw error
        }
    }

    func answerCurrentCall(presentInApp: Bool = false) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        if presentInApp { appAnswerRequestUUID = uuid }
        do {
            try await requestSystemAction(CXAnswerCallAction(call: uuid))
        } catch {
            if appAnswerRequestUUID == uuid { appAnswerRequestUUID = nil }
            throw error
        }
    }

    func endCurrentCall() async throws {
        guard let uuid = currentUUID, systemCallReported || currentDirection == "outgoing" else {
            throw CallKitBridgeError.noSystemCall
        }
        if endActionFulfilled || endingActionUUID == uuid { return }
        debugLog("requesting end action from app")
        try await requestSystemAction(CXEndCallAction(call: uuid))
    }

    func setMuted(_ muted: Bool) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXSetMutedCallAction(call: uuid, muted: muted))
    }

    /// App 内键盘也走 CallKit 事务，保证系统通话页和 App 页不会各自维护一套 DTMF 状态。
    func playDTMF(_ digits: String) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        let validDigits = digits.filter { "0123456789ABCD*#".contains($0) }
        guard !validDigits.isEmpty else { return }
        try await requestSystemAction(
            CXPlayDTMFCallAction(call: uuid, digits: validDigits, type: .singleTone)
        )
    }

    /// 每次模块轮询后把呼入与呼出生命周期同步给系统。
    func synchronize(call: CallRecord?, previous: CallRecord?, callerName: String?) {
        // CallKit 权限被系统拒绝后只保留 App 内状态机，不能继续伪造系统通话 UUID。
        guard isAvailable else {
            if call == nil { resetCurrentCall() }
            return
        }
        guard let call else {
            // 模块已把同一 ID 写入带 ended_at 的 history，这是明确的结束事件，
            // 必须立即关闭系统通话，不再等待空 CLCC 防抖。
            if previous?.endedAt != nil {
                finishCurrentCall(previous: previous)
                return
            }
            // AT+CLCC 偶发空响应不等于电话已挂断；保留 UUID，避免系统扬声器/静音事务变成未知 UUID。
            if currentUUID != nil, systemCallReported || currentDirection == "outgoing" {
                missingCallPolls += 1
                guard missingCallPolls >= 3 else { return }
            }
            finishCurrentCall(previous: previous)
            return
        }

        // CXEndCallAction 已 fulfill 且正在等待后端 call.hangup 完成，不再把这通
        // 正在挂断的通话重新同步回 CallKit。
        if endActionFulfilled, currentUUID != nil,
           currentBackendID == nil || currentBackendID == call.id {
            return
        }

        if call.direction == "outgoing" {
            // 只同步由 startOutgoingCall 建立的系统呼出；不为外部 ATD 伪造 UUID。
            guard currentDirection == "outgoing", let uuid = currentUUID else { return }
            if let backendID = currentBackendID, backendID != call.id {
                finishCurrentCall(previous: previous, reason: .failed)
                return
            }
            currentBackendID = call.id
            currentNumber = call.number ?? currentNumber
            if let callerName, !callerName.isEmpty, callerName != currentCallerName {
                currentCallerName = callerName
                if systemCallReported {
                    provider.reportCall(with: uuid, updated: update(number: currentNumber, callerName: callerName))
                }
            }
            missingCallPolls = 0
            if call.state == "active", currentState != "active", systemCallReported {
                provider.reportOutgoingCall(with: uuid, connectedAt: call.updatedAt)
            }
            currentState = call.state
            return
        }

        if currentDirection == "outgoing" {
            finishCurrentCall(previous: previous, reason: .failed)
        }

        missingCallPolls = 0
        outgoingStartInFlight = false

        if let backendID = currentBackendID, backendID != call.id {
            finishCurrentCall(previous: previous, reason: .failed)
        }
        if currentUUID == nil,
           !incomingDeduplicator.shouldAccept(callID: call.id, uuid: nil) {
            debugLog("忽略已结束通话的晚到模块状态")
            return
        }
        if currentUUID == nil { currentUUID = UUID() }
        currentDirection = "incoming"
        currentBackendID = call.id
        currentNumber = call.number
        if let callerName, !callerName.isEmpty, callerName != currentCallerName {
            currentCallerName = callerName
            if systemCallReported, let uuid = currentUUID {
                provider.reportCall(with: uuid, updated: update(number: currentNumber, callerName: callerName))
            }
        }

        if ["incoming", "waiting"].contains(call.state) {
            reportIncomingIfNeeded(number: call.number, callerName: currentCallerName ?? callerName, source: "模块状态")
        }
        currentState = call.state
    }

    private func reportIncomingIfNeeded(number: String?, callerName: String?, source: String) {
        guard !incomingReportRequested, !systemCallReported, let uuid = currentUUID else { return }
        incomingReportRequested = true
        let stamp = actionGate.generation
        let originalCompletions = incomingReportCompletions
        incomingReportCompletions.removeAll()
        debugLog("请求系统来电界面；来源=\(source)")
        provider.reportNewIncomingCall(
            with: uuid,
            update: update(number: number, callerName: callerName)
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.currentUUID == uuid, self.actionGate.accepts(stamp) else {
                    originalCompletions.forEach { $0(CallKitBridgeError.staleSystemCall) }
                    return
                }
                defer { originalCompletions.forEach { $0(error) } }
                if let error {
                    let diagnosticError = error as NSError
                    self.debugLog(
                        "系统来电上报失败；domain=\(diagnosticError.domain) code=\(diagnosticError.code) "
                            + "message=\(diagnosticError.localizedDescription)"
                    )
                    if self.disableCallKitIfUnentitled(error) {
                        self.finishIncomingReport(error)
                        self.resetCurrentCall()
                        return
                    }
                    self.systemCallReported = false
                    self.incomingReportFailed = true
                    self.handler?.callKitDidFail("系统来电界面启动失败：\(error.localizedDescription)")
                    self.finishIncomingReport(error)
                } else {
                    self.debugLog("系统来电上报成功")
                    self.systemCallReported = true
                    self.finishIncomingReport(nil)
                }
            }
        }
    }

    private func finishIncomingReport(_ error: Error?) {
        let completions = incomingReportCompletions
        incomingReportCompletions.removeAll()
        completions.forEach { $0(error) }
    }

    private func finishCurrentCall(
        previous: CallRecord?,
        reason explicitReason: CXCallEndedReason? = nil
    ) {
        guard let uuid = currentUUID else { return }
        if systemCallReported, !endActionFulfilled {
            let reason = explicitReason ?? endedReason(for: previous)
            provider.reportCall(with: uuid, endedAt: previous?.endedAt ?? Date(), reason: reason)
        }
        incomingDeduplicator.recordEnded(
            callID: currentBackendID ?? previous?.id,
            uuid: uuid,
            at: previous?.endedAt ?? Date()
        )
        handler?.callKitCallDidEnd()
        resetCurrentCall()
    }

    private func endedReason(for call: CallRecord?) -> CXCallEndedReason {
        guard let call else { return .failed }
        return call.state == "active" || call.state == "held" ? .remoteEnded : .unanswered
    }

    private func update(number: String?, callerName: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        let hasNumber = number?.isEmpty == false
        update.remoteHandle = CXHandle(type: hasNumber ? .phoneNumber : .generic, value: hasNumber ? number! : "未知号码")
        if let callerName, !callerName.isEmpty, callerName != number {
            update.localizedCallerName = callerName
        }
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        update.hasVideo = false
        return update
    }

    private func request(_ action: CXAction) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            callController.request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// CallKit 可能在系统界面重建期间短暂丢失 UUID；转换成业务层可恢复错误，
    /// 不让错误 4 直接传播成“通话已结束”。
    private func requestSystemAction(_ action: CXAction) async throws {
        do {
            try await request(action)
        } catch {
            let nsError = error as NSError
            if nsError.domain == CXErrorDomainRequestTransaction,
               nsError.code == CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue {
                throw CallKitBridgeError.staleSystemCall
            }
            throw error
        }
    }

    /// 个人签名或受限设备可能返回 requesttransaction/unentitled；此时自动使用 App 内通话。
    private func disableCallKitIfUnentitled(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CXErrorDomainRequestTransaction,
              error.code == CXErrorCodeRequestTransactionError.Code.unentitled.rawValue else {
            return false
        }
        entitlementAvailable = false
        audioSessionIsActive = false
        debugLog("CallKit 被系统判定为无权限，已降级到 App 内通话")
        return true
    }

    /// 真机联调只记录状态与系统错误码，避免把电话号码写入设备日志。
    private func debugLog(_ message: String) {
#if DEBUG
        NSLog("[AirSIM CallKit] %@", message)
#endif
    }

    private func resetCurrentCall() {
        if !incomingReportCompletions.isEmpty {
            finishIncomingReport(CallKitBridgeError.staleSystemCall)
        }
        currentUUID = nil
        currentBackendID = nil
        currentState = nil
        currentNumber = nil
        currentCallerName = nil
        currentDirection = nil
        currentIncomingPush = nil
        incomingReportRequested = false
        incomingReportFailed = false
        systemCallReported = false
        endActionFulfilled = false
        endingActionUUID = nil
        dtmfQueue.removeAll()
        dtmfDrainTask?.cancel()
        dtmfDrainTask = nil
        missingCallPolls = 0
        outgoingStartInFlight = false
        appAnswerRequestUUID = nil
        adoptingUUID = nil
    }

    private func beginCallControlBackgroundTask(name: String) -> UIBackgroundTaskIdentifier {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            guard taskID != .invalid else { return }
            let expiring = taskID
            taskID = .invalid
            UIApplication.shared.endBackgroundTask(expiring)
        }
        return taskID
    }

    private func endCallControlBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func fail(_ action: CXAction, error: Error) {
        let diagnostic = error as NSError
        debugLog("system action failed domain=\(diagnostic.domain) code=\(diagnostic.code)")
        action.fail()
        handler?.callKitDidFail(error.localizedDescription)
    }

    private func beginPerformAnswer(_ action: CXAnswerCallAction) {
        debugLog("performing answer action")
        guard currentUUID == action.callUUID else {
            fail(action, error: CallKitBridgeError.staleSystemCall)
            return
        }
        guard let handler else {
            fail(action, error: CallKitBridgeError.handlerUnavailable)
            return
        }
        let origin: CallAnswerOrigin = appAnswerRequestUUID == action.callUUID ? .app : .system
        appAnswerRequestUUID = nil
        do {
            try handler.callKitPrepareAudioSession()
        } catch {
            if handler is V2SystemCallController {
                debugLog("v2 answer audio session prepare warning code=\((error as NSError).code)")
            } else {
                fail(action, error: error)
                return
            }
        }
        currentState = "connecting"
        // 系统事务只确认“用户接受了接听”。公网控制、ATA 和 WebRTC 音频在其后异步建立，
        // 同步 fulfill 让 CallKit 立即进入接通界面并激活 AVAudioSession。
        action.fulfill()
        let callUUID = action.callUUID
        let backgroundTaskID = beginCallControlBackgroundTask(name: "AirSIMCallAnswer")
        Task { @MainActor [weak self] in
            defer { self?.endCallControlBackgroundTask(backgroundTaskID) }
            guard let self else { return }
            do {
                try await handler.callKitAnswer(origin: origin)
            } catch {
                guard self.currentUUID == callUUID, self.handler === handler,
                      self.endingActionUUID != callUUID else { return }
                let diagnostic = error as NSError
                self.debugLog("backend action failed domain=\(diagnostic.domain) code=\(diagnostic.code)")
                self.finishCurrentCall(previous: nil, reason: .failed)
                handler.callKitDidFail(error.localizedDescription)
            }
        }
    }

    private func performStart(_ action: CXStartCallAction) async {
        if action.isComplete { return }
        if action.callUUID == adoptingUUID, currentUUID == action.callUUID {
            // The call is already connected on the module; nothing is dialed.
            adoptingUUID = nil
            do { try handler?.callKitPrepareAudioSession() } catch { debugLog("adopted call audio session not prepared") }
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            systemCallReported = true
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
            return
        }
        let actionIdentity = ObjectIdentifier(action)
        guard handledOutgoingActions.insert(actionIdentity).inserted else { return }
        if dialedOutgoingUUIDs.contains(action.callUUID) {
            action.fulfill()
            return
        }
        if outgoingStartInFlight { return }
        if systemCallReported, currentUUID == action.callUUID, currentDirection == "outgoing" {
            action.fulfill()
            return
        }
        outgoingStartInFlight = true
        defer { outgoingStartInFlight = false }
        do {
            debugLog("starting outgoing transaction")
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            // 除了 App 内提交的事务，系统也可能通过 Siri/联系人把呼出动作
            // 直接交给 provider；此时以系统 UUID 建立同一套状态。
            if currentUUID == nil {
                currentUUID = action.callUUID
                currentDirection = "outgoing"
                currentNumber = action.handle.value
                currentCallerName = action.contactIdentifier
                currentState = "dialing"
            }
            guard currentUUID == action.callUUID, currentDirection == "outgoing" else {
                throw CallKitBridgeError.staleSystemCall
            }
            dialedOutgoingUUIDs.insert(action.callUUID)
            trimOutgoingDeduplicationState(keeping: action)
            let backgroundTaskID = beginCallControlBackgroundTask(name: "AirSIMCallStart")
            defer { endCallControlBackgroundTask(backgroundTaskID) }
            let backendError = try await CallKitActionCoordinator.perform(
                prepare: {
                    self.debugLog("preparing outgoing audio session")
                    try handler.callKitPrepareAudioSession()
                    self.debugLog("outgoing audio session prepared")
                },
                fulfill: {
                    self.debugLog("fulfilling outgoing start action")
                    self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                    self.systemCallReported = true
                    if let name = self.currentCallerName, !name.isEmpty, name != self.currentNumber {
                        self.provider.reportCall(with: action.callUUID, updated: self.update(number: self.currentNumber, callerName: name))
                    }
                    // 先让 CallKit 建立系统通话和音频会话；云端拨号轮询最长 25 秒，
                    // 不能占住 CXStartCallAction，否则系统 UI 和 didActivate 都会滞后。
                    action.fulfill()
                    self.debugLog("outgoing start action fulfilled")
                },
                backend: {
                    self.debugLog("starting backend dial")
                    try await handler.callKitStart(number: action.handle.value)
                    self.debugLog("backend dial accepted")
                }
            )
            if let backendError, currentUUID == action.callUUID, self.handler === handler,
               endingActionUUID != action.callUUID {
                let diagnostic = backendError as NSError
                debugLog("backend action failed domain=\(diagnostic.domain) code=\(diagnostic.code)")
                finishCurrentCall(previous: nil, reason: .failed)
                handler.callKitDidFail(backendError.localizedDescription)
                return
            }
            if currentUUID == action.callUUID, self.handler === handler, currentState == "active",
               endingActionUUID != action.callUUID {
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            }
        } catch {
            let nsError = error as NSError
            debugLog("outgoing start failed domain=\(nsError.domain) code=\(nsError.code)")
            if currentUUID == action.callUUID { resetCurrentCall() }
            fail(action, error: error)
        }
    }

    private func trimOutgoingDeduplicationState(keeping action: CXStartCallAction) {
        guard handledOutgoingActions.count > 32 || dialedOutgoingUUIDs.count > 32 else { return }
        handledOutgoingActions = [ObjectIdentifier(action)]
        dialedOutgoingUUIDs = [action.callUUID]
    }

    private func beginPerformEnd(_ action: CXEndCallAction) {
        debugLog("performing outgoing/system end action")
        let currentHandler = handler
        // reportCall(ended:) may be followed by a delayed CXEndCallAction after
        // the authoritative Agent state already cleared this UUID. That action
        // is cleanup, not a new user hangup whose missing transport needs an alert.
        let systemCallWasCurrent = currentUUID == action.callUUID
        guard systemCallWasCurrent else { action.fulfill(); return }
        guard endingActionUUID != action.callUUID else { action.fulfill(); return }
        endingActionUUID = action.callUUID
        endActionFulfilled = true
        incomingDeduplicator.recordEnded(
            callID: currentBackendID,
            uuid: action.callUUID,
            at: Date()
        )
        // 同步 fulfill 避免 CallKit 挂断界面卡死或触发系统动作超时；
        // 保留当前 UUID 并在后台任务保活期间完成后端 call.hangup，再释放系统通话上下文。
        action.fulfill()
        let callUUID = action.callUUID
        let backgroundTaskID = beginCallControlBackgroundTask(name: "AirSIMCallEnd")
        Task { @MainActor [weak self] in
            defer { self?.endCallControlBackgroundTask(backgroundTaskID) }
            guard let self else { return }
            var backendError: Error?
            if CallKitEndActionPolicy.shouldForwardToBackend(
                systemCallWasCurrent: systemCallWasCurrent
            ) {
                do {
                    guard let currentHandler else { throw CallKitBridgeError.handlerUnavailable }
                    try await currentHandler.callKitEnd()
                } catch {
                    backendError = error
                }
            }

            // CallKit owns the local system-call lifecycle. A temporarily missing
            // module must not leave the UUID registered after the user hangs up.
            guard self.currentUUID == callUUID, self.handler === currentHandler else { return }
            currentHandler?.callKitCallDidEnd()
            self.resetCurrentCall()

            if let backendError {
                currentHandler?.callKitDidFail(backendError.localizedDescription)
            }
        }
    }
}

extension CallKitController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        let stamp = actionGate.generation
        Task { @MainActor [weak self] in
            guard self?.acceptsAction(stamp) == true else { return }
            guard let self else { return }
            let handler = self.handler
            let uuid = self.currentUUID
            self.audioSessionIsActive = false
            await handler?.callKitProviderDidReset()
            guard self.actionGate.accepts(stamp), self.currentUUID == uuid else { return }
            self.resetCurrentCall()
            if handler is V2SystemCallController { handler?.callKitCallDidEnd() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Task { @MainActor [weak self] in
            self?.debugLog("system action timed out type=\(type(of: action))")
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let stamp = actionGate.generation
        Task { @MainActor [weak self] in
            guard self?.acceptsAction(stamp) == true else { action.fail(); return }
            await self?.performStart(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let stamp = actionGate.generation
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard self.acceptsAction(stamp), self.currentUUID == action.callUUID else {
                    action.fail()
                    return
                }
                self.beginPerformAnswer(action)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard self?.acceptsAction(stamp) == true else { action.fail(); return }
            guard self?.currentUUID == action.callUUID else { action.fail(); return }
            self?.beginPerformAnswer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let stamp = actionGate.generation
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard self.acceptsAction(stamp) else {
                    if self.currentUUID != action.callUUID { action.fulfill() } else { action.fail() }
                    return
                }
                guard self.currentUUID == action.callUUID else { action.fulfill(); return }
                self.beginPerformEnd(action)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { action.fulfill(); return }
            guard self.acceptsAction(stamp) else {
                if self.currentUUID != action.callUUID { action.fulfill() } else { action.fail() }
                return
            }
            guard self.currentUUID == action.callUUID else { action.fulfill(); return }
            self.beginPerformEnd(action)
        }
    }

    private func enqueueSystemDTMF(digits: String, callUUID: UUID, handler: any CallKitActionHandling) {
        let sanitized = String(digits.uppercased().filter { "0123456789ABCD*#".contains($0) })
        guard !sanitized.isEmpty else { return }
        dtmfQueue.append(sanitized)
        guard dtmfDrainTask == nil else { return }
        let backgroundTaskID = beginCallControlBackgroundTask(name: "AirSIMCallDTMF")
        dtmfDrainTask = Task { @MainActor [weak self] in
            defer {
                self?.dtmfDrainTask = nil
                self?.endCallControlBackgroundTask(backgroundTaskID)
            }
            while let self, !Task.isCancelled, !self.dtmfQueue.isEmpty,
                  self.currentUUID == callUUID, self.handler === handler,
                  self.endingActionUUID != callUUID {
                let nextDigits = self.dtmfQueue.removeFirst()
                do {
                    try await handler.callKitPlayDTMF(nextDigits)
                } catch {
                    guard self.currentUUID == callUUID, self.handler === handler,
                          self.endingActionUUID != callUUID else { break }
                    self.dtmfQueue.removeAll()
                    handler.callKitDidFail(error.localizedDescription)
                    break
                }
            }
        }
    }

    private func beginPerformMute(_ action: CXSetMutedCallAction) {
        guard currentUUID == action.callUUID, let handler else {
            action.fail()
            return
        }
        if let v2 = handler as? V2SystemCallController {
            v2.callKitSetMutedSync(action.isMuted)
            action.fulfill()
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.currentUUID == action.callUUID, self.handler === handler else {
                action.fail()
                return
            }
            await handler.callKitSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    private func beginPerformDTMF(_ action: CXPlayDTMFCallAction) {
        guard currentUUID == action.callUUID, endingActionUUID != action.callUUID else {
            fail(action, error: CallKitBridgeError.staleSystemCall)
            return
        }
        guard let handler else {
            fail(action, error: CallKitBridgeError.handlerUnavailable)
            return
        }
        if handler is V2SystemCallController {
            // 同步 fulfill 避免 CallKit 按键界面阻塞，串行队列按顺序发送连续按键。
            action.fulfill()
            enqueueSystemDTMF(digits: action.digits, callUUID: action.callUUID, handler: handler)
            return
        }
        Task { @MainActor [weak self] in
            do {
                guard self?.currentUUID == action.callUUID else { throw CallKitBridgeError.staleSystemCall }
                try await handler.callKitPlayDTMF(action.digits)
                action.fulfill()
            } catch {
                self?.fail(action, error: error)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let stamp = actionGate.generation
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard self.acceptsAction(stamp) else { action.fail(); return }
                self.beginPerformMute(action)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.acceptsAction(stamp) else { action.fail(); return }
            self.beginPerformMute(action)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        let stamp = actionGate.generation
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard self.acceptsAction(stamp) else { action.fail(); return }
                self.beginPerformDTMF(action)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.acceptsAction(stamp) else { action.fail(); return }
            self.beginPerformDTMF(action)
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
#if DEBUG
        NSLog("[AirSIM Media] stage=providerDidActivate")
#endif
        let stamp = actionGate.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.acceptsAction(stamp), !self.endActionFulfilled, self.endingActionUUID == nil else {
#if DEBUG
                self.logAudioGateRejection(stage: "providerActivateRejected", stamp: stamp)
#endif
                return
            }
            self.audioSessionIsActive = true
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "callkit-audio",
                phase: "activated",
                title: "CallKit 音频会话已激活",
                fields: self.audioTraceFields(audioSession)
            )
            guard self.acceptsAction(stamp), self.audioSessionIsActive,
                  !self.endActionFulfilled, self.endingActionUUID == nil else {
#if DEBUG
                self.logAudioGateRejection(stage: "providerActivateDeliverySkipped", stamp: stamp)
#endif
                return
            }
            await self.handler?.callKitAudioSessionDidActivate()
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
#if DEBUG
        NSLog("[AirSIM Media] stage=providerDidDeactivate")
#endif
        let stamp = actionGate.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.acceptsAction(stamp) else {
#if DEBUG
                self.logAudioGateRejection(stage: "providerDeactivateRejected", stamp: stamp)
#endif
                return
            }
            self.audioSessionIsActive = false
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP",
                category: "callkit-audio",
                phase: "deactivated",
                title: "CallKit 音频会话已停用",
                fields: self.audioTraceFields(audioSession)
            )
            guard self.acceptsAction(stamp), !self.audioSessionIsActive else {
#if DEBUG
                self.logAudioGateRejection(stage: "providerDeactivateDeliverySkipped", stamp: stamp)
#endif
                return
            }
            self.handler?.callKitAudioSessionDidDeactivate()
        }
    }

#if DEBUG
    private func logAudioGateRejection(stage: String, stamp: UInt64) {
        NSLog("[AirSIM Media] stage=%@ generationMatches=%d isAvailable=%d hasHandler=%d isV2=%d audioActive=%d", stage, actionGate.accepts(stamp) ? 1 : 0, isAvailable ? 1 : 0, handler != nil ? 1 : 0, handler is V2SystemCallController ? 1 : 0, audioSessionIsActive ? 1 : 0)
    }
#endif

    private func audioTraceFields(_ audioSession: AVAudioSession) -> [String: String] {
        let inputs = audioSession.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = audioSession.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return [
            "call_uuid": currentUUID?.uuidString.lowercased() ?? "none",
            "state": currentState ?? "none",
            "input_route": inputs.isEmpty ? "none" : inputs,
            "output_route": outputs.isEmpty ? "none" : outputs,
            "sample_rate": String(Int(audioSession.sampleRate)),
            "io_buffer_ms": String(Int(audioSession.ioBufferDuration * 1_000)),
        ]
    }
}

enum CallKitBridgeError: LocalizedError {
    case noSystemCall
    case staleSystemCall
    case handlerUnavailable
    case unavailable
    case callInProgress
    case noReachableTransport
    case cloudMediaDisabled

    var errorDescription: String? {
        switch self {
        case .noSystemCall: return "系统通话尚未建立"
        case .staleSystemCall: return "系统通话状态已刷新"
        case .handlerUnavailable: return "通话控制器尚未就绪"
        case .unavailable: return "系统 CallKit 当前不可用"
        case .callInProgress: return "当前已有进行中的系统通话"
        case .noReachableTransport: return "三星本地链路和云端语音当前都不可达"
        case .cloudMediaDisabled: return "三星本地链路不可达，云端语音中继已关闭"
        }
    }
}
