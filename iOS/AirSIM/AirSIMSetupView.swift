import SwiftUI

struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete", store: UITestScenario.defaults) private var completed = false
    @State private var presentation: V2SettingsSheet?

    var body: some View {
        NavigationStack {
            if let cloud = model.cloudV2 {
                AirSIMFirstConnectionContent(cloud: cloud, presentation: $presentation) {
                    completed = true
                }
                .navigationTitle("连接 AirSIM")
                .sheet(item: $presentation) { $0.content(model: cloud) }
            }
        }
    }
}

private struct AirSIMFirstConnectionContent: View {
    @ObservedObject var cloud: CloudV2Model
    @Binding var presentation: V2SettingsSheet?
    let onComplete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        Image(systemName: "simcard")
                            .font(.system(size: 48, weight: .ultraLight))
                            .accessibilityHidden(true)
                        Spacer()
                        Text("AirSIM")
                            .font(.headline)
                            .accessibilityHidden(true)
                    }
                    Text("你的号码，\n随身同行。")
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("连接你的设备，在这里拨打电话、接收来电和收发短信。")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(A1Palette.ink)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                if !cloud.modules.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("已添加的设备")
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(cloud.modules, id: \.module_id) { module in
                                if module.module_id != cloud.modules.first?.module_id {
                                    Divider()
                                }
                                HStack(spacing: 8) {
                                    Button {
                                        Task { await cloud.selectModule(module.module_id) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "simcard")
                                                .foregroundStyle(A1Palette.accent)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 4) {
                                                A1ModuleLabel(title: cloud.moduleName(module.module_id), signal: cloud.moduleSignal(module.module_id))
                                                    .font(.body.weight(.medium))
                                                    .foregroundStyle(A1Palette.ink)
                                                Text(module.online ? "在线" : "离线")
                                                    .font(.footnote)
                                                    .foregroundStyle(A1Palette.secondary)
                                            }
                                            .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                            if cloud.selectedModuleID == module.module_id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(A1Palette.accent)
                                            }
                                        }
                                        .frame(minHeight: 56)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(A1RowButtonStyle())
                                    .disabled(cloud.blocksSwitch)
                                    .accessibilityIdentifier("module-" + module.module_id)
                                    .accessibilityAddTraits(cloud.selectedModuleID == module.module_id ? .isSelected : [])
                                    Button {
                                        presentation = .moduleName(id: module.module_id, name: cloud.moduleName(module.module_id))
                                    } label: {
                                        Image(systemName: "pencil")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(A1PressButtonStyle())
                                    .accessibilityLabel("修改模块名称")
                                    .accessibilityIdentifier("rename-" + module.module_id)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("在电脑网页选择设备，再用 8 位连接码添加。")
                        .font(.body)
                        .foregroundStyle(A1Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        presentation = .pairing
                    } label: {
                        Label("添加设备", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(A1Palette.onCard)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(A1Palette.accentFill)
                    .disabled(cloud.blocksSwitch || !cloud.pairingAvailable)
                    .accessibilityIdentifier("v2-add-device")
                    if !cloud.pairingAvailable {
                        Text("此安装未配置设备配对服务。")
                            .font(.footnote)
                            .foregroundStyle(A1Palette.secondary)
                    }
                    Button("完成，进入 AirSIM", action: onComplete)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(A1PressButtonStyle())
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(A1Palette.background)
        .foregroundStyle(A1Palette.ink)
        .tint(A1Palette.accent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AirSIMSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let cloud = model.cloudV2 {
            A1CardsView(cloud: cloud)
        }
    }
}
