import SwiftUI
import CallKit

// Shared by callback entry points and network completion boundaries; no framework startup.
enum LegacyRuntimeGate {
    private static let lock = NSLock()
    private static var enabled = false
    private static var epoch: UInt64 = 0
    private static var requests = 0
    static var allowed: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    static var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    static func configure(_ value: Bool) { lock.lock(); enabled = value && !UITestScenario.active; epoch &+= 1; lock.unlock() }
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
    func report(reason: String = "legacy_runtime", completion: @escaping () -> Void) {
#if DEBUG
        UserDefaults.standard.set(reason, forKey: "airsim.push.last-rejection")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "airsim.push.last-rejection-time")
        NSLog("[AirSIM Push] rejected reason=%@", reason)
#endif
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
    private(set) var cloud: CloudV2Model?
    private let makeCloud: @MainActor () -> CloudV2Model

    init(makeCloud: @escaping @MainActor () -> CloudV2Model = { UITestScenario.makeCloud() }) {
        self.makeCloud = makeCloud
        LegacyRuntimeGate.configure(false)
    }

    func ensureRuntime() {
        guard model == nil else { return }
        let cloud = makeCloud()
        self.cloud = cloud
        model = AppModel(cloudV2: cloud)
        cloud.activateSystemIntegration()
    }
}

struct AirSIMRouteView: View {
    @EnvironmentObject private var router: AppRouteCoordinator
    var body: some View {
        Group {
            if let model = router.model { SharedAppHost(model: model) }
            else { ProgressView().onAppear { router.ensureRuntime() } }
        }
    }
}

struct SharedAppHost: View {
    @Environment(\.scenePhase) private var phase
    @ObservedObject var model: AppModel
    @StateObject private var settings = AppSettings()
    @AppStorage("airsim.first-connection-complete", store: UITestScenario.defaults) private var firstConnectionComplete = false
    var body: some View {
        Group {
            if firstConnectionComplete { RootView() }
            else { AirSIMFirstConnectionView() }
        }
        .environmentObject(model).environmentObject(model.contacts).environmentObject(model.audio).environmentObject(settings)
            .onAppear { model.start(sceneIsActive: phase == .active) }
            .onChange(of: phase) { value in
                guard model.isV2 || LegacyRuntimeGate.allowed else { return }
                switch value { case .active: model.didBecomeActive(); case .inactive: model.willResignActive(); case .background: model.didEnterBackground(); default: break }
            }
    }
}

// Launch scenarios are confined to simulator Debug builds and use disposable stores.
enum UITestScenario {
    static let name: String? = {
#if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--ui-scenario"), args.indices.contains(index + 1),
              ["fresh", "local-unpaired", "v1-unpaired", "v2-unconfigured", "v2-pairing-live", "v2-offline-fixture", "v2-ready-fixture", "v2-send-failure", "v2-command-unknown", "v2-incoming-fixture", "v2-active-fixture", "v2-dialing-fixture", "design-empty", "design-a1", "design-messages", "design-messages-failure"].contains(args[index + 1]) else { return nil }
        return args[index + 1]
#else
        return nil
#endif
    }()
    static var active: Bool { name != nil }
    static var usesDesignData: Bool { ["design-a1", "design-messages", "design-messages-failure"].contains(name ?? "") }
    static let defaults: UserDefaults = {
        guard let name else { return .standard }
        let suite = "airsim.ui." + UUID().uuidString
        let value = UserDefaults(suiteName: suite)!
        if name == "local-unpaired" || name == "v1-unpaired" {
            value.set("v1", forKey: "airsim.cloud-version")
            value.set(true, forKey: "airsim.cloud-version-selected")
            value.set(name == "local-unpaired", forKey: LocalModePreference.key)
        }
        #if DEBUG && targetEnvironment(simulator)
        if usesDesignData {
            value.set(["design-contact-0", "design-contact-2", "design-contact-5"], forKey: "airsim.contacts.favorites")
            value.set(["design-contact-0": FixtureTransport.first, "design-contact-2": FixtureTransport.second,
                       "design-contact-5": FixtureTransport.first], forKey: "airsim.contacts.preferred-modules")
        }
        #endif
        value.set(name != "fresh", forKey: "airsim.first-connection-complete")
        return value
    }()
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("airsim-ui-" + UUID().uuidString)
    @MainActor static func makeCloud() -> CloudV2Model {
#if DEBUG && targetEnvironment(simulator)
        if name == "v2-pairing-live" {
            let tokens = LivePairingTokens()
            let pairings = LivePairingStore()
            return CloudV2Model(defaults: defaults, root: root, tokens: tokens, pairings: pairings)
        }
        if active { return FixtureTransport.makeModel() }
#endif
        return CloudV2Model()
    }
}

