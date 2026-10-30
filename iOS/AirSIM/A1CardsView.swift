import SwiftUI

struct A1CardsView: View {
    @ObservedObject var cloud: CloudV2Model
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.a1UsesWideLayout) private var usesWideLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedModuleID: String?
    @State private var compactShowsDetail = false
    @State private var presentation: V2SettingsSheet?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesWideLayout {
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        cardList
                            .navigationSplitViewColumnWidth(A1Layout.masterColumnWidth(totalWidth: geometry.size.width))
                            .toolbar(.hidden, for: .navigationBar)
                    } detail: {
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationStack {
                        cardList
                            .navigationTitle("号卡")
                            .navigationDestination(isPresented: $compactShowsDetail) {
                                if let module = selectedModule {
                                    detail(module, showsBack: true)
                                }
                            }
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
            }
            .background(A1Palette.background)
            .sheet(item: $presentation) { $0.content(model: cloud) }
        }
        .onChange(of: cloud.modules.map(\.module_id)) { moduleIDs in
            if let selectedModuleID, !moduleIDs.contains(selectedModuleID) {
                self.selectedModuleID = nil
                compactShowsDetail = false
            }
        }
        .onChange(of: usesWideLayout) { wide in
            compactShowsDetail = !wide && selectedModule != nil
        }
    }

    private var selectedModule: V2Module? {
        cloud.modules.first { $0.module_id == selectedModuleID }
    }

    private var detailModule: V2Module? {
        selectedModule ?? cloud.modules.first(where: { $0.module_id == cloud.defaultOutgoingModuleID }) ?? cloud.modules.first
    }

    private var cardList: some View {
        VStack(spacing: 0) {
            header
            List {
                Group {
                    Text(cloud.modules.count == 2 ? "两个号码，各自清楚。" : "管理你的号卡。")
                        .font(A1Typography.font(14))
                        .foregroundStyle(A1Palette.secondary)
                        .padding(.top, 13).padding(.bottom, 26)
                        .listRowSeparator(.hidden)
                    if cloud.modules.isEmpty {
                        emptyCards
                            .listRowSeparator(.hidden)
                    }
                    ForEach(Array(cloud.modules.enumerated()), id: \.element.module_id) { index, module in
                        Button {
                            selectedModuleID = module.module_id
                            compactShowsDetail = !usesWideLayout
                        } label: {
                            card(module, index: index)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("module-" + module.module_id)
                        .accessibilityAddTraits(usesWideLayout && detailModule?.module_id == module.module_id ? .isSelected : [])
                        .listRowSeparator(.hidden)
                    }
                    if !cloud.modules.isEmpty {
                        Text("呼出与连接")
                            .font(A1Typography.font(18, weight: .bold))
                            .padding(.top, 39)
                            .listRowSeparator(.hidden)
                        Menu {
                            ForEach(cloud.modules, id: \.module_id) { module in
                                Button {
                                    Task { await cloud.selectModule(module.module_id) }
                                } label: {
                                    if module.module_id == cloud.defaultOutgoingModuleID {
                                        Label(cloud.moduleName(module.module_id), systemImage: "checkmark")
                                    } else {
                                        Text(cloud.moduleName(module.module_id))
                                    }
                                }
                            }
                        } label: {
                            A1CardSettingRow(title: "默认呼出号码", value: cloud.defaultOutgoingModuleID.map(cloud.moduleName) ?? "未选择", actionable: true)
                        }
                        .disabled(cloud.blocksSwitch)
                        .accessibilityIdentifier("a1-card-default-line")
                        A1CardSettingRow(title: "号码不可用时", value: "不自动切换")
                        A1CardSettingRow(title: "网络连接", value: connectionTitle)
                            .accessibilityIdentifier("a1-card-connection")
                        Text(requiresPairing ? cloud.userStatus : "连接会自动恢复。通话和短信始终使用所选号卡。")
                            .font(A1Typography.font(12))
                            .foregroundStyle(A1Palette.secondary)
                            .padding(.top, 12).padding(.bottom, 28)
                            .listRowSeparator(.hidden)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(A1Palette.background)
                .listRowSeparatorTint(A1Palette.separator)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .environment(\.defaultMinListHeaderHeight, 0)
        }
        .frame(maxWidth: usesWideLayout ? .infinity : 600)
        .frame(maxWidth: .infinity)
        .foregroundStyle(A1Palette.ink)
        .background(A1Palette.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("号卡").font(A1Typography.font(32, weight: .bold))
            Spacer(minLength: 8)
            Button { presentation = .pairing } label: {
                A1AssetIcon("a1-card-plus")
                    .frame(width: 44, height: 44)
                    .background(A1Palette.soft, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(cloud.blocksSwitch || !cloud.pairingAvailable)
            .accessibilityLabel("添加设备")
            .accessibilityIdentifier("v2-add-device")
            Menu {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            } label: {
                A1AssetIcon("a1-card-more")
                    .frame(width: 44, height: 44)
                    .background(A1Palette.soft, in: Circle())
            }
            .accessibilityLabel("号卡选项")
            .accessibilityIdentifier("a1-card-options")
        }
        .padding(.horizontal, 24).padding(.top, 8)
        .frame(minHeight: 53)
    }

    private func card(_ module: V2Module, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                A1AssetIcon(index == 0 ? "a1-card-sim-blue" : "a1-card-sim-green")
                Text(cloud.moduleName(module.module_id))
                    .font(A1Typography.font(17, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(module.online ? "在线" : "离线")
                    .font(A1Typography.font(12, weight: .medium))
                    .foregroundStyle(A1Palette.secondary)
            }
            Text("未提供号码")
                .font(A1Typography.font(27, weight: .medium))
                .foregroundStyle(A1Palette.secondary)
                .frame(minHeight: 38)
            HStack {
                Text(module.module_id == cloud.defaultOutgoingModuleID ? "默认呼出号码" : "通话与短信")
                    .font(A1Typography.font(12))
                    .foregroundStyle(A1Palette.secondary)
                Spacer()
                A1AssetIcon("a1-card-chevron")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 143, alignment: .leading)
        .background(A1Palette.soft, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            if usesWideLayout && detailModule?.module_id == module.module_id {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(A1Palette.ink, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private var emptyCards: some View {
        VStack(spacing: 18) {
            A1AssetIcon("a1-card-detail-sim")
            Text("添加你的第一张号卡")
                .font(A1Typography.font(24, weight: .medium))
            Text("连接模块后，即可通话和收发短信。")
                .font(A1Typography.font(14)).foregroundStyle(A1Palette.secondary)
            Button("添加设备") { presentation = .pairing }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(cloud.blocksSwitch || !cloud.pairingAvailable)
            if !cloud.pairingAvailable {
                Text("此安装未配置设备配对服务。")
                    .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    @ViewBuilder private var detailPane: some View {
        if let module = detailModule {
            detail(module, showsBack: false)
        } else {
            Text("号卡详情")
                .font(A1Typography.font(20, weight: .medium))
                .foregroundStyle(A1Palette.secondary)
        }
    }

    private func detail(_ module: V2Module, showsBack: Bool) -> some View {
        A1CardDetailView(cloud: cloud, module: module, showsBack: showsBack, requiresPairing: requiresPairing) {
            presentation = .moduleName(id: module.module_id, name: cloud.moduleName(module.module_id))
        }
    }

    private var connectionTitle: String {
        if requiresPairing { return "需重新添加设备" }
        guard cloud.connected else { return "自动连接中" }
        return cloud.usingUSB ? "USB 本地" : "通过互联网"
    }

    private var requiresPairing: Bool {
        guard !cloud.usingUSB, let configuration = cloud.configuration else { return false }
        return !configuration.accessIsValid(at: cloud.currentTime) && !configuration.canRenew(at: cloud.currentTime)
    }
}

private struct A1CardDetailView: View {
    @ObservedObject var cloud: CloudV2Model
    let module: V2Module
    let showsBack: Bool
    let requiresPairing: Bool
    let onRename: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !showsBack {
                Text("号卡")
                    .font(A1Typography.font(17, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(minHeight: 52)
            }
            List {
                Group {
                    VStack(spacing: 0) {
                        A1AssetIcon("a1-card-detail-sim")
                            .padding(.top, 31)
                        Text(cloud.moduleName(module.module_id))
                            .font(A1Typography.font(30, weight: .medium))
                            .multilineTextAlignment(.center)
                            .padding(.top, 18)
                        Text("未提供号码")
                            .font(A1Typography.font(26))
                            .foregroundStyle(A1Palette.secondary)
                            .padding(.top, 8)
                        Text(module.online ? "号卡 · 在线" : "号卡 · 离线")
                            .font(A1Typography.font(13))
                            .foregroundStyle(A1Palette.secondary)
                            .padding(.top, 4).padding(.bottom, 43)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    Button(action: onRename) {
                        A1CardSettingRow(title: "号卡名称", value: cloud.moduleName(module.module_id), actionable: true, titleSize: 15, valueSize: 13)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("修改模块名称")
                    .accessibilityIdentifier("rename-" + module.module_id)
                    Button {
                        Task { await cloud.selectModule(module.module_id) }
                    } label: {
                        A1CardSettingRow(title: "默认呼出", value: module.module_id == cloud.defaultOutgoingModuleID ? "当前默认" : "设为默认", actionable: true, titleSize: 15, valueSize: 13)
                    }
                    .buttonStyle(.plain)
                    .disabled(cloud.blocksSwitch)
                    .accessibilityIdentifier("a1-card-set-default")
                    A1CardSettingRow(title: "来电与短信", value: receptionTitle, titleSize: 15, valueSize: 13)
                    A1CardSettingRow(title: "连接方式", value: connectionTitle, titleSize: 15, valueSize: 13)
                    A1CardSettingRow(title: "不可用时", value: "不自动切换", titleSize: 15, valueSize: 13)
                    Text(requiresPairing ? cloud.userStatus : "连接会自动恢复，无需手动重连。")
                        .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                        .padding(.top, 28).padding(.bottom, 28)
                        .listRowSeparator(.hidden)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(A1Palette.background)
                .listRowSeparatorTint(A1Palette.separator)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(A1Palette.background)
        .foregroundStyle(A1Palette.ink)
        .navigationTitle(cloud.moduleName(module.module_id))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsBack ? .visible : .hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
    }

    private var receptionTitle: String {
        if requiresPairing { return "需重新添加设备" }
        guard module.online else { return "等待模块联网" }
        guard module.module_id == cloud.selectedModuleID else { return "模块在线" }
        return cloud.telephonyReady && cloud.messagingReady ? "已就绪" : "正在同步"
    }

    private var connectionTitle: String {
        if requiresPairing { return "需重新添加设备" }
        guard module.module_id == cloud.selectedModuleID else { return module.online ? "通过互联网" : "等待连接" }
        guard cloud.connected else { return "自动连接中" }
        return cloud.usingUSB ? "USB 本地" : "通过互联网"
    }
}

private struct A1CardSettingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String
    var actionable = false
    var titleSize: CGFloat = 14
    var valueSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text(title).font(A1Typography.font(titleSize)).foregroundStyle(A1Palette.ink)
                    .layoutPriority(1)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(value).font(A1Typography.font(valueSize)).foregroundStyle(A1Palette.secondary)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if actionable { A1AssetIcon("a1-card-row-chevron") }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 55)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
