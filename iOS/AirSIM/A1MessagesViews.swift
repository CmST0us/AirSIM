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
    @FocusState private var searching: Bool
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
            .onChange(of: wideLayout) { wide in
                selectInitialConversation()
                if !wide && !search.isEmpty { showingSearch = true }
            }
            .onChange(of: model.accountSMSThreads.map(\.id)) { _ in selectInitialConversation() }
        }
    }

    private var listContent: some View {
            VStack(spacing: 0) {
                if showingSearch || wideLayout {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(A1Palette.secondary)
                        TextField("搜索姓名、号码或短信", text: $search)
                            .focused($searching)
                            .submitLabel(.search)
                            .onSubmit { searching = false }
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("清除搜索").foregroundStyle(A1Palette.secondary)
                        .opacity(search.isEmpty ? 0 : 1)
                        .disabled(search.isEmpty).accessibilityHidden(search.isEmpty)
                    }
                        .font(A1Typography.font(15))
                        .padding(.leading, 12)
                        .background(A1Palette.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, wideLayout ? 24 : 12)
                        .accessibilityIdentifier("a1-message-search")
                }
                if !wideLayout {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill("全部", moduleID: nil)
                        ForEach(lines, id: \.self) { id in filterPill(model.lineTitle(moduleID: id), moduleID: id) }
                    }.padding(.horizontal, 20)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
                } else {
                    Menu {
                        Picker("筛选号卡", selection: $selectedLine) {
                            Text("所有会话").tag(String?.none)
                            ForEach(lines, id: \.self) { id in
                                A1ModuleLabel(title: model.lineTitle(moduleID: id), signal: model.moduleSignal(moduleID: id)).tag(Optional(id))
                            }
                        }
                    } label: {
                        HStack {
                            Group {
                                if let selectedLine {
                                    A1ModuleLabel(title: model.lineTitle(moduleID: selectedLine), signal: model.moduleSignal(moduleID: selectedLine))
                                } else { Text("所有会话") }
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .font(A1Typography.font(13, weight: .medium)).foregroundStyle(A1Palette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel("筛选号卡")
                    .accessibilityValue(selectedLine.map { "\(model.lineTitle(moduleID: $0))，\(model.moduleSignal(moduleID: $0).accessibilityDescription)" } ?? "所有会话")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                }
                List(selection: Binding(get: { selectedConversation }, set: { selectedConversation = $0 })) {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.id) {
                            conversationRow(thread)
                        }
                            .tag(thread.id)
                            .accessibilityIdentifier("sms-thread-\(thread.id.moduleID)-\(thread.id.peer)")
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(wideLayout && selectedConversation == thread.id ? A1Palette.accentSoft : A1Palette.background)
                            .listRowSeparatorTint(A1Palette.separator)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in max(0, dimensions.width - (wideLayout ? 0 : 60)) }
                    }

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .refreshable { await model.refreshMessages() }
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if threads.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: search.isEmpty ? "message" : "magnifyingglass")
                                .font(.system(size: 32, weight: .light)).accessibilityHidden(true)
                            Text(search.isEmpty ? "暂无短信" : "未找到短信")
                                .font(A1Typography.font(17, weight: .medium))
                            Text(search.isEmpty ? "收到或发送的短信会显示在这里" : "试试其他姓名、号码或关键词")
                                .font(A1Typography.font(14))
                            if !search.isEmpty {
                                Button("清除搜索") { search = ""; searching = false }
                                    .frame(minHeight: 44)
                            } else if selectedLine != nil {
                                Button("查看所有号卡") { selectedLine = nil }.frame(minHeight: 44)
                            } else {
                                if model.pairedAndroidAgents.isEmpty, let onSettings {
                                    Button("添加设备", action: onSettings).frame(minHeight: 44)
                                } else {
                                    Button("新信息") { showingComposer = true }.frame(minHeight: 44)
                                }
                            }
                        }
                        .foregroundStyle(A1Palette.secondary).tint(A1Palette.linkBlue)
                        .multilineTextAlignment(.center).padding(24)
                    }
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background { A1Palette.background.ignoresSafeArea() }
            .navigationTitle("短信")
            .navigationBarTitleDisplayMode(wideLayout ? .inline : .large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !wideLayout {
                        Button {
                            showingSearch.toggle()
                            searching = showingSearch
                            if !showingSearch { search = "" }
                        } label: { Label(showingSearch ? "结束搜索" : "搜索短信", systemImage: showingSearch ? "xmark" : "magnifyingglass") }
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

    private func filterPill(_ title: String, moduleID: String?) -> some View {
        Button { selectedLine = moduleID } label: {
            HStack(spacing: 6) {
                if let moduleID {
                    A1ModuleLabel(title: title, signal: model.moduleSignal(moduleID: moduleID))
                } else { Text(title) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selectedLine == moduleID ? .white : A1Palette.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(selectedLine == moduleID ? A1Palette.accentFill : A1Palette.surface, in: Capsule())
            .frame(minHeight: 44)
        }.buttonStyle(A1PressButtonStyle())
        .accessibilityAddTraits(selectedLine == moduleID ? .isSelected : [])
        .accessibilityIdentifier(moduleID.map { "sms-filter-" + $0 } ?? "sms-filter-all")
    }

    private func conversationRow(_ thread: AccountSMSThread) -> some View {
        let contact = contacts.contact(for: thread.id.peer)
        return HStack(alignment: .top, spacing: 12) {
            A1Avatar(name: contact?.name ?? thread.id.peer, photoData: contact?.photoData, size: 48)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
                    Text(contacts.displayName(for: thread.id.peer))
                        .font(.body.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(A1SMSDate.short(thread.lastMessage.timestamp))
                        .font(.caption).monospacedDigit().foregroundStyle(A1Palette.secondary)
                        .layoutPriority(1)
                }
                Text(thread.lastMessage.text)
                    .font(.subheadline).foregroundStyle(A1Palette.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                A1LineBadge(title: model.lineTitle(moduleID: thread.id.moduleID),
                            signal: model.moduleSignal(moduleID: thread.id.moduleID),
                            active: thread.id.moduleID == model.cloudV2?.selectedModuleID)
            }
        }
        .padding(.vertical, 16).contentShape(Rectangle()).foregroundStyle(A1Palette.ink)
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
        VStack(spacing: 8) {
            if let sendStatus { Text(sendStatus).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative) }
            A1ModuleLabel(title: "发送自 \(model.lineTitle(moduleID: conversation.moduleID))", signal: model.moduleSignal(moduleID: conversation.moduleID))
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
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if showsTimestamp(at: index) {
                                Text(A1SMSDate.heading(message.timestamp))
                                    .font(A1Typography.font(12)).foregroundStyle(A1Palette.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(A1Palette.soft, in: Capsule())
                                    .padding(.top, index == 0 ? 20 : 24).padding(.bottom, 16)
                            }
                            messageBubble(message)
                                .padding(.top, showsTimestamp(at: index) ? 0 : messageSpacing(at: index))
                                .id(message.id)
                        }
                        if scrollsStatus { senderStatus.padding(.top, 16) }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: A1SMSContentHeight.self, value: content.size.height)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
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
            VStack(spacing: 8) {
                if !scrollsStatus { senderStatus }
                A1SMSComposerBar(text: draft, canSend: canSend, sending: sending, asset: embedded ? "a1-duo-sms-send" : assetPrefix + "send", send: send)
            }.padding(.horizontal, 20).padding(.bottom, 10).padding(.top, 12)
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
                    Section("发送号卡") { A1ModuleLabel(title: model.lineTitle(moduleID: conversation.moduleID), signal: model.moduleSignal(moduleID: conversation.moduleID)) }
                }
                .navigationTitle("会话信息").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingInfo = false } } }
            }
        }
    }

    private func showsTimestamp(at index: Int) -> Bool {
        index == 0 || messages[index].timestamp.timeIntervalSince(messages[index - 1].timestamp) >= 300
            || !Calendar.current.isDate(messages[index].timestamp, inSameDayAs: messages[index - 1].timestamp)
    }

    private func messageSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return messages[index - 1].direction == messages[index].direction ? 8 : 16
    }

    private func messageBubble(_ message: AccountSMSMessage) -> some View {
        let outgoing = message.direction == "outgoing"
        return HStack(alignment: .top) {
            if outgoing { Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 56) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 8) {
                Text(message.text).font(A1Typography.font(17))
                    .textSelection(.enabled)
                    .frame(minHeight: 21)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(outgoing ? .white : A1Palette.ink)
                    .background(outgoing ? A1Palette.accentFill : A1Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if outgoing {
                    if message.canRetry {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(message.statusText).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative)
                            Button {
                                sending = true
                                Task {
                                    let outcome = await model.retrySMS(message)
                                    sending = false
                                    showOutcome(outcome)
                                }
                            } label: {
                                A1ModuleLabel(title: "使用\(model.lineTitle(moduleID: conversation.moduleID))重试", signal: model.moduleSignal(moduleID: conversation.moduleID))
                            }
                            .font(A1Typography.font(14, weight: .medium)).foregroundStyle(A1Palette.linkBlue)
                            .frame(minHeight: 44)
                            .disabled(sending || !model.canSendSMS(in: conversation))
                            .accessibilityIdentifier("a1-message-retry")
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    } else if message.state != "sent" {
                        Text(message.statusText)
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

private struct A1SMSComposerBar: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    let canSend: Bool
    let sending: Bool
    let asset: String
    let send: () -> Void
    @FocusState private var editing: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("短信", text: $text, axis: .vertical)
                .focused($editing)
                .font(A1Typography.font(17)).lineLimit(1...((dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact) ? 1 : 5))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(minHeight: 46)
                .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(editing ? A1Palette.accent : A1Palette.separator, lineWidth: 1))
                .accessibilityLabel("短信内容").accessibilityIdentifier("message-reply")
            Button(action: send) {
                Group {
                    if sending { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(canSend ? .white : A1Palette.secondary) }
                }
                .frame(width: 44, height: 44)
                .background(canSend || sending ? A1Palette.accentFill : A1Palette.gray, in: Circle())
            }.buttonStyle(A1PressButtonStyle()).disabled(!canSend)
                .accessibilityLabel(sending ? "正在发送" : "发送").accessibilityIdentifier("message-send")
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
    @State private var confirmingDiscard = false
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
    private var hasUnassignedDraft: Bool {
        conversation?.peer.isEmpty != false && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var suggestions: [ContactStore.Contact] {
        guard !recipient.isEmpty, contacts.contact(for: recipient) == nil else { return [] }
        return Array(contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(recipient) || $0.phones.contains { $0.contains(recipient) }
        }.prefix(5))
    }

    private var scrollsStatus: Bool { dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact }
    private var senderStatus: some View {
        VStack(spacing: 8) {
            if let sendStatus { Text(sendStatus).font(A1Typography.font(12)).foregroundStyle(A1Palette.negative) }
            A1ModuleLabel(title: "发送自 \(model.lineTitle(moduleID: conversation?.moduleID ?? selectedLine))", signal: model.moduleSignal(moduleID: conversation?.moduleID ?? selectedLine))
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
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        Button { selectedLine = line.id; switchDraft() } label: {
                            A1ModuleLabel(title: model.lineTitle(moduleID: line.id), signal: model.moduleSignal(moduleID: line.id))
                        }
                            .accessibilityIdentifier("sms-compose-line-" + line.id)
                    }
                } label: {
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                        Text("发送号卡").foregroundStyle(A1Palette.ink)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        A1ModuleLabel(title: model.lineTitle(moduleID: conversation?.moduleID ?? selectedLine), signal: model.moduleSignal(moduleID: conversation?.moduleID ?? selectedLine))
                        A1AssetIcon("a1-detail-down")
                    }.font(.subheadline).padding(16).background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.disabled(lockedConversation != nil)
                    .accessibilityIdentifier("sms-compose-line-picker")
                if scrollsStatus { senderStatus }
            }
            .padding(.horizontal, 20).padding(.top, 8)
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
                ), canSend: canSend, sending: sending, asset: "a1-sms-thread-send", send: send)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .background(A1Palette.background)
            }
            .background(A1Palette.background).foregroundStyle(A1Palette.ink)
            .navigationTitle("新信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(A1Palette.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") {
                    switchDraft()
                    if hasUnassignedDraft { confirmingDiscard = true } else { dismiss() }
                }.disabled(sending) }
            }
            .interactiveDismissDisabled(sending || hasUnassignedDraft)
            .confirmationDialog("放弃这条短信？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃短信", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            } message: {
                Text("尚未选择收件人，关闭后这段内容不会保留。")
            }
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
