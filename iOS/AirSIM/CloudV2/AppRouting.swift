import SwiftUI
import CallKit

// Reading a selection does not instantiate a runtime, register push or request permissions.
enum AirSIMRuntimeChoice: String, CaseIterable { case local, v1, v2 }
enum CloudVersionPreference {
    static let key = "airsim.cloud-version"
    static let selectedKey = "airsim.cloud-version-selected"
    static func selection(defaults: UserDefaults = .standard, paired: Bool = false) -> AirSIMRuntimeChoice? {
        if defaults.bool(forKey: selectedKey) {
            if defaults.bool(forKey: LocalModePreference.key) { return .local }
            return defaults.string(forKey: key) == "v2" ? .v2 : .v1
        }
        let legacyKeys = ["airsim.first-connection-complete", LocalModePreference.key, CloudModePreference.key, "airsim.push-relay-url", "airsim.voip-push-token", "airsim.alert-push-token", "airsim.push-device-id", "airsim.live-activity-push-to-start-token", "airsim.watch-voip-push-token", "airsim.watch-bundle-id", "airsim.appearance", "airsim.language"]
        guard paired || legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        return defaults.bool(forKey: LocalModePreference.key) ? .local : .v1
    }
    static func save(_ choice: AirSIMRuntimeChoice, defaults: UserDefaults = .standard) {
        defaults.set(choice == .v2 ? "v2" : "v1", forKey: key)
        defaults.set(choice == .local, forKey: LocalModePreference.key)
        defaults.set(true, forKey: selectedKey)
    }
}

// Shared by callback entry points and network completion boundaries; no framework startup.
enum LegacyRuntimeGate {
    private static let lock = NSLock()
    private static var enabled = false
    private static var epoch: UInt64 = 0
    private static var requests = 0
    static var allowed: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    static var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    static func configure(_ value: Bool) { lock.lock(); enabled = value; epoch &+= 1; lock.unlock() }
    static func accepts(_ generation: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return enabled && epoch == generation }
    static func begin() throws -> UInt64 { lock.lock(); defer { lock.unlock() }; guard enabled else { throw CancellationError() }; requests += 1; return epoch }
    static func end() { lock.lock(); requests -= 1; lock.unlock() }
    static func waitForRequests() async { while true { if idle { return }; try? await Task.sleep(for: .milliseconds(20)) } }
    private static var idle: Bool { lock.lock(); defer { lock.unlock() }; return requests == 0 }
    static func data(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        let stamp = try begin(); defer { end() }
        guard accepts(stamp) else { throw CancellationError() }
        let result = try await session.data(for: request)
        guard accepts(stamp) else { throw CancellationError() }
        return result
    }
}

// A late system VoIP push must still be reported, but must never enter either runtime.
@MainActor
final class ExpiredLegacyPushReporter: NSObject, CXProviderDelegate {
    static let shared = ExpiredLegacyPushReporter()
    private let provider: CXProvider
    override init() {
        let config = CXProviderConfiguration(); config.supportsVideo = false
        provider = CXProvider(configuration: config)
        super.init(); provider.setDelegate(self, queue: .main)
    }
    func report(completion: @escaping () -> Void) {
        let id = UUID(); let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "AirSIM 旧版通知")
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] _ in
            Task { @MainActor in
                self?.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
                completion()
            }
        }
    }
    nonisolated func providerDidReset(_ provider: CXProvider) {}
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { action.fail() }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) { action.fail() }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { action.fulfill() }
}

enum LegacyPushRouting {
    @discardableResult static func rejectExpired(allowed: Bool, expired: () -> Void) -> Bool {
        guard allowed else { expired(); return true }
        return false
    }
}

