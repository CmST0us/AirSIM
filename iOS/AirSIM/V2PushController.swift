import Foundation
import PushKit
import UIKit
import UserNotifications

private struct V2StoredPushRegistration: Codable, Equatable {
    let identityAccount: String
    let serverID: String
    let clientInstallationID: String
    let moduleID: String
    let registrationID: String
}

struct V2PushDomain: Equatable, Sendable {
    let serverID: String
    let clientInstallationID: String
    let registrationID: String
    let moduleID: String
    let agentBootID: String
    let backendEpoch: String
    let connectionEpoch: String

    init?(userInfo: [AnyHashable: Any]) {
        guard Self.protocolVersion(userInfo["protocol_version"]) == 2,
              let serverID = Self.uuid(userInfo["server_id"]),
              let clientInstallationID = Self.uuid(userInfo["client_installation_id"]),
              let registrationID = Self.uuid(userInfo["registration_id"]),
              let moduleID = Self.uuid(userInfo["module_id"]),
              let agentBootID = Self.uuid(userInfo["agent_boot_id"]),
              let backendEpoch = Self.uuid(userInfo["backend_epoch"]),
              let connectionEpoch = Self.uuid(userInfo["connection_epoch"]) else { return nil }
        self.serverID = serverID
        self.clientInstallationID = clientInstallationID
        self.registrationID = registrationID
        self.moduleID = moduleID
        self.agentBootID = agentBootID
        self.backendEpoch = backendEpoch
        self.connectionEpoch = connectionEpoch
    }

    private static func protocolVersion(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func uuid(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(),
              UUID(uuidString: text) != nil else { return nil }
        return text
    }
}

struct V2PushEnvelope: Equatable, Sendable {
    let domain: V2PushDomain
    let callID: String
    let callUUID: UUID
    let expiresAt: Date

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["event"] as? String == "incoming_call",
              let domain = V2PushDomain(userInfo: userInfo),
              let callID = V2PushDomain.uuid(userInfo["call_id"]),
              let rawUUID = userInfo["call_uuid"] as? String,
              let callUUID = UUID(uuidString: rawUUID),
              let rawExpiry = userInfo["expires_at"] as? String,
              let expiresAt = try? V2Validation.date(rawExpiry) else { return nil }
        self.domain = domain
        self.callID = callID
        self.callUUID = callUUID
        self.expiresAt = expiresAt
    }
}

/// Owns PushKit and alert-token registration for the v2 runtime.
///
/// Permission prompts are requested only while the app is active. PushKit itself
/// requires no user prompt, while alert notifications request alert and sound.
@MainActor
final class V2PushController: NSObject {
    static let shared = V2PushController()

    private enum Keys {
        static let voIPToken = "airsim.v2.voip-push-token"
        static let alertToken = "airsim.v2.alert-push-token"
        static let registration = "airsim.v2.push-registration"
    }

    private weak var model: CloudV2Model?
    private var registry: PKPushRegistry?
    private var registrationInFlight = false
    private var registrationPending = false
    private var notificationPermissionRequest: Task<UNAuthorizationStatus, Never>?
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    var alertTokenReady: Bool {
        guard let token = defaults.string(forKey: Keys.alertToken) else { return false }
        return !token.isEmpty
    }

    var voIPTokenReady: Bool {
        guard let token = defaults.string(forKey: Keys.voIPToken) else { return false }
        return !token.isEmpty
    }

    func attach(_ model: CloudV2Model) {
        self.model = model
        updateStatus()
    }

    func start(model: CloudV2Model? = nil) {
        if let model { self.model = model }
        guard model != nil, !UITestScenario.active else { return }
        if registry == nil {
            let registry = PKPushRegistry(queue: .main)
            registry.delegate = self
            self.registry = registry
        }
        registry?.desiredPushTypes = [.voIP]
        UIApplication.shared.registerForRemoteNotifications()
        requestRegistrationSync()
    }

    @discardableResult
    func requestNotificationPermission() async -> UNAuthorizationStatus {
        if let notificationPermissionRequest {
            return await notificationPermissionRequest.value
        }
        let task = Task { () -> UNAuthorizationStatus in
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            UIApplication.shared.registerForRemoteNotifications()
            return settings.authorizationStatus
        }
        notificationPermissionRequest = task
        let status = await task.value
        notificationPermissionRequest = nil
        updateStatus(notificationStatus: status)
        requestRegistrationSync()
        return status
    }

