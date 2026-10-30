import SwiftUI

struct A1MessagesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Binding var pendingRecipient: String?
    @Binding var pendingConversation: String?
    var onSettings: (() -> Void)? = nil
    @Environment(\.a1UsesWideLayout) private var wideLayout
    @State private var search = ""
    @State private var showingSearch = false
    @State private var selectedLine: String?
    @State private var showingComposer = false

    private var selectedConversation: SMSConversationID? {
        get { model.selectedSMSConversation }
        nonmutating set { model.selectedSMSConversation = newValue }
    }

    private var threads: [AccountSMSThread] {
        model.accountSMSThreads.filter { thread in
            (selectedLine == nil || thread.id.moduleID == selectedLine)
                && (search.isEmpty || contacts.displayName(for: thread.id.peer).localizedCaseInsensitiveContains(search)
                    || thread.id.peer.contains(search)
                    || thread.messages.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }
    }
    private var lines: [String] {
        Array(Set(model.pairedAndroidAgents.map(\.id) + model.accountSMSThreads.map { $0.id.moduleID })).sorted()
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                listContent
                    .navigationSplitViewColumnWidth(A1Layout.masterColumnWidth(totalWidth: geometry.size.width))
            } detail: {
                if let conversation = selectedConversation {
                    A1MessageThreadView(conversation: conversation, embedded: wideLayout,
                                        showsContentTitle: horizontalSizeClass == .regular && !wideLayout)
                        .id(conversation)
                } else {
                    Text("选择一条会话")
                        .font(A1Typography.font(17)).foregroundStyle(A1Palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(A1Palette.background)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .environment(\.horizontalSizeClass, wideLayout ? .regular : .compact)
            .sheet(isPresented: $showingComposer, onDismiss: { pendingRecipient = nil }) {
                A1NewMessageView(initialRecipient: pendingRecipient ?? "")
            }
            .task { await model.loadMessagesFromAgent(silently: true) }
            .onAppear { openPendingConversation(); openPendingComposer() }
            .onChange(of: pendingConversation) { _ in openPendingConversation() }
            .onChange(of: pendingRecipient) { _ in openPendingComposer() }
            .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
                showingComposer = false
                pendingRecipient = nil
            }

            .onAppear { selectInitialConversation() }
            .onChange(of: wideLayout) { _ in selectInitialConversation() }
            .onChange(of: model.accountSMSThreads.map(\.id)) { _ in selectInitialConversation() }
        }
    }

    private var listContent: some View {
            VStack(spacing: 0) {
                if showingSearch || wideLayout {
                    HStack(spacing: 8) {
                        if wideLayout { A1AssetIcon("a1-duo-sms-search") }
                        TextField("搜索姓名、号码或短信", text: $search)
                            .submitLabel(.search)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                            }.accessibilityLabel("清除搜索").foregroundStyle(A1Palette.secondary)
                        }
                    }
                        .font(A1Typography.font(15))
                        .padding(12)
                        .background(A1Palette.soft, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .accessibilityIdentifier("a1-message-search")
                }
                if !wideLayout {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill("全部", moduleID: nil)
                        ForEach(lines, id: \.self) { id in filterPill(model.lineTitle(moduleID: id), moduleID: id) }
                    }.padding(.horizontal, 24)
                }
                .padding(.top, 20)
                .padding(.bottom, 18)
                } else {
                    Menu {
                        Button("所有会话") { selectedLine = nil }
                        ForEach(lines, id: \.self) { id in
                            Button(model.lineTitle(moduleID: id)) { selectedLine = id }
                        }
                    } label: {
                        Text(selectedLine.map { model.lineTitle(moduleID: $0) } ?? "所有会话")
                            .font(A1Typography.font(13, weight: .medium)).foregroundStyle(A1Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("筛选号卡")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
                }
                if let status = model.cloudV2?.messageListStatus {
                    HStack {
                        Text(status).font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                        Spacer()
                        if let onSettings { Button("查看号卡", action: onSettings).font(A1Typography.font(12)).frame(minHeight: 44) }
                    }.padding(.horizontal, 24)
                }
                if model.cloudV2?.hasMessageGap == true {
                    Text("部分短信未同步，记录可能不完整")
                        .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                        .padding(.horizontal, 24)
                }
                List(selection: Binding(get: { selectedConversation }, set: { selectedConversation = $0 })) {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.id) {
                            if wideLayout { wideConversationRow(thread) } else { conversationRow(thread) }
                        }
                            .tag(thread.id)
                            .accessibilityIdentifier("sms-thread-\(thread.id.moduleID)-\(thread.id.peer)")
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                            .listRowBackground(wideLayout && selectedConversation == thread.id ? A1Palette.soft : A1Palette.background)
                            .listRowSeparatorTint(A1Palette.separator)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in max(0, dimensions.width - (wideLayout ? 0 : 60)) }
                    }
                    if !threads.isEmpty && !wideLayout {
                        Text("仅显示云端号码的短信")
                            .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 18)
                            .listRowSeparator(.hidden).listRowBackground(A1Palette.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .refreshable { await model.refreshMessages() }
                .overlay {
                    if threads.isEmpty {
                        Text(search.isEmpty ? "暂无短信" : "未找到短信")
                            .font(A1Typography.font(17)).foregroundStyle(A1Palette.secondary)
                    }
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(A1Palette.background)
            .navigationTitle("短信")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !wideLayout {
                        Button { showingSearch.toggle() } label: { Label("搜索短信", systemImage: "magnifyingglass") }
                    }
                    Button { showingComposer = true } label: { Label("新信息", systemImage: "square.and.pencil") }
                        .accessibilityIdentifier("a1-message-compose")
                }
            }
    }

    private func selectInitialConversation() {
        if wideLayout && selectedConversation == nil { selectedConversation = threads.first?.id }
    }

    private func openConversation(_ conversation: SMSConversationID) {
        selectedConversation = conversation
    }

    private func wideConversationRow(_ thread: AccountSMSThread) -> some View {
        let contact = contacts.contact(for: thread.id.peer)
        return HStack(spacing: 12) {
            A1Avatar(name: contact?.name ?? thread.id.peer, photoData: contact?.photoData, size: 44, fontSize: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(contacts.displayName(for: thread.id.peer))
                    .font(A1Typography.font(17, weight: .medium)).foregroundStyle(A1Palette.ink).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text("\(model.lineTitle(moduleID: thread.id.moduleID)) · \(thread.lastMessage.text)")
                    .font(A1Typography.font(13)).foregroundStyle(A1Palette.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).frame(minHeight: 70).contentShape(Rectangle())
    }

    private func filterPill(_ title: String, moduleID: String?) -> some View {
        Button { selectedLine = moduleID } label: {
            Text(title).font(A1Typography.font(13, weight: .medium))
                .foregroundStyle(selectedLine == moduleID ? .white : A1Palette.secondary)
                .padding(.horizontal, 20)
                .frame(minWidth: moduleID == nil ? 70 : 130, minHeight: 36)
                .padding(.vertical, 6)
                .background(selectedLine == moduleID ? A1Palette.blue : A1Palette.soft, in: Capsule())
                .frame(minHeight: 44)
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selectedLine == moduleID ? .isSelected : [])
        .accessibilityIdentifier(moduleID.map { "sms-filter-" + $0 } ?? "sms-filter-all")
    }

    private func conversationRow(_ thread: AccountSMSThread) -> some View {
        let contact = contacts.contact(for: thread.id.peer)
        return HStack(spacing: 12) {
            A1Avatar(name: contact?.name ?? thread.id.peer, photoData: contact?.photoData, size: 48, fontSize: 17.76)
            VStack(alignment: .leading, spacing: 4) {
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
                    Text(contacts.displayName(for: thread.id.peer))
                        .font(A1Typography.font(17, weight: .medium)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(A1SMSDate.short(thread.lastMessage.timestamp))
                        .font(.caption).foregroundStyle(A1Palette.secondary)
                }
                Text(thread.lastMessage.text).font(A1Typography.font(13))
                    .foregroundStyle(A1Palette.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Text(model.lineTitle(moduleID: thread.id.moduleID))
                    .font(A1Typography.font(11, weight: .medium))
                    .foregroundStyle(thread.id.moduleID == model.cloudV2?.selectedModuleID ? A1Palette.linkBlue : A1Palette.secondary)
            }
        }.padding(.vertical, 12).frame(minHeight: 103).contentShape(Rectangle()).foregroundStyle(A1Palette.ink)
    }

    private func openPendingComposer() {
        guard pendingRecipient != nil else { return }
        selectedConversation = nil
        showingComposer = true
    }
    private func openPendingConversation() {
        guard let peer = pendingConversation, let conversation = model.smsConversation(to: peer) else { return }
        showingComposer = false
        openConversation(conversation)
        pendingConversation = nil
    }
}

private struct A1MessageThreadView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    let conversation: SMSConversationID
    var embedded = false
    var showsContentTitle = false
    @State private var sending = false
    @State private var showingInfo = false
    @State private var sendStatus: String?
    @State private var positionedHistory = false
    private var messages: [AccountSMSMessage] {
        model.accountSMSThreads.first { $0.id == conversation }?.messages ?? []
    }
    private var draft: Binding<String> {
        Binding(get: { model.smsDraft(for: conversation) }, set: { model.setSMSDraft($0, for: conversation) })
    }
    private var canSend: Bool {
        !sending && model.canSendSMS(in: conversation)
            && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var scrollsStatus: Bool { dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact }
    private var failed: Bool { messages.contains { $0.canRetry } }
    private var senderStatus: some View {
        VStack(spacing: 12) {
            if let sendStatus { Text(sendStatus).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative) }
            Text("发送自 \(model.lineTitle(moduleID: conversation.moduleID))")
                .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
        }
    }
    private var assetPrefix: String { failed ? "a1-sms-failure-" : "a1-sms-thread-" }

    var body: some View {
        VStack(spacing: 0) {
            if showsContentTitle {
                Text(contacts.displayName(for: conversation.peer))
                    .font(A1Typography.font(22, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                    LazyVStack(spacing: 0) {
                        if let first = messages.first {
                            Text(A1SMSDate.heading(first.timestamp))
                                .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                                .frame(minHeight: 17)
                                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 16 : 32)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            messageBubble(message)
                                .padding(.top, messageSpacing(at: index))
                                .id(message.id)
                        }
                        if scrollsStatus { senderStatus.padding(.top, 16) }
                    }.padding(.horizontal, 24).padding(.bottom, 20)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: A1SMSContentHeight.self, value: content.size.height)
                            }
                        }
                    }
                    .onPreferenceChange(A1SMSContentHeight.self) { height in
                        guard !positionedHistory, viewport.size.height > 0, height > 0, let last = messages.last else { return }
                        positionedHistory = true
                        if height > viewport.size.height { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            VStack(spacing: 16) {
                if !scrollsStatus { senderStatus }
                A1SMSComposerBar(text: draft, canSend: canSend, asset: embedded ? "a1-duo-sms-send" : assetPrefix + "send", send: send)
            }.padding(.horizontal, 24).padding(.bottom, 10).padding(.top, 12)
        }
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .foregroundStyle(A1Palette.ink).background(A1Palette.background)
        .navigationTitle(contacts.displayName(for: conversation.peer))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingInfo = true } label: { Label("会话信息", systemImage: "info.circle") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in showingInfo = false }
        .onChange(of: model.smsSendOutcome(for: conversation)) { outcome in
            if let outcome { showOutcome(outcome) }
        }
        .onAppear {
            if let outcome = model.smsSendOutcome(for: conversation) { showOutcome(outcome) }
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                Form {
                    Section("联系人") {
                        Text(contacts.displayName(for: conversation.peer))
                        Text(A1PhonePresentation.display(conversation.peer)).textSelection(.enabled)
                    }
                    Section("发送号卡") { Text(model.lineTitle(moduleID: conversation.moduleID)) }
                }
                .navigationTitle("会话信息").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingInfo = false } } }
            }
        }
    }

    private func messageSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 19 }
        if embedded { return 47 }
        if messages[index - 1].direction == "outgoing" { return 15 }
        return messages[index].canRetry ? 38 : 50
    }

    private func messageBubble(_ message: AccountSMSMessage) -> some View {
        let outgoing = message.direction == "outgoing"
        return HStack(alignment: .top) {
            if outgoing { Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 56) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: message.canRetry ? 22 : 18) {
                Text(message.text).font(A1Typography.font(17))
                    .textSelection(.enabled)
                    .frame(minHeight: 21)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(outgoing ? .white : A1Palette.ink)
                    .background(outgoing ? A1Palette.blue : A1Palette.soft, in: RoundedRectangle(cornerRadius: 20))
                if outgoing {
                    if message.canRetry {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.statusText).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative)
                            Button("使用\(model.lineTitle(moduleID: conversation.moduleID))重试") {
                                sending = true
                                Task {
                                    let outcome = await model.retrySMS(message)
                                    sending = false
                                    showOutcome(outcome)
                                }
                            }
                            .font(A1Typography.font(14, weight: .medium)).foregroundStyle(A1Palette.linkBlue)
                            .frame(minHeight: 44)
                            .disabled(sending || !model.canSendSMS(in: conversation))
                            .accessibilityIdentifier("a1-message-retry")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else if !embedded || message.state != "sent" {
                        Text(message.state == "sent" ? "发送自 \(model.lineTitle(moduleID: conversation.moduleID))" : message.statusText)
                            .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                    }
                }
            }
            if !outgoing { Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 56) }
        }
    }

    private func send() {
        guard canSend else { return }
        let body = draft.wrappedValue
        sending = true
        Task {
            let outcome = await model.sendSMS(in: conversation, content: body)
            sending = false
            showOutcome(outcome)
            if case .sent = outcome, draft.wrappedValue == body { draft.wrappedValue = "" }
        }
    }
    private func showOutcome(_ outcome: SMSSendOutcome) {
        switch outcome {
        case .sent: sendStatus = nil
        case .notSent: sendStatus = "未发送，草稿已保留"
        case .unknown: sendStatus = "发送结果待核对，请勿重复发送"
        }
    }
}

