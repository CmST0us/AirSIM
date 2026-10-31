import SwiftUI

struct A1CallsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.a1UsesWideLayout) private var usesWideLayout
    let onCall: (String, String?) -> Void
    let onMessage: (String, String?) -> Void
    let onContacts: () -> Void
    var onDial: () -> Void = {}
    @State private var showingHistory = false
    @State private var showingSearch = false
    @State private var selectedCall: CallRecord?
    @State private var presentedCall: CallRecord?
    @State private var pendingMessage: A1CallMessageRequest?
    @State private var selectedFavorite: ContactStore.Contact?
    @State private var wideSearch = ""

    private var history: [CallRecord] {
        model.callHistory.sorted { $0.startedAt > $1.startedAt }
    }

    private var filteredWideCalls: [CallRecord] {
        history.filter { A1CallPresentation.matches($0, query: wideSearch, contacts: contacts) }
    }

    private var compactBody: some View {
        NavigationStack {
            Group {
                if history.isEmpty && contacts.favoriteContacts.isEmpty {
                    emptyCalls
                } else {
                    homeList
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background { A1Palette.background.ignoresSafeArea() }
            .navigationTitle("通话")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索通话和联系人")
                }
            }
            .navigationDestination(isPresented: $showingHistory) {
                A1CallHistoryView(onMessage: onMessage)
            }
            .sheet(isPresented: $showingSearch, onDismiss: deliverPendingMessage) {
                A1CallSearchView(onCall: onCall) { number, moduleID in
                    pendingMessage = A1CallMessageRequest(number: number, moduleID: moduleID)
                    showingSearch = false
                }
            }
            .sheet(item: $presentedCall, onDismiss: deliverPendingMessage) { call in
                A1CallDetailsView(call: call) { number, moduleID in
                    pendingMessage = A1CallMessageRequest(number: number, moduleID: moduleID)
                    presentedCall = nil
                }
            }
            .confirmationDialog("选择号码", isPresented: Binding(
                get: { selectedFavorite != nil },
                set: { if !$0 { selectedFavorite = nil } }
            ), titleVisibility: .visible) {
                if let contact = selectedFavorite {
                    ForEach(contact.phones, id: \.self) { number in
                        Button(number) {
                            onCall(number, contacts.preferredModuleID(for: contact.id))
                        }
                    }
                }
                Button("取消", role: .cancel) { selectedFavorite = nil }
            }
        }
    }

    var body: some View {
        Group {
            if usesWideLayout {
                GeometryReader { geometry in
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        wideCallList
                            .navigationSplitViewColumnWidth(A1Layout.masterColumnWidth(totalWidth: geometry.size.width))
                    } detail: {
                        if let selectedCall {
                            A1WideCallDetailView(call: selectedCall, onMessage: onMessage)
                        } else {
                            Text("选择通话记录")
                                .font(A1Typography.font(17)).foregroundStyle(A1Palette.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(A1Palette.background)
                                .toolbar(.hidden, for: .navigationBar)
                        }
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            } else {
                compactBody
            }
        }
        .task { await contacts.loadIfAuthorized() }
        .onAppear(perform: reconcileSelection)
        .onChange(of: model.callHistory) { _ in reconcileSelection() }
        .onChange(of: usesWideLayout) { wide in
            if wide {
                selectedCall = presentedCall ?? selectedCall
                presentedCall = nil
            } else {
                presentedCall = selectedCall
            }
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        if let selectedCall {
            self.selectedCall = history.first(where: { $0.id == selectedCall.id })
        }
        if usesWideLayout && selectedCall == nil { selectedCall = history.first }
    }

    private var homeList: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("常用联系人", action: onContacts)
                favorites
                sectionHeading("最近通话") { showingHistory = true }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(A1Palette.background)
            if history.isEmpty {
                Text("暂无通话记录")
                    .foregroundStyle(A1Palette.secondary)
                    .listRowBackground(A1Palette.background)
            }
            ForEach(A1CallPresentation.days(history), id: \.self) { day in
                Section {
                    ForEach(history.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { call in
                        A1RecentCallRow(call: call, onDetails: { presentedCall = call })
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    }
                } header: {
                    Text(A1CallPresentation.dayTitle(day)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(A1Palette.secondary).textCase(nil)
                        .padding(.top, 8).padding(.bottom, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
    }

    private var emptyCalls: some View {
        A1EmptyContent(icon: "a1-empty-clock", title: "还没有通话记录",
                       subtitle: "拨打电话后，记录会显示在这里。",
                       actionTitle: "拨打第一个电话", actionIcon: "a1-empty-phone", tint: A1Palette.green,
                       action: onDial)
    }

    private var wideCallList: some View {
        VStack(spacing: 0) {
            if history.isEmpty {
                A1EmptyContent(icon: "a1-empty-clock", title: "还没有通话记录",
                               subtitle: "拨打电话后，记录会显示在这里。",
                               actionTitle: "拨打第一个电话", actionIcon: "a1-empty-phone", tint: A1Palette.green,
                               action: onDial)
            } else {
                HStack(spacing: 8) {
                    A1AssetIcon("a1-wide-search")
                    TextField("搜索", text: $wideSearch)
                        .font(A1Typography.font(15)).autocorrectionDisabled()
                        .accessibilityLabel("搜索通话和联系人")
                    if !wideSearch.isEmpty {
                        Button { wideSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .foregroundStyle(A1Palette.secondary)
                        .accessibilityLabel("清除搜索")
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(A1Palette.soft, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20).padding(.top, 16)
                Text("最近通话")
                    .font(A1Typography.font(13, weight: .medium)).foregroundStyle(A1Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                List {
                    if filteredWideCalls.isEmpty {
                        Text("没有匹配的通话")
                            .font(.body)
                            .foregroundStyle(A1Palette.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .listRowSeparator(.hidden)
                            .listRowBackground(A1Palette.background)
                    }
                    ForEach(A1CallPresentation.days(filteredWideCalls), id: \.self) { day in
                        Section {
                    ForEach(filteredWideCalls.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { call in
                        Button { selectedCall = call } label: {
                            HStack(spacing: 8) {
                                A1CallRowContent(call: call)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(A1Palette.secondary)
                            }
                            .padding(.vertical, 12)
                            .frame(minHeight: 72).contentShape(Rectangle())
                        }
                        .buttonStyle(A1RowButtonStyle())
                        .accessibilityLabel("\(contacts.displayName(for: call.number))的通话详情")
                        .accessibilityIdentifier("a1-wide-call-row-\(call.id)")
                        .listRowBackground(selectedCall?.id == call.id ? A1Palette.soft : A1Palette.background)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparatorTint(A1Palette.separator)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                        } header: {
                            Text(A1CallPresentation.dayTitle(day)).font(.subheadline.weight(.semibold)).textCase(nil)
                                .padding(.top, 8).padding(.bottom, 4)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListHeaderHeight, 0)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollDismissesKeyboard(.interactively)
                    }
        }
        .foregroundStyle(A1Palette.ink)
        .background { A1Palette.background.ignoresSafeArea() }
        .navigationTitle("通话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func deliverPendingMessage() {
        guard let request = pendingMessage else { return }
        pendingMessage = nil
        onMessage(request.number, request.moduleID)
    }

    private func sectionHeading(_ title: String, action: @escaping () -> Void) -> some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
            Text(title)
                .font(A1Typography.font(18, weight: .bold))
                .foregroundStyle(A1Palette.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Button("全部", action: action)
                .buttonStyle(.plain)
                .font(A1Typography.font(14, weight: .medium))
                .foregroundStyle(A1Palette.linkBlue)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("全部\(title)")
        }
        .frame(minHeight: 25)
    }

    @ViewBuilder private var favorites: some View {
        if contacts.favoriteContacts.isEmpty {
            Button(action: onContacts) {
                HStack(spacing: 12) {
                    Image(systemName: "star").font(.title2).foregroundStyle(A1Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("让常联系的人更近一点").font(.subheadline.weight(.semibold))
                        Text("从联系人添加收藏").font(.footnote).foregroundStyle(A1Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(A1PressButtonStyle())
        } else {
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))) {
                ForEach(Array(contacts.favoriteContacts.prefix(3))) { contact in
                    Button {
                        if contact.phones.count == 1, let number = contact.phones.first {
                            onCall(number, contacts.preferredModuleID(for: contact.id))
                        } else { selectedFavorite = contact }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            A1Avatar(name: contact.name, photoData: contact.photoData, size: 40, fontSize: 17)
                            Text(contact.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(A1Palette.ink).fixedSize(horizontal: false, vertical: true)
                            A1ModuleLabel(title: model.lineTitle(moduleID: contacts.preferredModuleID(for: contact.id)), signal: model.moduleSignal(moduleID: contacts.preferredModuleID(for: contact.id)))
                                .labelStyle(A1InlineModuleLabelStyle())
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .font(.caption).foregroundStyle(A1Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Label("呼叫", systemImage: "phone.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(A1Palette.accent)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(A1PressButtonStyle())
                    .disabled(contact.phones.isEmpty)
                }
            }
        }
    }

}

private struct A1RecentCallRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let call: CallRecord
    let onDetails: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { Task { await model.redial(call) } } label: {
                A1CallRowContent(call: call)
                    .contentShape(Rectangle())
            }
            .disabled(RecentCallDialPolicy.numberToDial(call.number) == nil)
            Button(action: onDetails) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(A1Palette.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(contacts.displayName(for: call.number))的通话详情")
        }
        .buttonStyle(A1RowButtonStyle())
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .listRowBackground(A1Palette.background)
        .listRowSeparatorTint(A1Palette.separator)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

private struct A1CallRowContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let call: CallRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            A1Avatar(name: contacts.displayName(for: call.number),
                     photoData: call.number.flatMap { contacts.contact(for: $0)?.photoData }, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                name
                if dynamicTypeSize.isAccessibilitySize {
                    stackedMetadata
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            direction
                            Text("·").accessibilityHidden(true)
                            line
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        stackedMetadata
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(A1Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            timestamp
                .font(.footnote)
                .foregroundStyle(A1Palette.secondary)
                .fixedSize()
        }
    }

    private var name: some View {
        Text(contacts.displayName(for: call.number))
            .font(.body.weight(.semibold))
            .foregroundStyle(call.missed ? A1Palette.negative : A1Palette.ink)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var timestamp: some View {
        Text(call.startedAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .monospacedDigit()
    }

    private var direction: some View {
        HStack(spacing: 4) {
            Image(systemName: call.missed ? "phone.down" : call.direction == "incoming" ? "arrow.down.left" : "arrow.up.right")
                .accessibilityHidden(true)
            Text(A1CallPresentation.direction(call))
        }
        .foregroundStyle(call.missed ? A1Palette.negative : A1Palette.secondary)
    }

    private var line: some View {
        A1ModuleLabel(title: A1CallPresentation.line(call, model: model), signal: model.isV2 && model.moduleID(for: call) == nil ? .unavailable : model.moduleSignal(moduleID: model.moduleID(for: call)))
            .labelStyle(A1InlineModuleLabelStyle())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stackedMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            direction
            line
        }
    }
}

private struct A1CallHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let onMessage: (String, String?) -> Void
    @State private var search = ""
    @State private var missedOnly = false
    @State private var selectedCall: CallRecord?
    @State private var pendingMessage: A1CallMessageRequest?

    private var calls: [CallRecord] {
        model.callHistory.filter {
            (!missedOnly || $0.missed) && A1CallPresentation.matches($0, query: search, contacts: contacts)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        List {
            Picker("通话类型", selection: $missedOnly) {
                Text("全部").tag(false)
                Text("未接").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if calls.isEmpty {
                Text(search.isEmpty ? "暂无通话记录" : "没有匹配的通话")
                    .foregroundStyle(A1Palette.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(A1CallPresentation.days(calls), id: \.self) { day in
                Section {
                    ForEach(calls.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { call in
                        A1RecentCallRow(call: call, onDetails: { selectedCall = call })
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    }
                } header: {
                    Text(A1CallPresentation.dayTitle(day)).font(.subheadline.weight(.semibold)).textCase(nil)
                        .padding(.top, 8).padding(.bottom, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListHeaderHeight, 0)
        .scrollContentBackground(.hidden)
        .background(A1Palette.background)
        .navigationTitle("最近通话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $search, prompt: "搜索姓名或号码")
        .sheet(item: $selectedCall, onDismiss: deliverPendingMessage) { call in
            A1CallDetailsView(call: call) { number, moduleID in
                pendingMessage = A1CallMessageRequest(number: number, moduleID: moduleID)
                selectedCall = nil
            }
        }
    }

    private func deliverPendingMessage() {
        guard let request = pendingMessage else { return }
        pendingMessage = nil
        onMessage(request.number, request.moduleID)
    }

}

private struct A1CallDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    let onMessage: (String, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        A1Avatar(name: contacts.displayName(for: call.number),
                                 photoData: call.number.flatMap { contacts.contact(for: $0)?.photoData }, size: 70)
                        Text(contacts.displayName(for: call.number))
                            .font(A1Typography.font(24, weight: .bold))
                        if let number = call.number {
                            Text(number).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                Section("通话信息") {
                    LabeledContent("类型", value: A1CallPresentation.direction(call))
                    LabeledContent("线路") {
                        A1ModuleLabel(title: A1CallPresentation.line(call, model: model), signal: model.isV2 && model.moduleID(for: call) == nil ? .unavailable : model.moduleSignal(moduleID: model.moduleID(for: call)))
                    }
                    LabeledContent("开始时间", value: call.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let ended = call.endedAt {
                        LabeledContent("结束时间", value: ended.formatted(date: .abbreviated, time: .standard))
                    }
                    LabeledContent("状态", value: A1CallPresentation.state(call.state))
                }
                if let number = RecentCallDialPolicy.numberToDial(call.number) {
                    Section {
                        Button("使用原线路回拨") {
                            dismiss()
                            Task { await model.redial(call) }
                        }
                        Button("发送短信") {
                            onMessage(number, model.moduleID(for: call))
                        }
                        .disabled(model.isV2 && model.moduleID(for: call) == nil)
                        if let contact = contacts.contact(for: number) {
                            Button(contacts.isFavorite(id: contact.id) ? "移出常用联系人" : "添加到常用联系人") {
                                contacts.toggleFavorite(id: contact.id)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(A1Palette.background)
            .tint(A1Palette.accent)
            .navigationTitle("通话详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct A1CallSearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    @Environment(\.dismiss) private var dismiss
    let onCall: (String, String?) -> Void
    let onMessage: (String, String?) -> Void
    @State private var search = ""
    @State private var selectedCall: CallRecord?
    @State private var pendingMessage: A1CallMessageRequest?

    private var matchingContacts: [ContactStore.Contact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberQuery = ContactStore.normalized(query)
        return contacts.contacts.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || (!numberQuery.isEmpty && $0.phones.contains { ContactStore.normalized($0).contains(numberQuery) })
        }
    }
    private var matchingCalls: [CallRecord] {
        model.callHistory.filter { A1CallPresentation.matches($0, query: search, contacts: contacts) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if matchingContacts.isEmpty && matchingCalls.isEmpty {
                    Text("没有匹配的联系人或通话").foregroundStyle(.secondary)
                }
                if !matchingContacts.isEmpty {
                    Section("联系人") {
                        ForEach(matchingContacts) { contact in
                            ForEach(contact.phones, id: \.self) { number in
                                Button {
                                    dismiss()
                                    onCall(number, contacts.preferredModuleID(for: contact.id))
                                } label: {
                                    HStack(spacing: 12) {
                                        A1Avatar(name: contact.name, photoData: contact.photoData, size: 44)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(contact.name).foregroundStyle(A1Palette.ink)
                                            Text(number).font(.subheadline).foregroundStyle(A1Palette.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(A1RowButtonStyle())
                                .listRowBackground(A1Palette.background)
                            }
                        }
                    }
                }
                if !matchingCalls.isEmpty {
                    Section("通话") {
                        ForEach(matchingCalls) { call in
                            A1RecentCallRow(call: call, onDetails: { selectedCall = call })
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListHeaderHeight, 0)
            .scrollContentBackground(.hidden)
            .background(A1Palette.background)
            .accessibilityIdentifier("a1-call-search-results")
            .searchable(text: $search, prompt: "搜索姓名或号码")
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $selectedCall, onDismiss: deliverPendingMessage) { call in
                A1CallDetailsView(call: call) { number, moduleID in
                    pendingMessage = A1CallMessageRequest(number: number, moduleID: moduleID)
                    selectedCall = nil
                }
            }
        }
    }

    private func deliverPendingMessage() {
        guard let request = pendingMessage else { return }
        pendingMessage = nil
        onMessage(request.number, request.moduleID)
    }

}

private struct A1CallMessageRequest {
    let number: String
    let moduleID: String?
}

private enum A1CallPresentation {
    static func days(_ calls: [CallRecord]) -> [Date] {
        Array(Set(calls.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >)
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    @MainActor static func line(_ call: CallRecord, model: AppModel) -> String {
        guard !model.isV2 || model.moduleID(for: call) != nil else { return "原线路不可用" }
        return model.lineTitle(moduleID: model.moduleID(for: call))
    }

    static func direction(_ call: CallRecord) -> String {
        if call.missed { return "未接" }
        return call.direction == "incoming" ? "呼入" : "呼出"
    }

    @MainActor static func matches(_ call: CallRecord, query: String, contacts: ContactStore) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberQuery = ContactStore.normalized(query)
        return query.isEmpty || contacts.displayName(for: call.number).localizedCaseInsensitiveContains(query)
            || (!numberQuery.isEmpty && ContactStore.normalized(call.number ?? "").contains(numberQuery))
    }

    static func state(_ state: String) -> String {
        switch state {
        case "incoming", "ringing": return "来电响铃"
        case "dialing": return "正在拨号"
        case "alerting": return "等待接听"
        case "active", "connected": return "通话中"
        case "held": return "保持"
        case "ended", "disconnected", "idle": return "已结束"
        default: return state
        }
    }
}

private struct A1WideCallDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var contacts: ContactStore
    let call: CallRecord
    let onMessage: (String, String?) -> Void
    @State private var showingInformation = false

    private var callableNumber: String? { RecentCallDialPolicy.numberToDial(call.number) }
    private var originalLineAvailable: Bool { !model.isV2 || model.moduleID(for: call) != nil }
    private var duration: String {
        guard let ended = call.endedAt else { return A1CallPresentation.state(call.state) }
        let seconds = max(0, Int(ended.timeIntervalSince(call.startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    A1Avatar(name: contacts.displayName(for: call.number),
                             photoData: call.number.flatMap { contacts.contact(for: $0)?.photoData }, size: 88, fontSize: 34)
                        .padding(.top, 24)
                    Text(contacts.displayName(for: call.number))
                        .font(A1Typography.font(29, weight: .medium))
                        .frame(minHeight: 41).padding(.top, 16)
                    Text(A1PhonePresentation.display(call.number ?? "未知号码"))
                        .font(.body).foregroundStyle(A1Palette.secondary)
                        .frame(minHeight: 24).padding(.top, 4)
                    Button { showingInformation = true } label: {
                        HStack(spacing: 9) {
                            A1ModuleLabel(title: A1CallPresentation.line(call, model: model), signal: model.isV2 && model.moduleID(for: call) == nil ? .unavailable : model.moduleSignal(moduleID: model.moduleID(for: call)))
                                .font(A1Typography.font(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            A1AssetIcon("a1-wide-down")
                        }
                        .foregroundStyle(A1Palette.linkBlue)
                        .padding(.horizontal, 20).frame(minWidth: 190, minHeight: 44)
                        .background(A1Palette.soft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看原号卡，\(A1CallPresentation.line(call, model: model))")
                    .accessibilityValue((originalLineAvailable ? model.moduleSignal(moduleID: model.moduleID(for: call)) : .unavailable).accessibilityDescription)
                    .padding(.top, 16)
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 14))) {
                        Button { Task { await model.redial(call) } } label: {
                            HStack(spacing: 8) {
                                A1AssetIcon("a1-wide-phone")
                                Text("呼叫").font(A1Typography.font(15, weight: .medium))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 50)
                            .background(A1Palette.green, in: Capsule())
                        }
                        .accessibilityLabel("使用原线路回拨")
                        Button {
                            if let number = callableNumber { onMessage(number, model.moduleID(for: call)) }
                        } label: {
                            HStack(spacing: 8) {
                                A1AssetIcon("a1-wide-message", tint: A1Palette.accent)
                                Text("短信").font(A1Typography.font(15, weight: .medium))
                            }
                            .foregroundStyle(A1Palette.accent).padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 50)
                            .background(A1Palette.accentSoft, in: Capsule())
                        }
                        .accessibilityIdentifier("a1-wide-call-message")
                    }
                    .buttonStyle(.plain)
                    .disabled(callableNumber == nil || !originalLineAvailable)
                    .frame(maxWidth: 394).padding(.top, 16)
                    VStack(spacing: 0) {
                        Button { showingInformation = true } label: {
                            detailRow(call.startedAt.formatted(date: .abbreviated, time: .shortened),
                                      value: "\(A1CallPresentation.direction(call)) · \(duration)")
                        }
                        Divider().overlay(A1Palette.separator)
                        Button { showingInformation = true } label: {
                            detailRow(call.direction == "incoming" ? "呼入号卡" : "呼出号卡",
                                      value: A1CallPresentation.line(call, model: model))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .background(A1Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                    .padding(.top, 24)
                }
                .padding(.horizontal, 20).padding(.bottom, 32)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(A1Palette.ink).background(A1Palette.background)
        .navigationTitle("通话详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showingInformation) {
            NavigationStack {
                Form {
                    LabeledContent("号卡", value: A1CallPresentation.line(call, model: model))
                    LabeledContent("开始时间", value: call.startedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("类型", value: A1CallPresentation.direction(call))
                    LabeledContent("状态", value: A1CallPresentation.state(call.state))
                    LabeledContent("时长", value: duration)
                }
                .scrollContentBackground(.hidden)
                .background(A1Palette.background)
                .navigationTitle("通话信息").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingInformation = false } } }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
            Text(title).font(A1Typography.font(15)).foregroundStyle(A1Palette.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).font(A1Typography.font(13)).foregroundStyle(A1Palette.secondary).fixedSize(horizontal: false, vertical: true)
            A1AssetIcon("a1-wide-chevron")
        }
        .padding(.vertical, 12).frame(minHeight: 56).contentShape(Rectangle())
    }
}

struct A1EmptyContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let actionIcon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    A1AssetIcon(icon).frame(width: 88, height: 88)
                        .background(A1Palette.soft, in: Circle())
                    Text(title).font(A1Typography.font(23, weight: .medium))
                        .foregroundStyle(A1Palette.ink).frame(minHeight: 33).padding(.top, 24)
                    Text(subtitle).font(A1Typography.font(14))
                        .foregroundStyle(A1Palette.secondary).frame(minHeight: 20).padding(.top, 12)
                    Button(action: action) {
                        HStack(spacing: 8) {
                            A1AssetIcon(actionIcon)
                            Text(actionTitle).font(A1Typography.font(15, weight: .medium))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 264, minHeight: 50)
                        .background(tint, in: Capsule())
                    }
                    .buttonStyle(A1PressButtonStyle())
                    .padding(.top, 24)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 24 : max(24, (geometry.size.height - 324) / 2))
                .padding(.bottom, 24)
            }
        }
    }
}