    func refreshNotificationStatus() async -> UNAuthorizationStatus {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        updateStatus(notificationStatus: status)
        return status
    }

    func storeAlertToken(_ token: Data) {
        defaults.set(VoIPPushToken.hex(token), forKey: Keys.alertToken)
        requestRegistrationSync()
    }

    func clearAlertToken() {
        defaults.removeObject(forKey: Keys.alertToken)
        updateStatus()
    }

    func registrationFailed(_ message: String) {
        model?.updatePushRegistration(
            status: message,
            ready: false
        )
    }

    func requestRegistrationSync() {
        guard let model else { return }
        if registrationInFlight {
            registrationPending = true
            return
        }
        Task { [weak self] in await self?.syncRegistration(model: model) }
    }

    func syncRegistration(model: CloudV2Model) async {
        self.model = model
        guard !registrationInFlight else {
            registrationPending = true
            return
        }
        guard let configuration = model.configuration else {
            model.updatePushRegistration(status: "添加设备后启用后台推送", ready: false)
            return
        }
        guard model.connected else {
            model.updatePushRegistration(status: "等待云端 v2 连接", ready: false)
            return
        }
        guard model.discovery?.capabilities.apns == true else {
            model.updatePushRegistration(status: "服务端尚未启用 APNs", ready: false)
            return
        }
        guard let moduleID = model.selectedModuleID else {
            model.updatePushRegistration(status: "先选择一个模块", ready: false)
            return
        }
        guard let voIPToken = defaults.string(forKey: Keys.voIPToken), !voIPToken.isEmpty else {
            model.updatePushRegistration(status: "等待 PushKit token", ready: false)
            return
        }

        registrationInFlight = true
        defer {
            registrationInFlight = false
            if registrationPending {
                registrationPending = false
                requestRegistrationSync()
            }
        }
        model.updatePushRegistration(status: "正在注册后台来电与短信", ready: false)
        do {
            var existingState = loadRegistration()
            if let state = existingState,
               state.identityAccount == configuration.identity.account,
               state.serverID == configuration.identity.serverID,
               state.clientInstallationID == configuration.identity.clientInstallationID,
               state.moduleID != moduleID {
                try await model.unregisterPush(registrationID: state.registrationID)
                self.defaults.removeObject(forKey: Keys.registration)
                existingState = nil
            }
            let registration: V2StoredPushRegistration
            if let existing = existingState,
               existing.identityAccount == configuration.identity.account,
               existing.serverID == configuration.identity.serverID,
               existing.clientInstallationID == configuration.identity.clientInstallationID,
               existing.moduleID == moduleID {
                registration = existing
            } else {
                registration = V2StoredPushRegistration(
                    identityAccount: configuration.identity.account,
                    serverID: configuration.identity.serverID,
                    clientInstallationID: configuration.identity.clientInstallationID,
                    moduleID: moduleID,
                    registrationID: UUID().uuidString.lowercased()
                )
            }
            let body = V2PushRegistrationBody(
                registrationID: registration.registrationID,
                moduleID: moduleID,
                bundleID: Bundle.main.bundleIdentifier ?? "",
                environment: APNsEnvironment.current,
                voipToken: voIPToken,
                alertToken: Self.notificationAllowsAlerts(model.notificationPermission)
                    ? (defaults.string(forKey: Keys.alertToken) ?? "")
                    : ""
            )
            _ = try await model.registerPush(body)
            saveRegistration(registration)
            updateStatus(notificationStatus: await refreshNotificationStatus())
        } catch {
            model.updatePushRegistration(
                status: "推送注册失败，联网或连接恢复后重试",
                ready: false
            )
        }
    }

    func stopRuntime(unregister: Bool) async {
        if unregister, let model, model.connected, let registration = loadRegistration() {
            try? await model.unregisterPush(registrationID: registration.registrationID)
        }
        registry?.desiredPushTypes = []
        registry?.delegate = nil
        registry = nil
        self.model = nil
    }

#if DEBUG
    var lastIncomingDiagnostic: String { defaults.string(forKey: "airsim.v2.last-incoming-diagnostic") ?? "尚未收到" }
#endif
    private func recordIncomingDiagnostic(_ value: String) {
#if DEBUG
        defaults.set(value, forKey: "airsim.v2.last-incoming-diagnostic")
        NSLog("[AirSIM Push] incoming result=%@", value)
#endif
    }

