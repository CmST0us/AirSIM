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
    static func configure(_ value: Bool) { lock.lock(); enabled = value && !R7UITestScenario.active; epoch &+= 1; lock.unlock() }
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
    static let shared = AppRouteCoordinator()
    @Published private(set) var model: AppModel?
    func ensureRuntime() {
        guard model == nil, let choice else { return }
        let value = AppModel(cloudV2: choice == .v2 ? R7UITestScenario.makeCloud() : nil)
        model = value; legacy = value.isV2 ? nil : value; cloud = value.cloudV2
        cloud?.activateSystemIntegration()
    }
    @Published private(set) var choice: AirSIMRuntimeChoice?
    @Published private(set) var transitioning = false
    @Published var error: String?
    @Published private(set) var legacyRuntimeStopped = false
    private let defaults: UserDefaults
    var legacy: AppModel?
    var cloud: CloudV2Model?
    init(defaults: UserDefaults = R7UITestScenario.defaults, paired: Bool? = nil) {
        self.defaults = defaults
        choice = R7UITestScenario.name == "fresh" ? nil : CloudVersionPreference.selection(defaults: defaults, paired: paired ?? (!R7UITestScenario.active && VoWLANCredentialStore.load() != nil))
        if let choice { CloudVersionPreference.save(choice, defaults: defaults) }
        LegacyRuntimeGate.configure(choice == .v1 || choice == .local)
    }
    func choose(_ next: AirSIMRuntimeChoice) async {
        guard !transitioning, next != choice else { return }
        guard R7UITestScenario.active || (!LegacyBusinessReservations.pending && !LegacySwitchFence.shared.blocked), legacy?.blocksRuntimeSwitch != true, cloud?.blocksSwitch != true else {
            error = "仍有通话、媒体或未确认操作，请先结束通话并确认操作结果。"; return
        }
        transitioning = true
#if DEBUG
        let stopStarted = Date()
#endif
        LegacyRuntimeGate.configure(false)
        if !R7UITestScenario.active && (choice == .v1 || choice == .local) {
            if let legacy { await legacy.stopRuntime() }
            await VoIPPushController.shared.stopRuntime()
            AirSIMNotificationDelegate.current?.stopRuntime()
            WatchCallCoordinator.shared.stopRuntime()
            CallKitController.shared.handler = nil
            CallKitController.shared.setEnabled(false)
            await LegacyRuntimeGate.waitForRequests()
        }
        if let cloud { await cloud.stop(); cloud.systemCalls?.stop() }
        legacy = nil; cloud = nil; model = nil
        defaults.removeObject(forKey: IncomingCallPresentationRequest.key)
        defaults.removeObject(forKey: IncomingSMSPresentationRequest.key)
        legacyRuntimeStopped = true
        CloudVersionPreference.save(next, defaults: defaults)
        choice = next
        LegacyRuntimeGate.configure(next == .v1 || next == .local)
        ensureRuntime()
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
                if let model = router.model { SharedAppHost(model: model).id(choice) }
                else { ProgressView().onAppear { router.ensureRuntime() } }
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
                    Text(choice == .local ? "仅本地 VoWLAN" : choice == .v1 ? "云端 v1（现有版本）" : "云端 v2")
                    Spacer(); if router.choice == choice { Image(systemName: "checkmark") }
                }
            }.disabled(router.transitioning)
        }
    }
}
struct SharedAppHost: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    @Environment(\.scenePhase) private var phase
    @ObservedObject var model: AppModel
    @StateObject private var settings = AppSettings()
    var body: some View {
        RootView().environmentObject(model).environmentObject(model.contacts).environmentObject(model.audio).environmentObject(settings)
            .onAppear { model.start(sceneIsActive: phase == .active) }
            .onChange(of: phase) { value in
                guard model.isV2 || LegacyRuntimeGate.allowed else { return }
                switch value { case .active: model.didBecomeActive(); case .inactive: model.willResignActive(); case .background: model.didEnterBackground(); default: break }
            }
    }
}

// Launch scenarios are confined to simulator Debug builds and use disposable stores.
enum R7UITestScenario {
    static let name: String? = {
#if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--r7-ui-scenario"), args.indices.contains(index + 1),
              ["fresh", "local-unpaired", "v1-unpaired", "v2-unconfigured", "v2-pairing-live", "v2-offline-fixture", "v2-ready-fixture", "v2-send-failure", "v2-command-unknown", "v2-incoming-fixture", "v2-active-fixture"].contains(args[index + 1]) else { return nil }
        return args[index + 1]
#else
        return nil
#endif
    }()
    static var active: Bool { name != nil }
    static let defaults: UserDefaults = {
        guard let name else { return .standard }
        let suite = "airsim.r7.ui." + UUID().uuidString
        let value = UserDefaults(suiteName: suite)!
        if name != "fresh" {
            CloudVersionPreference.save(name == "local-unpaired" ? .local : name == "v1-unpaired" ? .v1 : .v2, defaults: value)
            value.set(true, forKey: "airsim.first-connection-complete")
        }
        return value
    }()
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("airsim-r7-ui-" + UUID().uuidString)
    @MainActor static func makeCloud() -> CloudV2Model {
#if DEBUG && targetEnvironment(simulator)
        if name == "v2-pairing-live" {
            let tokens = R8LivePairingTokens()
            let pairings = R8LivePairingStore()
            return CloudV2Model(defaults: defaults, root: root, tokens: tokens, pairings: pairings)
        }
        if active { return R7FixtureTransport.makeModel() }
#endif
        return CloudV2Model()
    }
}

