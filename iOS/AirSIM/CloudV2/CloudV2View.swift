import SwiftUI
import UniformTypeIdentifiers

struct CloudV2Host: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = CloudV2Model()
    var body: some View {
        CloudV2View(model: model)
            .task { router.cloud = model; await model.sceneChanged(phase) }
            .onChange(of: phase) { next in Task { await model.sceneChanged(next) } }
    }
}
struct CloudV2View: View {
    @ObservedObject var model: CloudV2Model
    var body: some View {
        TabView {
            V2PhoneView(model: model).tabItem { Label("模块与通话", systemImage: "phone") }
            V2MessagesView(model: model).tabItem { Label("短信", systemImage: "message") }
            V2SettingsView(model: model).tabItem { Label("设置", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .top) {
            if let status = model.syncStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .alert("AirSIM v2", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
private struct V2PhoneView: View {
    @ObservedObject var model: CloudV2Model
    var body: some View {
        NavigationStack {
            List {
                Section("使用哪个模块") {
                    if model.modules.isEmpty { Text("连接后加载模块目录，首次需要手动选择。") }
                    ForEach(model.modules, id: \.module_id) { module in
                        Button { Task { await model.selectModule(module.module_id) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(String(module.module_id.prefix(8))).font(.headline)
                                    Text(module.online ? "在线" : "离线").foregroundStyle(.secondary)
                                    Text("最近同步：\(module.last_seen ?? "尚无记录")").font(.caption)
                                }
                                Spacer(); if model.selectedModuleID == module.module_id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                    }
                    Text("本轮仅监控所选模块来电。电话需保持 App 前台；后台来电不可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("通话") {
                    Text("当前模块：\(model.selectedModuleID.map { String($0.prefix(8)) } ?? "未选择")")
                    Text(model.telephonyReady ? "通话控制就绪" : "通话控制不可用或状态已过期").foregroundStyle(.secondary)
                    Text(model.media.state.title).font(.caption).foregroundStyle(.secondary)
                    if let call = model.activeCall {
                        Text(call.number.isEmpty ? "号码不可用" : call.number).font(.title2)
                        Text("设备状态：\(call.state)")
                        if ["incoming", "waiting"].contains(call.state), model.ownedCall == nil {
                            HStack {
                                Button("接听") { Task { await model.answer(call) } }
                                Button("拒接", role: .destructive) { Task { await model.reject(call) } }
                            }.disabled(!model.canAct || !model.telephonyReady)
                        }
                    }
                    if model.ownedCall != nil {
                        Button("挂断", role: .destructive) { Task { await model.hangup() } }
                            .disabled(!model.canAct || !model.ownedControlReady)
                        TextField("DTMF（0–9、A–D、*、#）", text: $model.tones).textInputAutocapitalization(.characters)
                        Button("发送 DTMF") { Task { await model.dtmf() } }.disabled(!model.canAct || !model.ownedControlReady)
                        Button("恢复音频") { model.connectAudio() }.disabled(!model.audioReady || model.media.active)
                        HStack {
                            Button(model.media.muted ? "取消静音" : "静音") { model.media.setMuted(!model.media.muted) }
                            Button(model.media.speaker ? "使用听筒" : "使用扬声器") { model.media.setSpeaker(!model.media.speaker) }
                        }.disabled(model.media.state != .paired)
                        Text(model.media.muted ? "麦克风已静音" : "麦克风未静音").font(.caption)
#if DEBUG && targetEnvironment(simulator)
                        if model.diagnosticAudio { Text("模拟器音频注入：提示与回声，不代表真实麦克风验收。").font(.caption) }
#endif
                    } else {
                        TextField("拨号号码", text: $model.number).keyboardType(.phonePad)
                        Button("拨号") { Task { await model.dial() } }
                            .disabled(!model.canAct || !model.telephonyReady || model.activeCall != nil)
                    }
                    Text(model.commandStatus).font(.caption)
                    if model.hasUnresolvedCommand {
                        Button("查询原操作结果") { Task { await model.recoverPending() } }.disabled(model.busy || !model.connected)
                    }
                }
                Section("所选模块通话历史") {
                    ForEach(model.visibleCalls) { item in
                        VStack(alignment: .leading) {
                            Text(item.call.number.isEmpty ? "号码不可用" : item.call.number)
                            Text("\(item.call.state) · \(item.call.observed_at)").font(.caption)
                            Text("来源模块 \(item.domain.moduleID.prefix(8)) · 设备代次 \(item.domain.backendEpoch.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("AirSIM v2")
        }
    }
}
private struct V2MessagesView: View {
    @ObservedObject var model: CloudV2Model
    var body: some View {
        NavigationStack {
            List {
                Section("发送短信") {
                    Text("模块：\(model.selectedModuleID.map { String($0.prefix(8)) } ?? "未选择")")
                    TextField("收件号码", text: $model.smsNumber).keyboardType(.phonePad)
                    TextField("短信内容", text: $model.smsText, axis: .vertical).lineLimit(3...6)
                    Text("剩余 \(70 - model.smsText.utf16.count) 字符（表情可能占 2）").font(.caption)
                    Button("发送") { Task { await model.sendSMS() } }
                        .disabled(!model.canAct || !model.messagingReady || model.smsText.isEmpty || model.smsText.utf16.count > 70)
                    Text(model.commandStatus).font(.caption)
                    Text("sent 表示已发送，不代表对端已送达。").font(.caption).foregroundStyle(.secondary)
                }
                Section("本机历史与当前收件箱") {
                    if model.messagesResponse?.inbox_gap == true { Text("模块报告收件箱缺口，历史可能不完整。") }
                    ForEach(model.visibleMessages) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.message.direction == "incoming" ? item.message.sender : item.message.recipient).font(.headline)
                            Text(item.message.text)
                            Text("\(item.message.state == "sent" ? "已发送" : item.message.state) · \(item.message.observed_at)").font(.caption)
                            Text(model.isCurrentInbox(item) ? "当前设备代次" : "历史设备代次 / 离线副本").font(.caption2).foregroundStyle(.secondary)
                            if item.inboxGap { Text("来源有缺口（\(item.inboxDropped)）").font(.caption2) }
                        }
                    }
                }
            }.navigationTitle("短信")
        }
    }
}
private struct V2SettingsView: View {
    @ObservedObject private var activityEvents = LegacyActivityEvents.shared
    @EnvironmentObject private var router: AppRouteCoordinator
    @ObservedObject var model: CloudV2Model
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("连接版本") { RuntimeChoiceButtons() }
                Section("v2 连接") {
                    Text(model.connected ? "已连接" : "未连接")
                    if let config = model.configuration {
                        LabeledContent("HTTPS", value: config.identity.apiOrigin)
                        LabeledContent("服务身份", value: config.identity.serverID)
                        LabeledContent("客户端", value: config.identity.clientInstallationID)
                        Text("到期：\(config.expiresAt.formatted())")
                    }
                    Button("导入连接配置 JSON") { importing = true }.disabled(model.blocksSwitch)
                    Button("连接") { Task { await model.connect() } }.disabled(model.busy || model.connected || model.configuration == nil)
                    Button("断开连接") { Task { await model.disconnect() } }.disabled(model.blocksSwitch || !model.connected)
                    Text("导入管理员提供的短期连接文件；到期后需重新导入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("前台实验模式") {
                    Toggle("启用实验音频", isOn: $model.experimentalAudio)
                    Text("实验音频尚未经正式语音质量验收。开启后可在本 App 拨打或接听的通话中使用。")
                    Text("APNs：不可用 · 正式登录：不可用 · Watch v2：未支持")
                    Text("权限弹窗不会挂断；进入后台会停止轮询，并对本客户端已拥有的通话提交一次挂断。")
                }.font(.footnote)
#if DEBUG && targetEnvironment(simulator)
                Section("Debug · 音频诊断") {
                    Toggle("模拟器音频注入：提示与回声", isOn: $model.diagnosticAudio).disabled(model.media.active)
                    Text("默认关闭；开启时不采集真实麦克风，最多 75 秒后定向挂断。")
                    Button("断开本次媒体") { model.media.disconnectForDiagnostics() }.disabled(!model.media.active)
                    Button("测试本机音频（3秒）") { model.testLocalAudio() }.disabled(model.busy || model.media.active || model.ownedCall != nil || model.activeCall != nil)
                    Text(model.localAudioResult)
                    let stats = model.media.statistics
                    Text("接收 \(stats.received) · 发送 \(stats.sent) · 序号缺口 \(stats.sequenceGaps)")
                    Text("队列丢弃 \(stats.queueDrops) · 跳过节拍 \(stats.skippedSlots) · 写超时 \(stats.writeTimeouts)")
                    Text("采集 \(stats.captureFrames) · 已播放 \(stats.rendered) · 播放补零 \(stats.playbackZero) · 注入补零 \(stats.diagnosticZero)")
                }.font(.caption)
#endif
                Section("迁移诊断") {
                    if activityEvents.limitReached { Text("旧版 Live Activity token 观察已达上限，需重启恢复。") }
#if DEBUG
                    Text("只读源保留：全局 \(activityEvents.globalCount) · 活动 \(activityEvents.activityCount) · retired \(activityEvents.retiredCount) · 订阅 \(activityEvents.subscriptionCount)")
#endif
                    Text("legacy_runtime_stopped=\(router.legacyRuntimeStopped ? "true" : "false")")
                    Text("remote_registration_removal=unsupported")
                    Text("旧服务器不支持删除注册；仅停用本安装。其他手机和 Watch 不随本机切换。")
                }.font(.caption)
            }.navigationTitle("设置")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    switch result { case let .success(urls): if let url = urls.first { Task { await model.importFile(url) } }; case .failure: model.error = "无法读取配置文件。" }
                }
        }
    }
}