    func acceptsIncomingPush(_ call: IncomingVoIPCall) -> Bool {
        guard let model, model.isV2Runtime,
              let configuration = model.configuration,
              let envelope = call.v2Push,
              let state = loadRegistration(),
              model.selectedModuleID == envelope.domain.moduleID,
              state.identityAccount == configuration.identity.account,
              state.serverID == envelope.domain.serverID,
              state.clientInstallationID == envelope.domain.clientInstallationID,
              state.moduleID == envelope.domain.moduleID,
              state.registrationID == envelope.domain.registrationID else { return false }
        return true
    }

    func acceptsAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let domain = V2PushDomain(userInfo: userInfo),
              userInfo["event"] as? String == "incoming_sms",
              let model,
              model.isV2Runtime,
              let configuration = model.configuration,
              let state = loadRegistration(),
              model.selectedModuleID == domain.moduleID,
              state.identityAccount == configuration.identity.account,
              state.serverID == domain.serverID,
              state.clientInstallationID == domain.clientInstallationID,
              state.moduleID == domain.moduleID,
              state.registrationID == domain.registrationID else { return false }
        return true
    }

    private func updateStatus(notificationStatus: UNAuthorizationStatus? = nil) {
        guard let model else { return }
        let notes = notificationStatus ?? model.notificationPermission
        if !voIPTokenReady {
            model.updatePushRegistration(status: "等待 PushKit token", ready: false)
        } else if !model.connected {
            model.updatePushRegistration(status: "等待云端 v2 连接", ready: false)
        } else if !Self.notificationAllowsAlerts(notes) {
            let registered = loadRegistration() != nil
            model.updatePushRegistration(
                status: registered ? "后台来电已注册；短信通知已关闭" : "通知权限已关闭，连接后仍会启用后台来电",
                ready: registered
            )
        } else if !alertTokenReady {
            model.updatePushRegistration(status: "PushKit 已就绪，等待通知 token", ready: false)
        } else if loadRegistration() != nil {
            model.updatePushRegistration(status: "后台来电与短信已注册", ready: notificationStatus != .denied)
        } else {
            model.updatePushRegistration(status: "正在注册后台推送", ready: false)
        }
    }

    private static func notificationAllowsAlerts(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    private func loadRegistration() -> V2StoredPushRegistration? {
        guard let data = defaults.data(forKey: Keys.registration) else { return nil }
        return try? JSONDecoder().decode(V2StoredPushRegistration.self, from: data)
    }

    private func saveRegistration(_ registration: V2StoredPushRegistration) {
        guard let data = try? JSONEncoder().encode(registration) else { return }
        defaults.set(data, forKey: Keys.registration)
    }
}

extension V2PushController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = VoIPPushToken.hex(pushCredentials.token)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defaults.set(token, forKey: Keys.voIPToken)
            requestRegistrationSync()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defaults.removeObject(forKey: Keys.voIPToken)
            updateStatus()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        let userInfo = payload.dictionaryPayload
        Task { @MainActor [weak self] in
            guard let self else {
                ExpiredLegacyPushReporter.shared.report(reason: "v2_controller_unavailable", completion: completion)
                return
            }
            do {
                let call = try IncomingVoIPCall(userInfo: userInfo)
                guard acceptsIncomingPush(call) else {
                    recordIncomingDiagnostic("domain_mismatch")
                    ExpiredLegacyPushReporter.shared.report(reason: "v2_domain_mismatch", completion: completion)
                    return
                }
                self.model?.activateSystemIntegration()
                CallKitController.shared.reportIncomingPush(call) { error in
                    if let error {
                        self.recordIncomingDiagnostic("callkit_rejected:\((error as NSError).code)")
                        switch error as? CallKitBridgeError {
                        case .unavailable:
                            ExpiredLegacyPushReporter.shared.report(reason: "v2_report_unavailable", completion: completion)
                        case .callInProgress:
                            // 已有系统通话在进行，满足 PushKit 上报要求，不再插入占位来电。
                            completion()
                        default:
                            completion()
                        }
                    } else {
                        self.recordIncomingDiagnostic("reported")
                        completion()
                    }
                }
            } catch {
                recordIncomingDiagnostic((error as? VoIPPushPayloadError) == .expired ? "payload_expired" : "payload_invalid")
                ExpiredLegacyPushReporter.shared.report(reason: "v2_payload_invalid", completion: completion)
            }
        }
    }
}