#if DEBUG && targetEnvironment(simulator)
private final class LivePairingTokens: V2TokenStore {
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

private final class LivePairingStore: V2PairingStore {
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

private struct FixtureTokens: V2TokenStore {
    func save(_ token: String, account: String) throws {}
    func read(account: String) throws -> String { String(repeating: "a", count: 64) }
    func remove(account: String) throws {}
}
private struct FixtureTransport: V2HTTPTransport {
    static let first = "00112233-4455-4677-8899-aabbccddeeff"
    static let second = "10112233-4455-4677-8899-aabbccddeeff"
    static let config = V2Configuration(identity: V2Identity(apiOrigin: "https://example.invalid", serverID: first, clientInstallationID: first), mediaOrigin: "https://media.example.invalid", expiresAt: Date().addingTimeInterval(3600))
    static let designCalls: [(moduleID: String, wire: [String: String])] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let entries: [(Int, String, String, Int, Int, Int, String)] = [
            (2, second, "incoming", 0, 14, 27, "missed"),
            (5, first, "incoming", 0, 11, 20, "normal"),
            (0, first, "outgoing", 0, 10, 4, "normal"),
            (3, second, "incoming", -1, 17, 36, "normal")
        ]
        return entries.enumerated().map { offset, entry in
            let day = calendar.date(byAdding: .day, value: entry.3, to: today)!
            let date = calendar.date(bySettingHour: entry.4, minute: entry.5, second: 0, of: day)!
            return (entry.1, ["call_id": String(format: "20112233-4455-4677-8899-aabbccddee%02d", offset),
                "state": "disconnected", "ownership": "managed", "direction": entry.2,
                "number": String(format: "%011d", entry.0 + 1), "observed_at": V2Validation.timestamp(date),
                "disconnect_reason": entry.6])
        }
    }()
    static let designMessages: [(moduleID: String, wire: [String: String])] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var entries: [(String, String, String, String, String, Int, Int, Int)] = [
            (second, "00000000003", "incoming", "下班一起吃饭？我订了你喜欢的那家。", "received", 0, 14, 30),
            (first, "00000000001", "incoming", "方案已发你邮箱，方便时看一下。", "received", 0, 13, 42),
            (first, "00000000001", "outgoing", "收到，我今天下午看完后回复你。", "sent", 0, 13, 42),
            (first, "00000000001", "incoming", "好，辛苦了。", "received", 0, 13, 42),
            (second, "00000000007", "incoming", "您的虚构快件已送达，请及时查收。", "received", 0, 12, 18),
            (first, "00000000006", "incoming", "收到，明天上午十点见。", "received", -1, 18, 20),
            (second, "00000000004", "outgoing", "周末的照片发你啦。", "outcome_unknown", -1, 17, 34),
            (second, "00000000004", "incoming", "周末的照片发你啦。", "received", -1, 17, 35),
            (second, "00000000001", "incoming", "上次推荐的书已经读完了，很喜欢。", "received", -2, 12, 20),
            (second, "00000000001", "outgoing", "我把修改建议整理好了，发你确认。", "failed", -2, 12, 22)
        ]
        if UITestScenario.name == "design-messages-failure" {
            entries.append((first, "00000000001", "outgoing", "我把修改建议整理好了，发你确认。", "failed", 0, 13, 43))
        }
        return entries.enumerated().map { offset, entry in
            let day = calendar.date(byAdding: .day, value: entry.5, to: today)!
            let date = calendar.date(bySettingHour: entry.6, minute: entry.7, second: 0, of: day)!
            return (entry.0, ["message_id": String(format: "30112233-4455-4677-8899-aabbccddee%02d", offset),
                "direction": entry.2, "sender": entry.2 == "incoming" ? entry.1 : "",
                "recipient": entry.2 == "outgoing" ? entry.1 : "", "text": entry.3, "state": entry.4,
                "delivery": "unknown", "observed_at": V2Validation.timestamp(date)])
        }
    }()
    @MainActor static func makeModel() -> CloudV2Model {
        let defaults = UITestScenario.defaults
        if !["v2-unconfigured", "fresh", "local-unpaired", "v1-unpaired"].contains(UITestScenario.name ?? "") {
            defaults.set(try? JSONEncoder().encode(config), forKey: "airsim.v2.configuration")
            if defaults.string(forKey: V2LocalPaths.selectionKey(config.identity)) == nil {
                defaults.set(first, forKey: V2LocalPaths.selectionKey(config.identity))
            }
            if UITestScenario.name == "v2-command-unknown" {
                let pending = V2PendingCommand(binding: V2ControlBinding(identity: config.identity, moduleID: first, bootID: first, backendEpoch: first, connectionEpoch: first), commandID: second, action: "sms.send", generation: first, callID: nil)
                try? V2FilePendingStore(url: UITestScenario.root.appendingPathComponent("pending.json")).save(pending)
            }
        }
        if ["v2-incoming-fixture", "v2-active-fixture", "v2-dialing-fixture"].contains(UITestScenario.name ?? "") {
            defaults.set("工作 · 4821", forKey: "airsim.v2.module-name.\(first).\(first)")
        }
        if UITestScenario.name == "design-empty" {
            defaults.set("工作 · 4821", forKey: "airsim.v2.module-name.\(first).\(first)")
            defaults.set("生活 · 9066", forKey: "airsim.v2.module-name.\(first).\(second)")
        }
        if UITestScenario.usesDesignData {
            defaults.set("工作 · 4821", forKey: "airsim.v2.module-name.\(first).\(first)")
            defaults.set("生活 · 9066", forKey: "airsim.v2.module-name.\(first).\(second)")
            let calls = designCalls.compactMap { entry -> V2StoredCall? in
                guard let data = try? JSONSerialization.data(withJSONObject: entry.wire),
                      let call = try? JSONDecoder().decode(V2Call.self, from: data) else { return nil }
                return V2StoredCall(domain: V2HistoryDomain(identity: config.identity, moduleID: entry.moduleID,
                                                          bootID: first, backendEpoch: first), call: call)
            }
            let messages = designMessages.compactMap { entry -> V2StoredMessage? in
                guard let data = try? JSONSerialization.data(withJSONObject: entry.wire),
                      let message = try? JSONDecoder().decode(V2Message.self, from: data) else { return nil }
                return V2StoredMessage(domain: V2HistoryDomain(identity: config.identity, moduleID: entry.moduleID,
                    bootID: first, backendEpoch: first), message: message, inboxGap: false, inboxDropped: 0)
            }
            try? V2ProtectedFile<V2History>(url: UITestScenario.root.appendingPathComponent("history.json"))
                .save(V2History(messages: messages, calls: calls))
        }
        let tokens = FixtureTokens()
        let pairingClient = UITestScenario.usesDesignData
            ? V2PairingClient(origin: config.identity.apiOrigin, store: LivePairingStore(), transport: Self())
            : nil
        return CloudV2Model(client: V2Client(transport: Self(), tokens: tokens), defaults: defaults, root: UITestScenario.root, tokens: tokens, pairingClient: pairingClient)
    }
    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse {
        let id = Self.first, second = Self.second
        let path = request.url?.path ?? ""
        if path == "/v2/pairing/lookup" {
            return V2HTTPResponse(status: 410, body: Data())
        }
        let module = path.contains(second) ? second : id
        let online = UITestScenario.name != "v2-offline-fixture"
        let date = V2Validation.timestamp(Date())
        let label = module == id ? "甲" : "乙"
        let incomingCall = UITestScenario.name == "v2-incoming-fixture"
        let activeCall = UITestScenario.name == "v2-active-fixture"
        let dialingCall = UITestScenario.name == "v2-dialing-fixture"
        let callScenario = incomingCall || activeCall || dialingCall
        let moduleIDs = callScenario ? [id] : [id, second]
        let object: [String: Any]
        if path == "/.well-known/airsim" {
            object = ["protocol_version": 2, "profile": "airsim-v2-r4.1", "server_id": id, "api_origin": "https://example.invalid", "media_origin": "https://media.example.invalid", "device_origin": "https://device.example.invalid", "capabilities": ["controlled_test_client": true, "telephony": true, "messaging": true, "experimental_audio": true, "apns": false, "interactive_login": false]]
        } else if path == "/v2/modules" {
            object = ["server_id": id, "modules": moduleIDs.map { ["module_id": $0, "online": online, "last_seen": date, "agent_boot_id": id, "backend_epoch": id, "connection_epoch": id] as [String: Any] }]
        } else if path.hasSuffix("snapshot") {
            let call: [String: Any] = [
                "call_id": id,
                "state": incomingCall ? "incoming" : activeCall ? "active" : dialingCall ? "dialing" : "disconnected",
                "ownership": incomingCall ? "incoming" : "managed",
                "direction": incomingCall ? "incoming" : "outgoing",
                "number": callScenario ? "00000000001" : "QA\(label)通话",
                "observed_at": callScenario ? date : "2026-10-24T00:00:00Z",
                "disconnect_reason": ""
            ]
            object = ["server_id": id, "module_id": module, "online": online, "last_seen": date, "connection_epoch": id, "snapshot": [
                "agent_boot_id": id, "backend_epoch": id, "observed_at": date,
                "control": ["schema_version": 1, "agent_boot_id": id, "backend_epoch": id, "ready": true, "reason": "", "scope": "local_control", "voice_ready": false, "telephony_ready": true, "messaging_ready": true, "inbox_gap": false, "inbox_dropped": 0, "command_capacity_remaining": 100],
                "calls": ["agent_boot_id": id, "backend_epoch": id, "available": true, "calls": UITestScenario.name == "design-empty" ? [] : UITestScenario.usesDesignData ? Self.designCalls.filter { $0.moduleID == module }.map { $0.wire as [String: Any] } : [call]],
                "audio": ["available": false, "implementation": "unavailable", "verification": "unverified", "voice_ready": false, "reason": ""]]]
        } else if path.hasSuffix("messages") {
            let messages: [[String: Any]] = UITestScenario.name == "design-empty" ? [] : UITestScenario.usesDesignData
                ? Self.designMessages.filter { $0.moduleID == module }.map { $0.wire as [String: Any] }
                : [["message_id": id, "direction": "incoming", "sender": module == id ? "00000000001" : "00000000002", "recipient": "", "text": "QA\(label)消息", "state": "received", "delivery": "unknown", "observed_at": "2026-10-24T00:00:00Z"]]
            object = ["server_id": id, "module_id": module, "agent_boot_id": id, "backend_epoch": id, "online": online,
                      "inbox_gap": false, "inbox_dropped": 0, "messages": messages]
        } else if path.contains("commands") {
            if UITestScenario.name == "v2-command-unknown" { throw V2Error.transport }
            return V2HTTPResponse(status: 409, body: Data())
        } else { throw V2Error.transport }
        return V2HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
#endif
