import SwiftUI
import UniformTypeIdentifiers

struct V2ConnectionSections: View {
    @ObservedObject var model: CloudV2Model
    @State private var importing = false
    var body: some View {
        Group {
            Section("云端 v2 连接") {
                Text(model.userStatus)
                if let config = model.configuration {
                    LabeledContent("服务器", value: config.identity.apiOrigin)
                    Text("有效期至：\(config.expiresAt.formatted())")
                }
                Button("导入连接配置 JSON") { importing = true }.disabled(model.blocksSwitch)
                Button("重新连接") { Task { await model.connect() } }
                    .disabled(model.busy || model.configuration == nil)
                Button("断开连接") { Task { await model.disconnect() } }.disabled(model.blocksSwitch || !model.connected)
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
                Section("待核对操作") {
                    Text("结果尚未确认，保留草稿并只查询原操作。")
                    Button("查询原操作结果") { Task { await model.recoverPending() } }
                        .disabled(model.busy || !model.connected)
                        .accessibilityIdentifier("command-recover")
                }
            }
            Section("系统通话") {
                Toggle("通话音频", isOn: $model.experimentalAudio)
                Text("已有系统通话可在后台继续；空闲时请保持 App 前台接收来电。Watch v2 尚不可用。")
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
                Section("Debug · 音频诊断") {
#if targetEnvironment(simulator)
                    Toggle("模拟器音频注入：提示与回声", isOn: $model.diagnosticAudio).disabled(model.media.active)
                    Text("默认关闭；开启时不采集真实麦克风，最多 75 秒后定向挂断。")
                    Button("断开本次媒体") { model.media.disconnectForDiagnostics() }.disabled(!model.media.active)
                    Button("测试本机音频（3秒）") { model.testLocalAudio() }.disabled(model.busy || model.media.active || model.ownedCall != nil || model.activeCall != nil)
                    Text(model.localAudioResult)
#endif
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