private struct A1SMSIconButton: View {
    let asset: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            A1AssetIcon(asset).frame(width: 44, height: 44).background(A1Palette.soft, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

private struct A1SMSComposerBar: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    let canSend: Bool
    let asset: String
    let send: () -> Void
    @FocusState private var editing: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("短信", text: $text, axis: .vertical)
                .focused($editing)
                .font(A1Typography.font(17)).lineLimit(1...((dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact) ? 1 : 5))
                .padding(.horizontal, 15).padding(.vertical, 11)
                .frame(minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(A1Palette.separator, lineWidth: 1))
                .accessibilityLabel("短信内容").accessibilityIdentifier("message-reply")
            Button(action: send) {
                A1AssetIcon(asset, tint: canSend ? .white : A1Palette.secondary).frame(width: 44, height: 44)
                    .background(canSend ? A1Palette.blue : A1Palette.gray, in: Circle())
            }.buttonStyle(.plain).disabled(!canSend)
                .accessibilityLabel("发送").accessibilityIdentifier("message-send")
        }
        .onDisappear { editing = false }
    }
}

private enum A1SMSDate {
    static func short(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    static func heading(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? "今天 " : date.formatted(date: .abbreviated, time: .omitted) + " ")
            + date.formatted(date: .omitted, time: .shortened)
    }
}

