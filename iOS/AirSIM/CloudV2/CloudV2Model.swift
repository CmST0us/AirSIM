import Foundation
import SwiftUI
import UIKit
import Combine

enum V2EligibilityFailureReason: String {
    case configuration, foreground, directoryOffline, snapshotOffline, identityEpochMismatch
    case snapshotExpired, snapshotFuture, snapshotInvalid, controlNotReady, audioUnavailable
    case callNotActive, ownedContextMismatch, persistenceFailed, experimentalDisabled, unknown
}
struct V2EligibilityFailure: Equatable {
    let reason: V2EligibilityFailureReason
    let snapshotAgeSeconds: Double?
}

@MainActor
final class CloudV2Model: ObservableObject {
    @Published private(set) var lastEligibilityFailure: V2EligibilityFailure?
    @Published private(set) var configuration: V2Configuration?
    @Published private(set) var modules: [V2Module] = []
    @Published private(set) var selectedModuleID: String?
    @Published private(set) var snapshot: V2SnapshotResponse?
    @Published private(set) var messagesResponse: V2MessagesResponse?
    @Published private(set) var history = V2History()
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var commandStatus = "尚无操作"
    @Published var error: String?
    @Published private(set) var syncStatus: String?
    @Published var number = ""
    @Published var smsNumber = ""
    @Published var smsText = ""
    @Published var tones = ""
    @Published var experimentalAudio = false {
        didSet {
            defaults.set(experimentalAudio, forKey: "airsim.v2.experimental-audio")
            if !experimentalAudio { media.requestStop() }
        }
    }
    @Published var diagnosticAudio = false
    @Published private(set) var localAudioResult = "尚未测试"
    private var localAudioTask: Task<Void, Never>?
    let media: V2MediaCoordinator
    private var mediaObservation: AnyCancellable?
    private var runtimeCallCommandID: String?
    private var newlyOwnedCall: V2CallContext?
    private var attemptedAudioCall: V2CallContext?

