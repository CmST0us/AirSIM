import SwiftUI

/// 首次连接沿用当前选择的运行时。
struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete") private var completed = false
    @AppStorage(LocalModePreference.key) private var localModeEnabled = false
    @AppStorage(CloudModePreference.key) private var cloudModeEnabled = true
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            if let cloud = model.cloudV2 {
                Form {
                    V2ConnectionSections(model: cloud)
                    Section { Button("完成，进入 AirSIM") { completed = true } }
                }.navigationTitle("连接 AirSIM")
            } else {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 76, height: 76)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 8) {
                    Text("连接三星手机")
                        .font(.largeTitle.bold())
                    Text("AirSIM 通过同一 Wi-Fi 或三星热点建立 VoWLAN；离开局域网时可使用独立云端 Relay。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("在三星手机启动 AirSIM 和音频桥", systemImage: "1.circle.fill")
                    Label("将两台设备连接到同一局域网", systemImage: "2.circle.fill")
                    Label("输入三星显示的六位配对码", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                Toggle(isOn: Binding(get: { router.choice == .local }, set: { enabled in Task { await router.choose(enabled ? .local : .v1) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("仅本地模式", systemImage: "wifi")
                            .font(.headline)
                        Text("只使用 VoWLAN，不需要 Relay、PushKit 或 CallKit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("开始配对", systemImage: "lock.shield") {
                    showingPairing = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("稍后在设置中配对") { completed = true }
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("AirSIM")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing, onDismiss: {
                if model.vowlan.availability.isOnlineForDisplay { completed = true }
            }) {
                NavigationStack {
                    SamsungPairingView()
                        .environmentObject(model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingPairing = false }
                            }
                        }
                }
            }
            }
        }
    }
}

struct AirSIMSettingsView: View {
    @ObservedObject private var activityEvents = LegacyActivityEvents.shared
    @EnvironmentObject private var router: AppRouteCoordinator
    private enum SelfTestPhase {
        case idle
        case running
        case completed
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @AppStorage(LocalModePreference.key) private var localModeEnabled = false
    @AppStorage(CloudModePreference.key) private var cloudModeEnabled = true
    @AppStorage(LiveActivityVisibilityPreference.key) private var liveActivityEnabled = true
    @State private var relayURL = RelayConfiguration.effectiveURL(
        stored: R7UITestScenario.defaults.string(forKey: "airsim.push-relay-url"),
        buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
        bundleID: Bundle.main.bundleIdentifier
    )
    @State private var message: String?
    @State private var selfTestPhase: SelfTestPhase = .idle
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("连接版本") {
                    RuntimeChoiceButtons()
                    if activityEvents.limitReached { Text("Live Activity token 观察已达上限，需重启 App 恢复；通话和普通推送不受影响。") }
#if DEBUG
                    Text("只读源保留：全局 \(activityEvents.globalCount) · 活动 \(activityEvents.activityCount) · retired \(activityEvents.retiredCount) · 订阅 \(activityEvents.subscriptionCount)").font(.caption)
#endif
                    if !R7UITestScenario.active && LegacySwitchFence.shared.blocked {
                        Text("旧版操作结果待核对，暂不能迁移。")
                        Button("查询旧云端操作收据") { Task { await VoIPPushController.shared.recoverSwitchFences(); model.objectWillChange.send() } }
                    }
                }
                if let cloud = model.cloudV2 {
                    V2ConnectionSections(model: cloud)
                } else {
                Section {
                    Toggle(isOn: Binding(get: { router.choice == .local }, set: { enabled in Task { await router.choose(enabled ? .local : .v1) } })) {
                        Label("仅本地模式", systemImage: "wifi")
                    }
                } header: {
                    Text("运行模式")
                } footer: {
                    Text(localModeEnabled
                        ? "仅使用同一 Wi-Fi 或手机热点下的 VoWLAN。不会注册 Relay、APNs、PushKit 或 CallKit。"
                        : "关闭后可按需启用云端 Relay、PushKit 和 CallKit。")
                }

                Section("当前连接") {
                    LabeledContent("当前模式", value: model.connectionModePresentation.title)
                    LabeledContent("连接状态", value: model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    LabeledContent(
                        "云端 Relay",
                        value: localModeEnabled
                            ? "本地模式已关闭"
                            : (!cloudModeEnabled
                            ? "已关闭"
                            : (model.cloudAgentStatus?.cloudOnline == true ? "Agent 在线" : "不可达"))
                    )
                    Text(model.connectionModePresentation.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty {
                        Text(connectionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("三星连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对三星手机", systemImage: "personalhotspot")
                    }.disabled(model.blocksRuntimeSwitch)
                    Button("重新发现", systemImage: "arrow.clockwise") {
                        model.vowlan.restartBrowsing()
                        Task { await model.vowlan.probeNow() }
                    }
                }

                Section {
                    Toggle(isOn: $liveActivityEnabled) {
                        Label("显示灵动岛", systemImage: "platter.filled.top.iphone")
                    }
                    .onChange(of: liveActivityEnabled) { enabled in
                        model.setLiveActivityEnabled(enabled)
                    }
                } header: {
                    Text("灵动岛与实时活动")
                } footer: {
                    Text("关闭后结束 AirSIM 的灵动岛与锁屏实时活动；通话和短信仍可正常使用。")
                }

                Section {
                    Toggle(isOn: $cloudModeEnabled) {
                        Label("远程通话与短信", systemImage: "cloud")
                    }
                    .disabled(localModeEnabled || model.blocksRuntimeSwitch)
                    .onChange(of: cloudModeEnabled) { enabled in
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.setCloudModeEnabled(enabled, with: api)
                            } else {
                                await VoIPPushController.shared.setCloudModeEnabled(enabled)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                    }

                    TextField("https://relay.example.com", text: $relayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(localModeEnabled || model.blocksRuntimeSwitch)
                    Button("保存 Relay 地址") {
                        guard !model.blocksRuntimeSwitch else { message = "旧版操作结果待核对或仍有通话"; return }
                        VoIPPushController.shared.updateRelayURL(relayURL)
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.syncRegistration(with: api)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                        message = "地址已保存；配对后自动注册。"
                    }
                    .disabled(localModeEnabled || model.blocksRuntimeSwitch)
                    if let message { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("云端 Relay")
                } footer: {
                    Text("云端关闭后，局域网内的三星 VoWLAN 仍可使用；公网拨打、接听和短信需要云端 Relay 与有效设备注册。")
                }

                Section {
                    Button {
                        startCloudSelfTest()
                    } label: {
                        HStack {
                            Label("运行云端模式自检", systemImage: "stethoscope")
                            Spacer()
                            if selfTestPhase == .running {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(localModeEnabled || selfTestPhase == .running)

                    if let report = selfTestReport {
                        ForEach(report.steps) { step in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selfTestSymbol(for: step.state))
                                    .foregroundStyle(selfTestColor(for: step.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title)
                                    Text(step.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if selfTestPhase == .completed {
                            Text(report.allPassed ? "云端模式自检通过" : "自检未通过，请按失败步骤修复后重试")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(report.allPassed ? .green : .orange)
                        }
                    }
                } header: {
                    Text("云端模式自检")
                } footer: {
                    Text(localModeEnabled
                        ? "本地模式不运行云端自检。"
                        : "依次验证本机 Push 凭据、AirSIM Relay 身份、设备注册和 Agent 最近 90 秒心跳；不会拨号或发送短信。")
                }

                }

                Section("关于") {
                    LabeledContent("项目", value: model.isV2 ? "AirSIM" : "AirSIM · Samsung")
                    Picker("外观", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .task {
                if !model.isV2 && !localModeEnabled {
                    await model.refreshCloudStatusForDiagnostics()
                }
            }
            .onDisappear {
                selfTestTask?.cancel()
                selfTestTask = nil
                if selfTestPhase == .running { selfTestPhase = .idle }
            }
        }
    }

    private func startCloudSelfTest() {
        selfTestTask?.cancel()
        selfTestPhase = .running
        selfTestReport = .initial
        selfTestTask = Task { @MainActor in
            let report = await VoIPPushController.shared.runCloudSelfTest { update in
                guard !Task.isCancelled else { return }
                selfTestReport = update
            }
            guard !Task.isCancelled else { return }
            selfTestReport = report
            selfTestPhase = .completed
            await model.refreshCloudStatusForDiagnostics()
        }
    }

    private func selfTestSymbol(for state: CloudSelfTestStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func selfTestColor(for state: CloudSelfTestStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}
