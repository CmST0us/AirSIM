import SwiftUI

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case message(String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        guard let scheme = url.scheme?.lowercased(), scheme == "tel" || scheme == "im" else {
            return nil
        }
        let prefixLength = scheme.count + 1
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        target = target.removingPercentEncoding ?? target
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return scheme == "tel" ? .call(target) : .message(target)
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case calls = "通话"
    case contacts = "联系人"
    case messages = "短信"
    case dial = "拨号键盘"
    case cards = "号卡"
    var id: String { rawValue }
}

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("airsim.selected-tab") private var selectedTabRawValue = PhoneTab.calls.rawValue
    @State private var pendingSMSRecipient: String?
    @State private var pendingSMSConversation: String?

    var body: some View {
        GeometryReader { geometry in
            content.environment(\.a1UsesWideLayout, horizontalSizeClass == .regular
                && geometry.size.width >= 840 && verticalSizeClass != .compact
                && !dynamicTypeSize.isAccessibilitySize)
        }
    }

    private var content: some View {
        ZStack {
            TabView(selection: selectedTabBinding) {
                A1CallsView(onCall: dial, onMessage: composeMessage,
                            onContacts: { selectedTab = .contacts },
                            onDial: { selectedTab = .dial })
                    .background { A1Palette.background.ignoresSafeArea() }
                    .tag(PhoneTab.calls)
                    .tabItem { Label("通话", systemImage: "phone") }
                A1ContactsView(onCall: dial, onMessage: composeMessage)
                    .background { A1Palette.background.ignoresSafeArea() }
                    .tag(PhoneTab.contacts)
                    .tabItem { Label("联系人", systemImage: "person.crop.circle") }
                A1MessagesView(pendingRecipient: $pendingSMSRecipient,
                               pendingConversation: $pendingSMSConversation,
                               onSettings: { selectedTab = .cards })
                    .background { A1Palette.background.ignoresSafeArea() }
                    .tag(PhoneTab.messages)
                    .tabItem { Label("短信", systemImage: "bubble.left.and.bubble.right") }
                A1DialPadView(onSettings: { selectedTab = .cards })
                    .tag(PhoneTab.dial)
                    .tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3") }
                AirSIMSettingsView()
                    .tag(PhoneTab.cards)
                    .tabItem { Label("号卡", systemImage: "simcard") }
            }
            .phoneTabSelectionFeedback(selectedTab.rawValue)
            .tint(A1Palette.linkBlue)
            .background { A1Palette.background.ignoresSafeArea() }
            if let call = model.inAppPresentedCall {
                ActiveCallView(call: call)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background { A1Palette.background.ignoresSafeArea() }
        .preferredColorScheme(model.inAppPresentedCall == nil ? settings.appearance.colorScheme : .dark)
        .onChange(of: model.messageScope) { _ in
            pendingSMSRecipient = nil; pendingSMSConversation = nil; model.numberInput = ""
        }
        .onOpenURL(perform: handleSystemCommunicationURL)
        .onAppear {
            if !UITestScenario.active, let sender = IncomingSMSPresentationRequest.consume() { openSMSConversation(sender) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimRemoteSMSReceived)) { _ in model.reloadMessagesFromLocalStore() }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenSMSConversation)) { notification in
            let sender = IncomingSMSPresentationRequest.consume() ?? notification.userInfo?["sender"] as? String
            if let sender { openSMSConversation(sender) } else { selectedTab = .messages }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
            selectedTab = .calls
            model.presentCurrentCallInApp()
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage, !message.isEmpty {
                TransientNoticeBanner(message: message) { model.errorMessage = nil }
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.2), value: model.inAppPresentedCall?.id)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.2), value: model.errorMessage)
    }

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 })
    }
    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .calls }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }
    private func dial(_ number: String, _ moduleID: String?) {
        Task { await model.call(number: number, moduleID: moduleID) }
    }
    private func composeMessage(_ number: String, _ moduleID: String?) {
        Task {
            guard await model.selectLine(moduleID: moduleID) else { return }
            pendingSMSRecipient = number
            selectedTab = .messages
        }
    }
    private func openSMSConversation(_ sender: String) {
        model.reloadMessagesFromLocalStore()
        pendingSMSConversation = sender
        selectedTab = .messages
    }
    private func handleSystemCommunicationURL(_ url: URL) {
        switch SystemCommunicationURL.destination(for: url) {
        case let .call(number): dial(number, nil)
        case let .message(recipient): composeMessage(recipient, nil)
        case nil: break
        }
    }
}

struct TransientNoticeBanner: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(A1Palette.negative)
                .padding(.top, 12)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
            Spacer(minLength: 2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 15).fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// 浅色模式使用系统电话式纯白底；深色模式才绘制深蓝黑底部环境光。
struct PhoneBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.008, green: 0.016, blue: 0.035)
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.018, green: 0.075, blue: 0.16).opacity(0.72),
                        Color(red: 0.025, green: 0.20, blue: 0.48).opacity(0.62),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.white
            }
        }
        .ignoresSafeArea()
    }
}

/// 关键内容表面使用系统原生 Liquid Glass，旧系统回退为系统材质。
struct PhoneCard: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }
}

struct PhoneGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive
                ? Glass.regular.tint(tint).interactive()
                : Glass.regular.tint(tint)
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

/// 自定义工具栏材质仅用于隐藏了系统共享背景的 ToolbarItem，确保始终只有一层玻璃。
private struct PhoneToolbarGlassMorph: ViewModifier {
    let id: String
    @Namespace private var glassNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 40, minHeight: 40)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID(id, in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.82)))
        } else {
            content
        }
    }
}

/// iOS 26 隐藏导航栏自动生成的共享按钮背景，再使用上面的单层可变形玻璃；
/// 旧系统继续交给 ToolbarItem 使用平台默认样式。
@ToolbarContentBuilder
func phoneMorphingToolbarItem<Content: View>(
    placement: ToolbarItemPlacement,
    id: String,
    @ViewBuilder content: () -> Content
) -> some ToolbarContent {
    if #available(iOS 26.0, *) {
        ToolbarItem(placement: placement) {
            content().phoneToolbarGlassMorph(id: id)
        }
        .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

extension View {
    func phoneCard() -> some View { modifier(PhoneCard()) }

    func phoneGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PhoneGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            interactive: interactive
        ))
    }

    @ViewBuilder
    func phoneTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    func phoneToolbarGlassMorph(id: String) -> some View {
        modifier(PhoneToolbarGlassMorph(id: id))
    }

    @ViewBuilder
    func phoneTabSelectionFeedback(_ trigger: String) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}

private struct PhoneTabBarCompactStateActionKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    fileprivate var phoneTabBarCompactStateAction: (Bool) -> Void {
        get { self[PhoneTabBarCompactStateActionKey.self] }
        set { self[PhoneTabBarCompactStateActionKey.self] = newValue }
    }
}

private struct PhoneTabBarCompactScrollReporter: ViewModifier {
    @Environment(\.phoneTabBarCompactStateAction) private var reportCompactState

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { oldOffset, newOffset in
                let delta = newOffset - oldOffset
                if newOffset < 2 {
                    reportCompactState(false)
                } else if delta > 2 {
                    reportCompactState(true)
                } else if delta < -2 {
                    reportCompactState(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func phoneReportsTabBarCompactState() -> some View {
        modifier(PhoneTabBarCompactScrollReporter())
    }
}
