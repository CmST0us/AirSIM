import SwiftUI

enum V2SettingsSheet: Identifiable {
    case pairing
    case moduleName(id: String, name: String)
    var id: String {
        switch self {
        case .pairing: return "pairing"
        case let .moduleName(id, _): return "name-" + id
        }
    }

    @ViewBuilder func content(model: CloudV2Model) -> some View {
        switch self {
        case .pairing: V2PairingSheet(model: model)
        case let .moduleName(id, name): V2ModuleNameEditor(model: model, moduleID: id, initialName: name)
        }
    }
}

struct V2ConnectionSections: View {
    @ObservedObject var model: CloudV2Model
    @Binding var presentation: V2SettingsSheet?

    var body: some View {
        Group {
            Section("设备") {
                ForEach(model.modules, id: \.module_id) { module in
                    HStack {
                        Button { Task { await model.selectModule(module.module_id) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.moduleName(module.module_id)).foregroundStyle(.primary)
                                    Text(module.online ? "在线" : "离线")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedModuleID == module.module_id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.blocksSwitch)
                        .accessibilityIdentifier("module-" + module.module_id)
                        Button {
                            presentation = .moduleName(id: module.module_id, name: model.moduleName(module.module_id))
                        } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("修改模块名称")
                        .accessibilityIdentifier("rename-" + module.module_id)
                    }
                }
                Button("添加设备") { presentation = .pairing }
                    .disabled(model.blocksSwitch || !model.pairingAvailable)
                    .accessibilityIdentifier("v2-add-device")
                if model.configuration != nil {
                    Text(model.userStatus).font(.footnote).foregroundStyle(.secondary)
                } else if !model.pairingAvailable {
                    Text("此安装未配置设备配对服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

    }
}

private struct V2ModuleNameEditor: View {
    @ObservedObject var model: CloudV2Model
    let moduleID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(model: CloudV2Model, moduleID: String, initialName: String) {
        self.model = model
        self.moduleID = moduleID
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("号卡名称", text: $name)
                        .accessibilityIdentifier("module-name")
                }
            }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("模块名称")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            model.renameModule(moduleID, name: name)
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct V2PairingSheet: View {
    @ObservedObject var model: CloudV2Model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var found: V2PairingLookup?
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("输入电脑网页上显示的 8 位连接码。")
                    TextField("8 位连接码", text: $code)
                        .focused($codeFocused)
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
                        Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(messageIsError ? A1Palette.negative : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
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
            .safeAreaInset(edge: .bottom) {
                if busy {
                    ProgressView(found == nil ? "正在查找设备…" : "正在添加设备…")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    @MainActor private func lookup() async {
        codeFocused = false
        busy = true; message = nil; messageIsError = false
        defer { busy = false }
        do { found = try await model.lookupPairing(code: code) }
        catch { message = model.pairingErrorMessage(error); messageIsError = true }
    }

    @MainActor private func add() async {
        guard let found else { return }
        codeFocused = false
        busy = true; message = nil; messageIsError = false
        defer { busy = false }
        if await model.addPairedDevice(code: code, device: found) { dismiss() }
        else { message = model.error ?? "暂时无法添加设备，请稍后重试。"; messageIsError = true }
    }
}
