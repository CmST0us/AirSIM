import SwiftUI

struct A1ContactsView: View {
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.openURL) private var openURL
    @Environment(\.a1UsesWideLayout) private var usesWideLayout
    let onCall: (String, String?) -> Void
    let onMessage: (String, String?) -> Void
    @State private var search = ""
    @State private var selectedContact: ContactStore.Contact?
    @State private var compactShowsDetail = false
    @State private var showingEditor = false

    private var filtered: [ContactStore.Contact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts.contacts }
        let phoneQuery = ContactStore.normalized(query)
        return contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || (!phoneQuery.isEmpty && $0.phones.contains { $0.contains(phoneQuery) })
        }
    }

    private var groups: [(key: String, contacts: [ContactStore.Contact])] {
        Dictionary(grouping: filtered, by: \.groupInitial)
            .map { (key: $0.key, contacts: $0.value) }
            .sorted { $0.key == "#" ? false : $1.key == "#" || $0.key < $1.key }
    }

    var body: some View {
        Group {
            if usesWideLayout {
                GeometryReader { geometry in
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        contactList
                            .navigationSplitViewColumnWidth(A1Layout.masterColumnWidth(totalWidth: geometry.size.width))
                    } detail: {
                        if let contact = selectedContact {
                            A1ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage, embedded: true)
                                .id(contact.id)
                        } else {
                            Text("选择联系人")
                                .font(A1Typography.font(17)).foregroundStyle(A1Palette.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(A1Palette.background)
                                .toolbar(.hidden, for: .navigationBar)
                        }
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            } else {
                NavigationStack {
                    contactList
                        .navigationDestination(isPresented: $compactShowsDetail) {
                            if let contact = selectedContact {
                                A1ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingEditor) { A1ContactEditor(contact: nil) }
        .task { await contacts.loadIfAuthorized(); reconcileSelection() }
        .onChange(of: contacts.contacts.map(\.id)) { _ in reconcileSelection() }
        .onChange(of: usesWideLayout) { wide in
            reconcileSelection()
            compactShowsDetail = !wide && selectedContact != nil
        }
    }

    private func reconcileSelection() {
        if let selectedContact, !contacts.contacts.contains(where: { $0.id == selectedContact.id }) {
            self.selectedContact = nil
            compactShowsDetail = false
        }
        if usesWideLayout && selectedContact == nil { selectedContact = filtered.first }
    }

    private var contactList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("联系人")
                    .font(A1Typography.font(32, weight: .bold))
                Spacer()
                if contacts.contacts.isEmpty {
                    Menu { Button("添加联系人") { showingEditor = true } } label: {
                        A1AssetIcon("a1-empty-more")
                            .frame(width: 44, height: 44)
                            .background(A1Palette.soft, in: Circle())
                    }
                    .accessibilityLabel("更多")
                } else {
                    Button { showingEditor = true } label: {
                        A1AssetIcon("a1-contacts-plus")
                            .frame(width: 44, height: 44)
                            .background(A1Palette.soft, in: Circle())
                    }
                    .accessibilityLabel("新增联系人")
                }
            }
            .frame(minHeight: 45)
            .padding(.top, 8)
            .padding(.horizontal, 24)
            if !contacts.contacts.isEmpty {
                HStack(spacing: 8) {
                    A1AssetIcon("a1-contacts-search")
                    TextField("搜索", text: $search)
                        .font(A1Typography.font(15))
                        .autocorrectionDisabled()
                        .accessibilityLabel("搜索姓名或号码")
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .foregroundStyle(A1Palette.secondary)
                        .accessibilityLabel("清除搜索")
                    }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(A1Palette.soft, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 17)
            }

            if contacts.contacts.isEmpty && !contacts.isAuthorized {
                authorizationView
            } else if filtered.isEmpty {
                if search.isEmpty {
                    A1EmptyContent(icon: "a1-empty-contacts", title: "还没有联系人",
                                   subtitle: "添加常用联系人，下次联系更方便。",
                                   actionTitle: "添加联系人", actionIcon: "a1-empty-plus", tint: A1Palette.blue) {
                        showingEditor = true
                    }
                } else {
                    Text("未找到联系人")
                        .font(A1Typography.font(17)).foregroundStyle(A1Palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        Text(group.key)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(A1Palette.secondary)
                            .frame(minHeight: 19)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                            .listRowSeparator(.hidden)
                        ForEach(group.contacts) { contact in
                            Button {
                                selectedContact = contact
                                compactShowsDetail = !usesWideLayout
                            } label: {
                                HStack(spacing: 12) {
                                    A1Avatar(name: contact.name, photoData: contact.photoData, size: 44, fontSize: 17)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.name).font(A1Typography.font(17, weight: .medium))
                                            .foregroundStyle(A1Palette.ink)
                                        Text(A1PhonePresentation.display(contact.phones.first ?? ""))
                                            .font(.footnote)
                                            .foregroundStyle(A1Palette.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    A1AssetIcon("a1-chevron")
                                }
                                .padding(.vertical, 10)
                                .frame(minHeight: 70)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("a1-contact-row-\(contact.id)")
                            .listRowBackground(usesWideLayout && selectedContact?.id == contact.id ? A1Palette.soft : A1Palette.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                            .listRowSeparatorTint(A1Palette.separator)
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .refreshable { await contacts.requestAccessAndLoad() }
                .scrollDismissesKeyboard(.interactively)
                Text("\(filtered.count) 位联系人")
                    .font(A1Typography.font(12))
                    .foregroundStyle(A1Palette.secondary)
                    .padding(.top, 18)
                    .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: usesWideLayout ? .infinity : 600)
        .frame(maxWidth: .infinity)
        .foregroundStyle(A1Palette.ink)
        .background(A1Palette.background)
        .navigationTitle("联系人")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var authorizationView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle").font(.largeTitle)
                Text(contacts.authorizationState == .denied ? "通讯录权限已关闭" : "授权访问通讯录")
                    .font(A1Typography.font(20, weight: .medium))
                Text("联系人保存在本机，用于显示来电姓名和选择收件人。")
                    .font(A1Typography.font(15))
                    .foregroundStyle(A1Palette.secondary)
                    .multilineTextAlignment(.center)
                Button(contacts.authorizationState == .denied ? "前往系统设置" : "授权访问通讯录") {
                    if contacts.authorizationState == .denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } else {
                        Task { await contacts.requestAccessAndLoad() }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct A1ContactDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let contact: ContactStore.Contact
    let onCall: (String, String?) -> Void
    let onMessage: (String, String?) -> Void
    var embedded = false
    @State private var showingEditor = false
    @State private var choosingCallNumber = false
    @State private var choosingMessageNumber = false

    private var current: ContactStore.Contact {
        contacts.contacts.first { $0.id == contact.id } ?? contact
    }
    private var preferredModuleID: String? { contacts.preferredModuleID(for: contact.id) }
    private var lineTitle: String { model.lineTitle(moduleID: preferredModuleID) }

    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                HStack {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer()
                    Text("联系人").font(A1Typography.font(17, weight: .medium))
                    Spacer()
                    Button("编辑") { showingEditor = true }
                        .font(A1Typography.font(15, weight: .medium))
                        .foregroundStyle(A1Palette.linkBlue)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("a1-contact-edit")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            ScrollView {
                VStack(spacing: 0) {
                    A1Avatar(name: current.name, photoData: current.photoData, size: 100, fontSize: 38)
                        .padding(.top, 25)
                    Text(current.name)
                        .font(A1Typography.font(30, weight: .medium))
                        .frame(minHeight: 42)
                        .padding(.top, 12)
                    Text("手机 \(A1PhonePresentation.display(current.phones.first ?? ""))")
                        .font(A1Typography.font(15))
                        .foregroundStyle(A1Palette.secondary)
                        .frame(minHeight: 21)
                        .padding(.top, 3)
                    lineMenu {
                        HStack(spacing: 9) {
                            Text(lineTitle).font(A1Typography.font(14, weight: .medium))
                            A1AssetIcon("a1-detail-down")
                        }
                        .foregroundStyle(A1Palette.linkBlue)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(minWidth: 190, minHeight: 44)
                        .background(A1Palette.soft, in: Capsule())
                    }
                    .padding(.top, 25)
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                        actionButton("呼叫", asset: "a1-detail-phone", color: A1Palette.green) {
                            if current.phones.count == 1, let phone = current.phones.first { onCall(phone, preferredModuleID) }
                            else { choosingCallNumber = true }
                        }
                        actionButton("短信", asset: "a1-detail-message", color: A1Palette.blue) {
                            if current.phones.count == 1, let phone = current.phones.first { onMessage(phone, preferredModuleID) }
                            else { choosingMessageNumber = true }
                        }.accessibilityIdentifier("a1-contact-message")
                    }
                    .padding(.top, 21)
                    VStack(spacing: 0) {
                        ForEach(current.phones, id: \.self) { phone in
                            Menu {
                                Button("呼叫") { onCall(phone, preferredModuleID) }
                                Button("发送短信") { onMessage(phone, preferredModuleID) }
                                Button("复制号码") { UIPasteboard.general.string = phone }
                            } label: {
                                informationRow("手机", value: A1PhonePresentation.display(phone))
                            }
                            Divider().overlay(A1Palette.separator)
                        }
                        lineMenu { informationRow("常用呼出号卡", value: lineTitle) }
                        Divider().overlay(A1Palette.separator)
                        Button { contacts.toggleFavorite(id: contact.id) } label: {
                            informationRow(contacts.isFavorite(id: contact.id) ? "移出常用联系人" : "加入常用联系人")
                        }
                    }
                    .padding(.top, 37)
                    Text("短信通过独立会话发送，通话记录不混入短信。")
                        .font(A1Typography.font(12))
                        .foregroundStyle(A1Palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 32)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(A1Palette.background)
        .foregroundStyle(A1Palette.ink)
        .navigationTitle("联系人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { showingEditor = true }
                        .accessibilityIdentifier("a1-contact-edit")
                }
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(isPresented: $showingEditor) { A1ContactEditor(contact: current) }
        .confirmationDialog("选择呼叫号码", isPresented: $choosingCallNumber, titleVisibility: .visible) {
            ForEach(current.phones, id: \.self) { phone in Button(phone) { onCall(phone, preferredModuleID) } }
        }
        .confirmationDialog("选择短信号码", isPresented: $choosingMessageNumber, titleVisibility: .visible) {
            ForEach(current.phones, id: \.self) { phone in Button(phone) { onMessage(phone, preferredModuleID) } }
        }
    }

    private func lineMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("跟随当前号卡") { contacts.setPreferredModuleID(nil, for: contact.id) }
            ForEach(model.pairedAndroidAgents) { line in
                Button(model.lineTitle(moduleID: line.id)) {
                    contacts.setPreferredModuleID(line.id, for: contact.id)
                }
            }
        } label: { label() }
        .accessibilityLabel("常用呼出号卡，\(lineTitle)")
    }

    private func informationRow(_ title: String, value: String? = nil) -> some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
            Text(title).font(A1Typography.font(15)).foregroundStyle(A1Palette.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let value {
                Text(value).font(A1Typography.font(13))
                    .foregroundStyle(A1Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            A1AssetIcon("a1-detail-chevron")
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func actionButton(_ title: String, asset: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                A1AssetIcon(asset)
                Text(title).font(A1Typography.font(15, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(current.phones.isEmpty)
    }
}

struct A1ContactEditor: View {
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    let contact: ContactStore.Contact?
    @State private var name: String
    @State private var phones: [String]
    @State private var saving = false
    @State private var saveError: String?

    init(contact: ContactStore.Contact?, initialPhones: [String] = [""]) {
        self.contact = contact
        _name = State(initialValue: contact?.name ?? "")
        _phones = State(initialValue: contact?.phones ?? initialPhones)
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phones.contains { !ContactStore.normalized($0).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("姓名") { TextField("姓名", text: $name).textContentType(.name) }
                Section("电话号码") {
                    ForEach(phones.indices, id: \.self) { index in
                        TextField("手机号码", text: $phones[index])
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                    .onDelete { indices in phones.remove(atOffsets: indices) }
                    Button("添加号码") { phones.append("") }
                }
                if let saveError { Section { Text(saveError).foregroundStyle(A1Palette.negative) } }
            }
            .navigationTitle(contact == nil ? "新增联系人" : "编辑联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("取消", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saving = true
                        Task {
                            let saved = await contacts.saveContact(id: contact?.id, name: name, phones: phones)
                            saving = false
                            if saved { dismiss() } else { saveError = contacts.errorMessage ?? "无法保存联系人" }
                        }
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