#if DEBUG && targetEnvironment(simulator)
private final class R8LivePairingTokens: V2TokenStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ token: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = token
    }

    func read(account: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let token = values[account] else { throw V2Error.keychain }
        return token
    }

    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = nil
    }
}

private final class R8LivePairingStore: V2PairingStore {
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> V2PairingState {
        lock.lock(); defer { lock.unlock() }
        guard let data else { return V2PairingState() }
        return try JSONDecoder().decode(V2PairingState.self, from: data)
    }

    func save(_ state: V2PairingState) throws {
        let encoded = try JSONEncoder().encode(state)
        lock.lock(); defer { lock.unlock() }
        data = encoded
    }
}

private struct R7FixtureTokens: V2TokenStore {
    func save(_ token: String, account: String) throws {}
    func read(account: String) throws -> String { String(repeating: "a", count: 64) }
    func remove(account: String) throws {}
}
private struct R7FixtureTransport: V2HTTPTransport {
    static let first = "00112233-4455-4677-8899-aabbccddeeff"
    static let second = "10112233-4455-4677-8899-aabbccddeeff"
    static let config = V2Configuration(identity: V2Identity(apiOrigin: "https://example.invalid", serverID: first, clientInstallationID: first), mediaOrigin: "https://media.example.invalid", expiresAt: Date().addingTimeInterval(3600))
    @MainActor static func makeModel() -> CloudV2Model {
        let defaults = R7UITestScenario.defaults
        if R7UITestScenario.name != "v2-unconfigured" && R7UITestScenario.name != "fresh" {
            defaults.set(try? JSONEncoder().encode(config), forKey: "airsim.v2.configuration")
            if defaults.string(forKey: V2LocalPaths.selectionKey(config.identity)) == nil {
                defaults.set(first, forKey: V2LocalPaths.selectionKey(config.identity))
            }
            if R7UITestScenario.name == "v2-command-unknown" {
                let pending = V2PendingCommand(binding: V2ControlBinding(identity: config.identity, moduleID: first, bootID: first, backendEpoch: first, connectionEpoch: first), commandID: second, action: "sms.send", generation: first, callID: nil)
                try? V2FilePendingStore(url: R7UITestScenario.root.appendingPathComponent("pending.json")).save(pending)
            }
        }
        let tokens = R7FixtureTokens()
        return CloudV2Model(client: V2Client(transport: Self(), tokens: tokens), defaults: defaults, root: R7UITestScenario.root, tokens: tokens)
    }
    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse {
        let id = Self.first, second = Self.second
        let path = request.url?.path ?? ""
        let module = path.contains(second) ? second : id
        let online = R7UITestScenario.name != "v2-offline-fixture"
        let date = V2Validation.timestamp(Date())
        let label = module == id ? "甲" : "乙"
        let incomingCall = R7UITestScenario.name == "v2-incoming-fixture"
        let activeCall = R7UITestScenario.name == "v2-active-fixture"
        let callScenario = incomingCall || activeCall
        let moduleIDs = callScenario ? [id] : [id, second]
        let object: [String: Any]
        if path == "/.well-known/airsim" {
            object = ["protocol_version": 2, "profile": "airsim-v2-r4.1", "server_id": id, "api_origin": "https://example.invalid", "media_origin": "https://media.example.invalid", "device_origin": "https://device.example.invalid", "capabilities": ["controlled_test_client": true, "telephony": true, "messaging": true, "experimental_audio": true, "apns": false, "interactive_login": false]]
        } else if path == "/v2/modules" {
            object = ["server_id": id, "modules": moduleIDs.map { ["module_id": $0, "online": online, "last_seen": date, "agent_boot_id": id, "backend_epoch": id, "connection_epoch": id] as [String: Any] }]
        } else if path.hasSuffix("snapshot") {
            let call: [String: Any] = [
                "call_id": id,
                "state": incomingCall ? "incoming" : activeCall ? "active" : "disconnected",
                "ownership": incomingCall ? "incoming" : "managed",
                "direction": incomingCall ? "incoming" : "outgoing",
                "number": callScenario ? "00000000001" : "QA\(label)通话",
                "observed_at": callScenario ? date : "2026-10-24T00:00:00Z",
                "disconnect_reason": ""
            ]
            object = ["server_id": id, "module_id": module, "online": online, "last_seen": date, "connection_epoch": id, "snapshot": [
                "agent_boot_id": id, "backend_epoch": id, "observed_at": date,
                "control": ["schema_version": 1, "agent_boot_id": id, "backend_epoch": id, "ready": true, "reason": "", "scope": "local_control", "voice_ready": false, "telephony_ready": true, "messaging_ready": true, "inbox_gap": false, "inbox_dropped": 0, "command_capacity_remaining": 100],
                "calls": ["agent_boot_id": id, "backend_epoch": id, "available": true, "calls": [call]],
                "audio": ["available": false, "implementation": "unavailable", "verification": "unverified", "voice_ready": false, "reason": ""]]]
        } else if path.hasSuffix("messages") {
            object = ["server_id": id, "module_id": module, "agent_boot_id": id, "backend_epoch": id, "online": online, "inbox_gap": false, "inbox_dropped": 0, "messages": [["message_id": id, "direction": "incoming", "sender": module == id ? "00000000001" : "00000000002", "recipient": "", "text": "QA\(label)消息", "state": "received", "delivery": "unknown", "observed_at": "2026-10-24T00:00:00Z"]]]
        } else if path.contains("commands") {
            if R7UITestScenario.name == "v2-command-unknown" { throw V2Error.transport }
            return V2HTTPResponse(status: 409, body: Data())
        } else { throw V2Error.transport }
        return V2HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
#endif