    @Published private(set) var foreground = false
    private let client: V2Client
    private var machine: V2CommandMachine?
    private let configurationStore: V2ConfigurationStore
    private let historyFile: V2ProtectedFile<V2History>
    private let defaults: UserDefaults
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionEpoch: UInt64 = 0
    private var actionInFlight = false
    private var backgroundCleanupTask: Task<Void, Never>?
    private var backgroundEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var backgroundHangups = Set<String>()
    private var persistenceFailed = false
    private(set) var discovery: V2Discovery?
    init(client: V2Client? = nil, media: V2MediaCoordinator? = nil, defaults: UserDefaults = .standard, root: URL = V2LocalPaths.root, tokens: V2TokenStore = V2KeychainTokenStore(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        let client = client ?? V2Client(transport: V2URLSessionTransport(), tokens: tokens, now: now)
        self.client = client
        self.media = media ?? V2MediaCoordinator(create: { context, request in try await client.createMedia(context: context, requestID: request) }, delete: { context, session in try? await client.deleteMedia(context: context, sessionID: session) })
        configurationStore = V2ConfigurationStore(tokens: tokens, defaults: defaults)
        historyFile = V2ProtectedFile(url: root.appendingPathComponent("history.json"))
        do {
            configuration = try configurationStore.load()
            history = try historyFile.load() ?? V2History()
            machine = try V2CommandMachine(client: client, store: V2FilePendingStore(url: root.appendingPathComponent("pending.json")), ownedStore: V2FileOwnedCallStore(file: V2ProtectedFile(url: root.appendingPathComponent("owned-call.json"))))
            if let configuration { selectedModuleID = defaults.string(forKey: V2LocalPaths.selectionKey(configuration.identity)) }
        } catch { persistenceFailed = true; self.error = "本地状态读取失败，已禁止控制。" }
        experimentalAudio = defaults.bool(forKey: "airsim.v2.experimental-audio")
        client.onAuthenticationInvalidated = { [weak self] in
            self?.connected = false
            self?.generation &+= 1
            self?.pollTask?.cancel(); self?.pollTask = nil
            self?.syncStatus = "凭据已过期或撤销，需要重新导入连接配置。"
            self?.media.requestStop()
        }
        client.onControlInvalidated = { [weak self] in
            self?.syncStatus = "模块离线或会话已变化；保留通话上下文，等待核对。"
            self?.media.requestStop()
        }
        mediaObservation = self.media.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.media.onDiagnosticTimeout = { [weak self] context in
            guard let self, self.ownedCall == context else { return }
            Task {
                guard self.ownedCall == context else { return }
                await self.perform(action: "call.hangup", args: ["call_id": context.callID])
            }
        }
        refreshCommandStatus()
    }
    var ownedCall: V2CallContext? { machine?.ownedCall }
    var hasUnresolvedCommand: Bool { machine?.pending != nil }
    var activeCall: V2Call? {
        if let ownedCall { return snapshot?.snapshot?.calls.calls.first { $0.call_id == ownedCall.callID } }
        return snapshot?.snapshot?.calls.calls.first { $0.state != "disconnected" }
    }
    var blocksSwitch: Bool {
        media.active || busy || persistenceFailed || hasUnresolvedCommand || ownedCall != nil || snapshot?.snapshot?.calls.calls.contains(where: { $0.state != "disconnected" }) == true
    }
    var selectedModule: V2Module? { modules.first { $0.module_id == selectedModuleID } }
    var freshBinding: V2ControlBinding? {
        guard connected, foreground, !persistenceFailed, let configuration, let selectedModule, let snapshot else { return nil }
        return try? snapshot.controlBinding(configuration: configuration, module: selectedModule, now: now())
    }
    var telephonyReady: Bool { freshBinding != nil && snapshot?.snapshot?.control.ready == true && snapshot?.snapshot?.control.telephony_ready == true }
    var messagingReady: Bool { freshBinding != nil && snapshot?.snapshot?.control.ready == true && snapshot?.snapshot?.control.messaging_ready == true }
    var canAct: Bool { !busy && !hasUnresolvedCommand && !persistenceFailed }
    var ownedControlReady: Bool {
        guard let ownedCall, let snapshot, freshBinding == ownedCall.binding else { return false }
        return snapshot.matches(ownedCall, now: now()) && telephonyReady
    }
    var visibleMessages: [V2StoredMessage] {
        history.messages.filter { $0.domain.identity == configuration?.identity && $0.domain.moduleID == selectedModuleID }
    }
    var visibleCalls: [V2StoredCall] {
        history.calls.filter { $0.domain.identity == configuration?.identity && $0.domain.moduleID == selectedModuleID }
    }
    func isCurrentInbox(_ item: V2StoredMessage) -> Bool {
        item.domain.bootID == messagesResponse?.agent_boot_id && item.domain.backendEpoch == messagesResponse?.backend_epoch && messagesResponse?.online == true
    }
    func selectModule(_ moduleID: String) async {
        guard modules.contains(where: { $0.module_id == moduleID }), moduleID != selectedModuleID else { return }
        let recoveryTarget = ownedCall?.binding.moduleID ?? machine?.pending?.binding.moduleID
        guard !busy, (!blocksSwitch || (selectedModuleID == nil && moduleID == recoveryTarget)) else { error = "请先结束通话并确认未完成操作，再切换模块。"; return }
        await cancelPolling()
        selectedModuleID = moduleID; snapshot = nil; messagesResponse = nil
        if let configuration { defaults.set(moduleID, forKey: V2LocalPaths.selectionKey(configuration.identity)) }
        if foreground && connected { startPolling() }
    }
    func importFile(_ url: URL) async {
        guard !blocksSwitch else { error = "通话或未确认操作期间不能更换配置。"; return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
            let imported = try V2ConfigurationImport.parse(data, now: now())
            await stop()
            configuration = try configurationStore.importConfiguration(data, now: now())
            selectedModuleID = defaults.string(forKey: V2LocalPaths.selectionKey(imported.configuration.identity))
            modules = []; snapshot = nil; messagesResponse = nil
            if foreground { await connect() }
        } catch { self.error = "连接配置导入失败：\((error as? V2Error)?.rawValue ?? "file_unavailable")" }
    }
    func connect() async {
        guard foreground, !busy, !persistenceFailed, let configuration else { return }
        connectionEpoch &+= 1; let stamp = connectionEpoch
        busy = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionEpoch == stamp { self.busy = self.actionInFlight; self.connectionTask = nil }
            }
            do {
                let result = try await self.client.connect(configuration)
                guard self.connectionEpoch == stamp, self.foreground, !Task.isCancelled else { return }
                self.discovery = result; self.connected = true; self.syncStatus = nil
                self.startPolling()
            } catch {
                guard self.connectionEpoch == stamp, !Task.isCancelled else { return }
                self.connected = false; self.syncStatus = "v2 连接未建立：\((error as? V2Error)?.rawValue ?? "request_failed")。不会回退 v1。"
            }
        }
        connectionTask = task
        await task.value
    }
    private func cancelConnection() async {
        connectionEpoch &+= 1
        let task = connectionTask; connectionTask = nil
        if task != nil { client.stop(); connected = false }
        task?.cancel(); await task?.value
        busy = actionInFlight
    }
    func disconnect() async {
        guard !blocksSwitch else { error = "请先结束通话并确认操作结果。"; return }
        await stop()
    }
    func stop() async {
        localAudioTask?.cancel(); await localAudioTask?.value; localAudioTask = nil
        await media.stop()
        await cancelBackgroundCleanup(); await cancelConnection(); await cancelPolling()
        client.stop(); connected = false; busy = actionInFlight
    }
    private func cancelPolling() async {
        generation &+= 1
        let task = pollTask; pollTask = nil; task?.cancel(); await task?.value
    }
    func sceneChanged(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            foreground = true; await cancelBackgroundCleanup()
            if connected { startPolling() } else { await connect() }
        case .inactive: break
        case .background:
            foreground = false
            // Retire a still-verifying connection before the first suspension point.
            if connectionTask != nil { connectionEpoch &+= 1; connectionTask?.cancel(); client.stop(); connected = false }
            localAudioTask?.cancel(); await localAudioTask?.value; localAudioTask = nil
            await media.stop()
            await cancelConnection(); await cancelPolling()
            beginBackgroundCleanup()
        default: break
        }
    }
    private func cancelBackgroundCleanup() async {
        backgroundEpoch &+= 1
        let task = backgroundCleanupTask; backgroundCleanupTask = nil
        task?.cancel(); await task?.value
    }
    private func beginBackgroundCleanup() {
        guard ownedCall != nil || machine?.pending != nil || actionInFlight else { return }
        backgroundEpoch &+= 1; let epoch = backgroundEpoch
        let id = UIApplication.shared.beginBackgroundTask(withName: "AirSIMV2ForegroundCallCleanup") { [weak self] in
            self?.backgroundCleanupTask?.cancel()
        }
        guard id != .invalid else { return } // Keep durable pending/context for the next foreground.
        backgroundCleanupTask = Task { [weak self] in
            defer { UIApplication.shared.endBackgroundTask(id) }
            guard let self else { return }
            let deadline = Date().addingTimeInterval(10)
            while !Task.isCancelled, self.backgroundEpoch == epoch, !self.foreground, Date() < deadline {
                if self.busy { try? await Task.sleep(for: .milliseconds(100)); continue }
                if self.machine?.pending != nil {
                    try? await self.machine?.recover()
                    guard !Task.isCancelled, self.backgroundEpoch == epoch, !self.foreground else { return }
                    try? self.finishResolvedCommand()
                }
                if let context = self.ownedCall, !self.hasUnresolvedCommand {
                    guard !self.backgroundHangups.contains(context.callID) else { return }
                    self.backgroundHangups.insert(context.callID)
                    await self.perform(action: "call.hangup", args: ["call_id": context.callID], backgroundContext: context)
                    return
                }
                if self.machine?.pending == nil { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func startPolling() {
        guard foreground, connected, pollTask == nil else { return }
        let stamp = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            var nextDirectory = Date.distantPast
            var backoff = V2PollBackoff()
            while !Task.isCancelled, self.generation == stamp, self.foreground {
                var delay: TimeInterval = 1
                do {
                    if self.now() >= nextDirectory {
                        let directory = try await self.client.modules()
                        guard self.generation == stamp, !Task.isCancelled else { return }
                        self.modules = directory.modules; nextDirectory = self.now().addingTimeInterval(5)
                    }
                    if let module = self.selectedModuleID {
                        let snapshot = try await self.client.snapshot(moduleID: module)
                        guard self.generation == stamp, !Task.isCancelled, self.selectedModuleID == module else { return }
                        self.snapshot = snapshot
                        try self.consumeSnapshot(snapshot)
                        let messages = try await self.client.messages(moduleID: module)
                        guard self.generation == stamp, !Task.isCancelled, self.selectedModuleID == module else { return }
                        self.messagesResponse = messages
                        try self.consumeMessages(messages)
                    }
                    if self.machine?.pending != nil, !self.busy {
                        try await self.machine?.recover()
                        guard self.generation == stamp, !Task.isCancelled else { return }
                        try self.finishResolvedCommand()
                    }
                    self.updateMediaEligibility()
                    self.syncStatus = nil
                    delay = backoff.succeeded()
                } catch {
                    guard self.generation == stamp, !Task.isCancelled else { return }
                    self.updateMediaEligibility()
                    self.syncStatus = "同步失败，当前状态可能已过期；未自动重发操作。"
                    delay = backoff.failed()
                }
                self.objectWillChange.send()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
    private func consumeSnapshot(_ response: V2SnapshotResponse) throws {
        guard let config = configuration, let snapshot = response.snapshot else { return }
        let domain = V2HistoryDomain(identity: config.identity, moduleID: response.module_id, bootID: snapshot.agent_boot_id, backendEpoch: snapshot.backend_epoch)
        history.merge(calls: snapshot.calls.calls.map { V2StoredCall(domain: domain, call: $0) })
        try historyFile.save(history)
        if let pending = machine?.pending, pending.action == "call.hangup",
           pending.binding.identity == config.identity, pending.binding.moduleID == response.module_id,
           response.online, response.connection_epoch == pending.binding.connectionEpoch,
           snapshot.agent_boot_id == pending.binding.bootID, snapshot.backend_epoch == pending.binding.backendEpoch,
           (-3...8).contains(now().timeIntervalSince(snapshot.observedAt)),
           snapshot.calls.calls.contains(where: { $0.call_id == pending.callID && $0.state == "disconnected" }) {
            if case .receipt = machine?.phase { try machine?.acknowledgeResolved() }
        }
        guard let context = ownedCall, context.binding.identity == config.identity,
              context.binding.moduleID == response.module_id, response.online,
              response.connection_epoch == context.binding.connectionEpoch,
              snapshot.agent_boot_id == context.binding.bootID, snapshot.backend_epoch == context.binding.backendEpoch,
              (-3...8).contains(now().timeIntervalSince(snapshot.observedAt)),
              let call = snapshot.calls.calls.first(where: { $0.call_id == context.callID }) else { return }
        if call.state == "disconnected" { try machine?.clearDisconnectedOwnedCall(); backgroundHangups.remove(context.callID) }
        else { try client.restoreOwnership(context, snapshot: response) }
    }
    private func consumeMessages(_ response: V2MessagesResponse) throws {
        guard let config = configuration else { return }
        let domain = V2HistoryDomain(identity: config.identity, moduleID: response.module_id, bootID: response.agent_boot_id, backendEpoch: response.backend_epoch)
        history.merge(messages: response.messages.map { V2StoredMessage(domain: domain, message: $0, inboxGap: response.inbox_gap, inboxDropped: response.inbox_dropped) })
        try historyFile.save(history)
    }
    func dial() async { await perform(action: "call.dial", args: ["number": number]) }
    func answer(_ call: V2Call) async { await perform(action: "call.answer", args: ["call_id": call.call_id]) }
    func reject(_ call: V2Call) async { await perform(action: "call.hangup", args: ["call_id": call.call_id]) }
    func hangup() async { guard let ownedCall else { return }; await perform(action: "call.hangup", args: ["call_id": ownedCall.callID]) }
    func dtmf() async { guard let ownedCall else { return }; await perform(action: "call.dtmf", args: ["call_id": ownedCall.callID, "tones": tones]) }
    func sendSMS() async { await perform(action: "sms.send", args: ["number": smsNumber, "text": smsText]) }
    func recoverPending() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await machine?.recover(); try finishResolvedCommand() } catch { self.error = "查询失败，操作结果仍未确认。" }
    }
    private func perform(action: String, args: [String: String], backgroundContext: V2CallContext? = nil) async {
        guard canAct, let machine else { return }
        let binding: V2ControlBinding
        if let backgroundContext { binding = backgroundContext.binding }
        else if action == "call.dtmf" || (action == "call.hangup" && ownedCall != nil) {
            guard ownedControlReady, let context = ownedCall else { error = "原通话状态尚未核对，不能控制。"; return }; binding = context.binding
        } else {
            guard let freshBinding, action == "sms.send" ? messagingReady : telephonyReady else { error = "模块状态或对应能力尚未就绪。"; return }; binding = freshBinding
        }
        busy = true; actionInFlight = true
        defer { busy = false; actionInFlight = false; objectWillChange.send() }
        do {
            if action == "call.hangup" { await media.stop() }
            let command = try V2Command(binding: binding, action: action, args: args, now: now())
            if action == "call.dial" || action == "call.answer" { runtimeCallCommandID = command.command_id }
            try await machine.submit(command, binding: binding)
            try finishResolvedCommand()
        } catch { self.error = "操作未提交：\((error as? V2Error)?.rawValue ?? "request_failed")" }
    }
    private func finishResolvedCommand() throws {
        refreshCommandStatus()
        guard let machine else { return }
        if let commandID = machine.pending?.commandID, commandID == runtimeCallCommandID, let owned = machine.ownedCall { newlyOwnedCall = owned }
        switch machine.phase {
        case let .receipt(_, state) where machine.pending?.action == "call.hangup" && (state == "accepted" || state == "observed"): break // Snapshot confirms disconnect before releasing this pending.
        case .receipt, .rejected: try machine.acknowledgeResolved()
        default: break
        }
        objectWillChange.send()
    }
#if DEBUG && targetEnvironment(simulator)
    func testLocalAudio() {
        guard !busy, !media.active, ownedCall == nil, activeCall == nil, foreground else { return }
        busy = true; localAudioResult = "正在准备本机麦克风和播放测试…"
        localAudioTask = Task { [weak self] in
            guard let self else { return }
            let audio = V2AudioEngine()
            do {
                try await audio.prepare(microphone: true)
                var pcm = Data()
                for i in 0..<160 {
                    let sample = Int16(sin(Double(i) * 2 * .pi * 400 / 8000) * 1200)
                    pcm.append(UInt8(truncatingIfNeeded: sample)); pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
                }
                let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
                while !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
                    _ = audio.takeCaptured(); _ = audio.play(pcm)
                    try await Task.sleep(for: .milliseconds(20))
                }
                let m = audio.metrics
                self.localAudioResult = "本机测试：\(Int(m.sampleRate)) Hz / \(m.channels) 声道，语音处理 \(m.voiceProcessing ? "开启" : "关闭")；采集 \(m.captured) 帧，播放 \(m.rendered) 帧。"
            } catch {
                self.localAudioResult = (error as? V2AudioError)?.message ?? "本机音频测试已停止"
            }
            await audio.stop()
            self.localAudioResult += " 引擎已停止。"
            self.busy = false; self.localAudioTask = nil
        }
    }
#endif
#if DEBUG
    var selectedSnapshotAgeSeconds: Double? {
        guard let observed = snapshot?.snapshot?.observedAt else { return nil }
        return now().timeIntervalSince(observed)
    }
#endif
    var audioReady: Bool {
        guard experimentalAudio, foreground, ownedControlReady,
              discovery?.capabilities.experimental_audio == true,
              snapshot?.snapshot?.audio.available == true,
              activeCall?.state == "active" else { return false }
        return true
    }
    private func updateMediaEligibility() {
        if media.active, (!audioReady || media.context != ownedCall) {
            media.requestStop(); return
        }
        guard audioReady, let ownedCall, newlyOwnedCall == ownedCall, attemptedAudioCall != ownedCall, !media.active else { return }
        connectAudio()
    }
    func connectAudio() {
        guard audioReady, let ownedCall, !media.active else { return }
        attemptedAudioCall = ownedCall
        lastEligibilityFailure = nil
        media.start(context: ownedCall, diagnosticMode: diagnosticAudio) { [weak self] in
            guard let self else { return false }
            let valid = self.audioReady == true && self.ownedCall == ownedCall
            if !valid { self.recordEligibilityFailure(for: ownedCall) }
            return valid
        }
    }
    private func recordEligibilityFailure(for context: V2CallContext) {
        let age = snapshot?.snapshot.map { now().timeIntervalSince($0.observedAt) }
        let reason: V2EligibilityFailureReason
        if configuration == nil || !connected { reason = .configuration }
        else if !foreground { reason = .foreground }
        else if persistenceFailed { reason = .persistenceFailed }
        else if !experimentalAudio { reason = .experimentalDisabled }
        else if ownedCall != context { reason = .ownedContextMismatch }
        else if selectedModule?.online != true { reason = .directoryOffline }
        else if snapshot?.online != true || snapshot?.snapshot == nil { reason = .snapshotOffline }
        else if let configuration, let module = selectedModule, let response = snapshot, let value = response.snapshot {
            if configuration.identity != context.binding.identity || response.server_id != configuration.identity.serverID ||
                response.module_id != module.module_id || module.module_id != context.binding.moduleID ||
                response.connection_epoch != module.connection_epoch || response.connection_epoch != context.binding.connectionEpoch ||
                value.agent_boot_id != module.agent_boot_id || value.agent_boot_id != context.binding.bootID ||
                value.backend_epoch != module.backend_epoch || value.backend_epoch != context.binding.backendEpoch {
                reason = .identityEpochMismatch
            } else if let age, age > 8 { reason = .snapshotExpired }
            else if let age, age < -3 { reason = .snapshotFuture }
            else if age == nil { reason = .snapshotInvalid }
            else if !value.control.ready || !value.control.telephony_ready { reason = .controlNotReady }
            else if discovery?.capabilities.experimental_audio != true || !value.audio.available { reason = .audioUnavailable }
            else if activeCall?.state != "active" { reason = .callNotActive }
            else { reason = .unknown }
        } else { reason = .unknown }
        lastEligibilityFailure = V2EligibilityFailure(reason: reason, snapshotAgeSeconds: age)
    }
    private func refreshCommandStatus() {
        guard let machine else { return }
        switch machine.phase {
        case .idle: break
        case .submitting: commandStatus = "正在提交"
        case .waiting: commandStatus = "等待收据或通话关联，只读查询中"
        case .unknown: commandStatus = "结果未知；只查询原操作，不自动重发"
        case let .rejected(code): commandStatus = "请求被拒绝（HTTP \(code)）"
        case let .receipt(_, state): commandStatus = "设备收据：\(state)（不代表接通或送达）"
        }
    }
}