@MainActor
final class AppRouteCoordinator: ObservableObject {
    @Published private(set) var choice: AirSIMRuntimeChoice?
    @Published private(set) var transitioning = false
    @Published var error: String?
    @Published private(set) var legacyRuntimeStopped = false
    private let defaults: UserDefaults
    var legacy: AppModel?
    var cloud: CloudV2Model?
    init(defaults: UserDefaults = .standard, paired: Bool? = nil) {
        self.defaults = defaults
        choice = CloudVersionPreference.selection(defaults: defaults, paired: paired ?? (VoWLANCredentialStore.load() != nil))
        if let choice { CloudVersionPreference.save(choice, defaults: defaults) }
        LegacyRuntimeGate.configure(choice == .v1 || choice == .local)
    }
    func choose(_ next: AirSIMRuntimeChoice) async {
        guard !transitioning, next != choice else { return }
        guard !LegacyBusinessReservations.pending, !LegacySwitchFence.shared.blocked, legacy?.blocksRuntimeSwitch != true, cloud?.blocksSwitch != true else {
            error = "仍有通话、媒体或未确认操作，请先结束通话并确认操作结果。"; return
        }
        transitioning = true
#if DEBUG
        let stopStarted = Date()
#endif
        LegacyRuntimeGate.configure(false)
        if choice == .v1 || choice == .local {
            if let legacy { await legacy.stopRuntime() }
            await VoIPPushController.shared.stopRuntime()
            AirSIMNotificationDelegate.current?.stopRuntime()
            WatchCallCoordinator.shared.stopRuntime()
            CallKitController.shared.handler = nil
            CallKitController.shared.setEnabled(false)
            await LegacyRuntimeGate.waitForRequests()
        }
        if let cloud { await cloud.stop() }
        legacy = nil; cloud = nil
        defaults.removeObject(forKey: IncomingCallPresentationRequest.key)
        defaults.removeObject(forKey: IncomingSMSPresentationRequest.key)
        legacyRuntimeStopped = true
        CloudVersionPreference.save(next, defaults: defaults)
        choice = next
        LegacyRuntimeGate.configure(next == .v1 || next == .local)
        transitioning = false
#if DEBUG
        let events = LegacyActivityEvents.shared
        NSLog("[AirSIM RuntimeStop] completed ms=%.0f readonly_global=%d activity=%d retired=%d subscriptions=%d", Date().timeIntervalSince(stopStarted) * 1000, events.globalCount, events.activityCount, events.retiredCount, events.subscriptionCount)
#endif
    }
}

struct AirSIMRouteView: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    var body: some View {
        Group {
            if router.transitioning { ProgressView("正在停止当前连接…") }
            else if let choice = router.choice {
                if choice == .v2 { CloudV2Host() } else { LegacyAppHost() }
            } else {
                NavigationStack {
                    List {
                        Section("选择连接方式") { RuntimeChoiceButtons() }
                        Text("选择前不会发现设备、注册推送或请求权限。")
                            .foregroundStyle(.secondary)
                    }.navigationTitle("欢迎使用 AirSIM")
                }
            }
        }
        .alert("无法切换", isPresented: Binding(get: { router.error != nil }, set: { if !$0 { router.error = nil } })) {
            Button("好") { router.error = nil }
        } message: { Text(router.error ?? "") }
    }
}
struct RuntimeChoiceButtons: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    var body: some View {
        ForEach(AirSIMRuntimeChoice.allCases, id: \.self) { choice in
            Button { Task { await router.choose(choice) } } label: {
                HStack {
                    Text(choice == .local ? "仅本地 VoWLAN" : choice == .v1 ? "云端 v1（现有版本）" : "云端 v2（前台实验）")
                    Spacer(); if router.choice == choice { Image(systemName: "checkmark") }
                }
            }.disabled(router.transitioning)
        }
    }
}
struct LegacyAppHost: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = AppModel()
    @StateObject private var settings = AppSettings()
    var body: some View {
        RootView().environmentObject(model).environmentObject(model.contacts).environmentObject(model.audio).environmentObject(settings)
            .onAppear { router.legacy = model; model.start(sceneIsActive: phase == .active) }
            .onChange(of: phase) { value in
                guard LegacyRuntimeGate.allowed else { return }
                switch value { case .active: model.didBecomeActive(); case .inactive: model.willResignActive(); case .background: model.didEnterBackground(); default: break }
            }
    }
}