private struct A1NewMessageView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipient: String
    @State private var selectedLine: String?
    @State private var content = ""
    @State private var sending = false
    @State private var showingContacts = false
    @State private var lockedConversation: SMSConversationID?
    @State private var sendStatus: String?
    @State private var initialized = false
    @State private var draftConversation: SMSConversationID?
    @State private var lastSubmittedText: String?
    @FocusState private var editingRecipient: Bool

    init(initialRecipient: String) { _recipient = State(initialValue: initialRecipient) }

    private var conversation: SMSConversationID? {
        lockedConversation ?? model.smsConversation(to: ContactStore.normalized(recipient), moduleID: selectedLine)
    }
    private var canSend: Bool {
        guard let conversation, !conversation.peer.isEmpty else { return false }
        return !sending && model.canSendSMS(in: conversation)
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var suggestions: [ContactStore.Contact] {
        guard !recipient.isEmpty, contacts.contact(for: recipient) == nil else { return [] }
        return Array(contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(recipient) || $0.phones.contains { $0.contains(recipient) }
        }.prefix(5))
    }

    private var scrollsStatus: Bool { dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact }
    private var senderStatus: some View {
        VStack(spacing: 12) {
            if let sendStatus { Text(sendStatus).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative) }
            Text("发送自 \(model.lineTitle(moduleID: conversation?.moduleID ?? selectedLine))")
                .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                    Text("收件人：").font(A1Typography.font(15)).foregroundStyle(A1Palette.secondary)
                    TextField("输入号码或姓名", text: $recipient)
                        .font(A1Typography.font(15)).textContentType(.telephoneNumber)
                        .focused($editingRecipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .frame(minHeight: 44)
                        .onSubmit { switchDraft() }
                        .accessibilityIdentifier("a1-message-recipient")
                        .disabled(lockedConversation != nil)
                    Button { showingContacts = true } label: {
                        A1AssetIcon("a1-contacts-plus").frame(width: 44, height: 44)
                            .background(A1Palette.soft, in: Circle())
                    }.accessibilityLabel("从通讯录选择").disabled(lockedConversation != nil)
                }
                if let contact = contacts.contact(for: recipient) {
                    HStack(spacing: 10) {
                        A1Avatar(name: contact.name, photoData: contact.photoData, size: 36)
                        Text(contact.name).font(A1Typography.font(15, weight: .medium))
                        Spacer()
                    }.accessibilityLabel("已识别联系人：\(contact.name)")
                }
                if !suggestions.isEmpty && lockedConversation == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions) { contact in
                                Menu {
                                    ForEach(contact.phones, id: \.self) { phone in Button(phone) { recipient = phone; switchDraft() } }
                                } label: {
                                    Text(contact.name).font(A1Typography.font(14))
                                        .padding(12).background(A1Palette.soft, in: Capsule())
                                }
                            }
                        }
                    }
                }
                Menu {
                    ForEach(model.pairedAndroidAgents) { line in
                        Button(model.lineTitle(moduleID: line.id)) { selectedLine = line.id; switchDraft() }
                            .accessibilityIdentifier("sms-compose-line-" + line.id)
                    }
                } label: {
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                        Text("发送号卡").foregroundStyle(A1Palette.ink)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text(model.lineTitle(moduleID: conversation?.moduleID ?? selectedLine))
                        A1AssetIcon("a1-detail-down")
                    }.font(A1Typography.font(14)).padding(14).background(A1Palette.soft, in: Capsule())
                }.disabled(lockedConversation != nil)
                    .accessibilityIdentifier("sms-compose-line-picker")
                if scrollsStatus { senderStatus }
            }
            .padding(.horizontal, 24).padding(.top, 8)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if !scrollsStatus { senderStatus }
                A1SMSComposerBar(text: Binding(
                    get: { content },
                    set: { body in
                        switchDraft()
                        content = body
                        if let draftConversation { model.setSMSDraft(body, for: draftConversation) }
                    }
                ), canSend: canSend, asset: "a1-sms-thread-send", send: send)
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .background(A1Palette.background)
            }
            .background(A1Palette.background).foregroundStyle(A1Palette.ink)
            .navigationTitle("新信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { switchDraft(); dismiss() }.disabled(sending) }
            }
            .interactiveDismissDisabled(sending)
            .sheet(isPresented: $showingContacts) {
                A1SMSContactPicker { phone in recipient = phone; switchDraft(); showingContacts = false }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                selectedLine = model.cloudV2?.selectedModuleID
                switchDraft()
            }
            .onChange(of: editingRecipient) { editing in
                if !editing { switchDraft() }
            }
            .onChange(of: lockedConversation.flatMap { model.smsSendOutcome(for: $0) }) { outcome in
                if !sending, let outcome { showOutcome(outcome) }
            }
            .task { await contacts.loadIfAuthorized() }
        }
    }

    private func switchDraft() {
        let next = conversation.flatMap { $0.peer.isEmpty ? nil : $0 }
        guard next != draftConversation else { return }
        let hadTarget = draftConversation != nil
        if let draftConversation { model.setSMSDraft(content, for: draftConversation) }
        draftConversation = next
        if let next {
            if hadTarget || content.isEmpty { content = model.smsDraft(for: next) }
            model.setSMSDraft(content, for: next)
        } else if hadTarget {
            content = ""
        }
        sendStatus = nil
    }

    private func send() {
        switchDraft()
        guard canSend, let conversation else { return }
        let body = content
        lockedConversation = conversation
        lastSubmittedText = body
        model.setSMSDraft(body, for: conversation)
        sending = true
        Task {
            let outcome = await model.sendSMS(in: conversation, content: body)
            sending = false
            showOutcome(outcome)
        }
    }

    private func showOutcome(_ outcome: SMSSendOutcome) {
        switch outcome {
        case .sent:
            sendStatus = nil
            if let lastSubmittedText, content == lastSubmittedText {
                content = ""
                if let lockedConversation, model.smsDraft(for: lockedConversation) == lastSubmittedText {
                    model.setSMSDraft("", for: lockedConversation)
                }
                dismiss()
            }
        case .notSent: sendStatus = "未发送，草稿已保留。重试仍使用原号卡。"
        case .unknown: sendStatus = "发送结果待核对，请勿重复发送。草稿已保留。"
        }
    }
}

