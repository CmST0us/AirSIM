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
    private let initialName: String
    @FocusState private var nameFocused: Bool
    @State private var showsDiscardConfirmation = false

    init(model: CloudV2Model, moduleID: String, initialName: String) {
        self.model = model
        self.moduleID = moduleID
        self.initialName = initialName
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("号卡名称", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .onChange(of: name) { value in
                            name = String(value.prefix(40))
                        }
                        .accessibilityIdentifier("module-name")
                } header: {
                    Text("名称")
                } footer: {
                    Text("名称仅保存在此设备，最多 40 个字符。留空恢复原名称。")
                }
            }
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background(A1Palette.background)
                .tint(A1Palette.accent)
                .navigationTitle("号卡名称")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            if name != initialName { showsDiscardConfirmation = true }
                            else { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", action: save)
                    }
                }
                .onAppear { nameFocused = true }
                .confirmationDialog("放弃名称更改？", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
                    Button("放弃更改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) { }
                }
        }
        .interactiveDismissDisabled(name != initialName)
    }

    private func save() {
        model.renameModule(moduleID, name: name)
        dismiss()
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

    init(model: CloudV2Model) {
        self.model = model
        let pending = model.pendingPairingClaim()
        _code = State(initialValue: pending?.code ?? "")
        _found = State(initialValue: pending?.device)
        _message = State(initialValue: pending == nil ? nil : "上次添加尚未完成。确认设备后会只重试原添加。")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: found == nil ? "simcard" : "checkmark.circle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(A1Palette.accent)
                            .frame(width: 72, height: 72)
                            .background(A1Palette.accentSoft, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        Text(found == nil ? "把号卡带在身边" : "确认你的设备")
                            .font(.title2.weight(.bold))
                        Text(found == nil ? "在电脑网页选择设备，再输入网页上的连接码。" : "核对设备信息，添加后即可使用这张号卡。")
                            .font(.body)
                            .foregroundStyle(A1Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("连接码")
                            .font(.subheadline.weight(.semibold))
                        TextField("8 位连接码", text: $code)
                            .focused($codeFocused)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .padding(16)
                            .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("v2-pairing-code")
                            .onChange(of: code) { value in
                                code = String(value.filter(\.isNumber).prefix(8))
                                found = nil; message = nil
                            }
                        Text("连接码在 5 分钟内有效。")
                            .font(.footnote)
                            .foregroundStyle(A1Palette.secondary)
                    }
                    if let found {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "simcard")
                                    .font(.title2)
                                    .foregroundStyle(A1Palette.accent)
                                Text(found.name)
                                    .font(.headline)
                                    .accessibilityIdentifier("v2-pairing-device-name")
                                Spacer(minLength: 0)
                            }
                            Divider()
                            LabeledContent("设备标识", value: found.short_id)
                            LabeledContent("状态", value: found.online ? "在线" : "等待联网")
                        }
                        .padding(20)
                        .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    if let message {
                        Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(messageIsError ? A1Palette.negative : A1Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Task {
                            if found == nil { await lookup() }
                            else { await add() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(A1Palette.onCard) }
                            Text(busy ? (found == nil ? "正在查找设备…" : "正在添加设备…") : (found == nil ? "查找设备" : "确认添加"))
                        }
                        .font(.headline)
                        .foregroundStyle(A1Palette.onCard)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(A1Palette.accentFill)
                    .disabled(code.count != 8 || busy)
                    .accessibilityIdentifier(found == nil ? "v2-pairing-lookup" : "v2-pairing-confirm")
                    if model.pendingPairingClaim() != nil {
                        Button("取消未完成的添加", role: .destructive) {
                            model.discardPairingPending()
                            code = ""; found = nil; message = nil
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(A1Palette.background)
            .foregroundStyle(A1Palette.ink)
            .tint(A1Palette.accent)
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("添加设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(busy && found != nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { codeFocused = false }
                }
            }

        }
        .interactiveDismissDisabled(busy && found != nil)
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
