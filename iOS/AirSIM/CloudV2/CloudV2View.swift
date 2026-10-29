import SwiftUI
import UniformTypeIdentifiers

struct V2ConnectionSections: View {
    @ObservedObject var model: CloudV2Model
    @State private var importing = false
    @State private var showingPairing = false
    var body: some View {
        Group {
            Section("设备") {
                Button("添加设备") { showingPairing = true }
                    .disabled(model.blocksSwitch || !model.pairingAvailable)
                    .accessibilityIdentifier("v2-add-device")
                    .sheet(isPresented: $showingPairing) {
                        V2PairingSheet(model: model)
                    }
                if !model.pairingAvailable {
                    Text("此安装未配置设备配对服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("云端 v2 连接") {
                Text(model.userStatus)
                if let config = model.configuration {
                    if config.persistentSession == true {
                        Text("设备授权长期有效，可在配对网页撤销。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if config.canRenew(at: Date()) {
                        Text("旧版设备授权已安全保存在本机，联网时会自动续期。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let expiresAt = config.expiresAt {
                        Text("临时连接有效期至：\(expiresAt.formatted())")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("重新连接") { Task { await model.connect() } }
                    .disabled(model.busy || model.configuration == nil)
                Button("断开连接") { Task { await model.disconnect() } }.disabled(model.blocksSwitch || !model.connected)
                DisclosureGroup("其他方式") {
                    Button("导入旧版连接文件") { importing = true }.disabled(model.blocksSwitch)
                }
            }
            Section("选择模块") {
                if model.modules.isEmpty { Text("连接后加载模块列表，首次需要手动选择。") }
                ForEach(Array(model.modules.enumerated()), id: \.element.module_id) { index, module in
                    Button { Task { await model.selectModule(module.module_id) } } label: {
                        HStack {
                            Text("模块 · \(module.module_id.prefix(8))")
                            Text(module.online ? "在线" : "离线").foregroundStyle(.secondary)
                            Spacer()
                            if model.selectedModuleID == module.module_id { Image(systemName: "checkmark") }
                        }
                    }.disabled(model.blocksSwitch)
                    .accessibilityIdentifier("module-" + module.module_id)
                }
            }
            if model.hasUnresolvedCommand {
                Section("正在同步") {
                    Text("上一步操作仍在确认，通常会自动完成。")
                    Button("立即同步") { Task { await model.recoverPending() } }
                        .disabled(model.busy || !model.connected)
                        .accessibilityIdentifier("command-recover")
                }
            }
            Section("权限与后台通知") {
                LabeledContent("通知", value: model.notificationPermissionText)
                LabeledContent("麦克风", value: model.microphonePermission)
                LabeledContent("通讯录", value: model.contactPermission)
                Text(model.pushRegistrationStatus)
                    .font(.footnote)
                    .foregroundStyle(model.pushRegistrationReady ? .secondary : .primary)
                if model.notificationPermission == .denied {
                    Button("前往系统设置开启通知") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else if model.notificationPermission == .notDetermined {
                    Button("申请通知权限") {
                        Task { await model.requestInitialPermissions() }
                    }
                } else {
                    Button("重新登记后台推送") {
                        V2PushController.shared.requestRegistrationSync()
                    }
                }
            }
            Section("系统通话") {
                Toggle("通话音频", isOn: $model.experimentalAudio)
                Text("来电会显示在系统通话界面；接听后即使 App 进入后台也会继续。Watch v2 尚不可用。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("打开系统权限设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                NavigationLink("连接与音频诊断") { V2DiagnosticsView(model: model) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls): if let url = urls.first { Task { await model.importFile(url) } }
            case .failure: model.error = "无法读取配置文件。"
            }
        }
        .task { await model.refreshPermissionPresentation() }
    }
}

private struct V2PairingSheet: View {
    @ObservedObject var model: CloudV2Model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var found: V2PairingLookup?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("输入电脑网页上显示的 8 位连接码。")
                    TextField("8 位连接码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .accessibilityIdentifier("v2-pairing-code")
                        .onChange(of: code) { value in
                            code = String(value.filter(\.isNumber).prefix(8))
                            found = nil; message = nil
                        }
                }
                if let found {
                    Section("确认设备") {
                        LabeledContent("设备") {
                            Text(found.name).accessibilityIdentifier("v2-pairing-device-name")
                        }
                        LabeledContent("标识", value: found.short_id)
                        LabeledContent("状态", value: found.online ? "在线" : "等待联网")
                    }
                }
                if model.pendingPairingClaim() != nil {
                    Section {
                        Button("取消未完成的添加", role: .destructive) {
                            model.discardPairingPending()
                            code = ""; found = nil; message = nil
                        }
                    }
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if found == nil {
                        Button("查找设备") { Task { await lookup() } }
                            .disabled(code.count != 8 || busy)
                    } else {
                        Button("确认添加") { Task { await add() } }
                            .disabled(busy)
                            .accessibilityIdentifier("v2-pairing-confirm")
                    }
                }
            }
            .onAppear {
                if let pending = model.pendingPairingClaim() {
                    code = pending.code
                    found = pending.device
                    message = "上次添加尚未完成。确认设备后会只重试原添加。"
                }
            }
            .overlay { if busy { ProgressView("正在添加设备…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .interactiveDismissDisabled(busy)
    }

    @MainActor private func lookup() async {
        busy = true; message = nil
        defer { busy = false }
        do { found = try await model.lookupPairing(code: code) }
        catch { message = model.pairingErrorMessage(error) }
    }

    @MainActor private func add() async {
        guard let found else { return }
        busy = true; message = nil
        defer { busy = false }
        if await model.addPairedDevice(code: code, device: found) { dismiss() }
        else { message = model.error ?? "暂时无法添加设备，请稍后重试。" }
    }
}

private struct V2DiagnosticsView: View {
    @ObservedObject var model: CloudV2Model
    var body: some View {
        List {
            Section("连接身份") {
                if let config = model.configuration {
                    LabeledContent("服务", value: config.identity.serverID)
                    LabeledContent("安装实例", value: config.identity.clientInstallationID)
                }
                LabeledContent("模块", value: model.selectedModuleID ?? "未选择")
                Text(model.commandStatus)
                if let status = model.syncStatus { Text(status) }
            }
#if DEBUG
                LegacyRuntimeDiagnosticsSection()
                Section("Debug · 音频诊断") {
                    Text("最后来电推送：\(V2PushController.shared.lastIncomingDiagnostic)")
#if targetEnvironment(simulator)
                    Toggle("模拟器音频注入：提示与回声", isOn: $model.diagnosticAudio).disabled(model.media.active)
                    Text("默认关闭；开启时不采集真实麦克风，最多 75 秒后定向挂断。")
                    Button("断开本次媒体") { model.media.disconnectForDiagnostics() }.disabled(!model.media.active)
#endif
                    Button("测试本机音频（3秒）") { model.testLocalAudio() }.disabled(model.busy || model.media.active || model.ownedCall != nil || model.activeCall != nil)
                    Text(model.localAudioResult)
                    if let failure = model.lastEligibilityFailure {
                        Text("最后资格失败：\(failure.reason.rawValue) · 当时快照年龄：\(failure.snapshotAgeSeconds.map { String(format: "%.3f s", $0) } ?? "—")")
                    } else { Text("最后资格失败：无") }
                    if let failure = model.media.lastFailure {
                        Text("最后失败：\(failure.code.rawValue) · 阶段 \(failure.stage.rawValue)")
                        Text("错误域：\(failure.domain ?? "—") · 数字码：\(failure.numericCode.map { String($0) } ?? "—")")
                        Text("失败距最近下行：\(failure.downlinkAgeMilliseconds.map { String($0) + " ms" } ?? "尚无有效帧")")
                    } else { Text("最后失败：无") }
                    Text("快照年龄：\(model.selectedSnapshotAgeSeconds.map { String(format: "%.1f s", $0) } ?? "—")")
                    Text("audioReady=\(model.audioReady ? "true" : "false") · ownedControlReady=\(model.ownedControlReady ? "true" : "false")")
                    let stats = model.media.statistics
                    Text("配对 \(stats.pairedElapsedMilliseconds) ms · tick≥20ms \(stats.tickIntervalsAtLeast20ms) 次 / max \(stats.maxTickIntervalMilliseconds) ms")
                    Text("validate \(stats.validationCount) 次 · 总 \(String(format: "%.3f", Double(stats.validationTotalNanoseconds) / 1_000_000)) ms / max \(stats.validationMaxMicroseconds) μs · 成功写 max \(stats.maxSuccessfulWriteMilliseconds) ms")
                    Text("上/下行队列丢弃 \(stats.upQueueDrops)/\(stats.downQueueDrops) · 跳槽 \(stats.upSkippedSlots)/\(stats.downSkippedSlots) · 采集输出丢弃 \(stats.captureOutputDrops) · 播放丢弃 \(stats.playbackDrops)")
                    let metrics = model.media.audioMetrics
                    Text("引擎：\(metrics.running ? "运行" : "停止") · 输入 \(String(format: "%.0f", metrics.sampleRate)) Hz / \(metrics.channels) 声道 · VoiceProcessing=\(metrics.voiceProcessing ? "true" : "false")")
                    Text("实际输入：\(metrics.inputRoute.map(\.rawValue).joined(separator: ",")) · 实际输出：\(metrics.outputRoute.map(\.rawValue).joined(separator: ","))")
                    Text("请求 speaker=\(model.media.speaker ? "true" : "false")")
                    Text("发送成功 PCM：RMS \(String(format: "%.1f", stats.sentPCMEnergy.rms)) · peak \(stats.sentPCMEnergy.peak) · 非零帧 \(stats.sentPCMEnergy.nonzeroFrames)/\(stats.sentPCMEnergy.frames)")
                    Text("ASMP 校验后 PCM：RMS \(String(format: "%.1f", stats.receivedPCMEnergy.rms)) · peak \(stats.receivedPCMEnergy.peak) · 非零帧 \(stats.receivedPCMEnergy.nonzeroFrames)/\(stats.receivedPCMEnergy.frames)")
#if targetEnvironment(simulator)
                    Text("下行 PCM：RMS \(String(format: "%.1f", stats.diagnosticReceivedEnergy.rms)) · peak \(stats.diagnosticReceivedEnergy.peak) · 非零帧 \(stats.diagnosticReceivedEnergy.nonzeroFrames)/\(stats.diagnosticReceivedEnergy.frames)")
                    Text("回声输出：RMS \(String(format: "%.1f", stats.diagnosticEchoEnergy.rms)) · peak \(stats.diagnosticEchoEnergy.peak) · 非零帧 \(stats.diagnosticEchoEnergy.nonzeroFrames) · echo 帧 \(stats.diagnosticEchoEnergy.frames)")
#endif
                    Text("接收 \(stats.received) · 发送 \(stats.sent) · 序号缺口 \(stats.sequenceGaps)")
                    Text("队列丢弃 \(stats.queueDrops) · 跳过节拍 \(stats.skippedSlots) · 写超时 \(stats.writeTimeouts)")
                    Text("采集 \(stats.captureFrames) · 已播放 \(stats.rendered) · 播放补零 \(stats.playbackZero) · 注入补零 \(stats.diagnosticZero)")
                }.font(.caption)
#endif
        }.navigationTitle("诊断")
    }
}