private struct A1SMSContactPicker: View {
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    let select: (String) -> Void
    private var filtered: [ContactStore.Contact] {
        contacts.contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.phones.contains { $0.contains(query) } }
    }
    var body: some View {
        NavigationStack {
            List {
                if !contacts.isAuthorized {
                    Button(contacts.authorizationState == .denied ? "前往系统设置" : "授权访问通讯录") {
                        if contacts.authorizationState == .denied {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } else { Task { await contacts.requestAccessAndLoad() } }
                    }
                }
                ForEach(filtered) { contact in
                    ForEach(contact.phones, id: \.self) { phone in
                        Button { select(phone) } label: {
                            HStack(spacing: 12) {
                                A1Avatar(name: contact.name, photoData: contact.photoData, size: 44, fontSize: 17)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name).font(A1Typography.font(17, weight: .medium)).foregroundStyle(A1Palette.ink)
                                    Text(A1PhonePresentation.display(phone)).font(.subheadline).foregroundStyle(A1Palette.secondary)
                                }
                            }.frame(minHeight: 70)
                        }
                        .accessibilityIdentifier("a1-sms-recipient-" + phone)
                    }
                }
            }
            .listStyle(.plain).searchable(text: $query, prompt: "搜索姓名或号码")
            .navigationTitle("选择联系人").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await contacts.loadIfAuthorized() }
        }
    }
}

private struct A1SMSContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
