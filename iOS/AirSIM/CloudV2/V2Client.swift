import Foundation

struct V2ControlBinding: Codable, Equatable {
    let identity: V2Identity
    let moduleID: String
    let bootID: String
    let backendEpoch: String
    let connectionEpoch: String
}
struct V2CallContext: Codable, Equatable {
    let binding: V2ControlBinding
    let callID: String
    let generation: String
}

struct V2PushRegistrationBody: Encodable, Equatable {
    let registrationID: String
    let moduleID: String
    let bundleID: String
    let environment: String
    let voipToken: String
    let alertToken: String

    enum CodingKeys: String, CodingKey {
        case registrationID = "registration_id"
        case moduleID = "module_id"
        case bundleID = "bundle_id"
        case environment
        case voipToken = "voip_token"
        case alertToken = "alert_token"
    }
}

struct V2PushRegistrationReceipt: Decodable, Equatable {
    let server_id: String
    let client_installation_id: String
    let registration_id: String
    let module_id: String
    let bundle_id: String
    let environment: String
}
extension V2SnapshotResponse {
    func controlBinding(configuration: V2Configuration, module: V2Module, now: Date) throws -> V2ControlBinding {
        guard server_id == configuration.identity.serverID, module_id == module.module_id,
              online, module.online, let snapshot,
              connection_epoch == module.connection_epoch,
              snapshot.agent_boot_id == module.agent_boot_id,
              snapshot.backend_epoch == module.backend_epoch else { throw V2Error.stale }
        try V2Validation.uuid(snapshot.agent_boot_id); try V2Validation.uuid(snapshot.backend_epoch); try V2Validation.uuid(connection_epoch)
        let age = now.timeIntervalSince(snapshot.observedAt)
        guard (-3...8).contains(age) else { throw V2Error.stale }
        return V2ControlBinding(identity: configuration.identity, moduleID: module_id, bootID: snapshot.agent_boot_id, backendEpoch: snapshot.backend_epoch, connectionEpoch: connection_epoch)
    }
    func matches(_ context: V2CallContext, now: Date) -> Bool {
        guard online, server_id == context.binding.identity.serverID, module_id == context.binding.moduleID,
              connection_epoch == context.binding.connectionEpoch, let snapshot,
              snapshot.agent_boot_id == context.binding.bootID, snapshot.backend_epoch == context.binding.backendEpoch,
              (-3...8).contains(now.timeIntervalSince(snapshot.observedAt)) else { return false }
        return snapshot.calls.calls.contains { $0.call_id == context.callID && $0.state != "disconnected" }
    }
}

@MainActor
final class V2Client {
    private let transport: V2HTTPTransport
    private let tokens: V2TokenStore
    private let now: () -> Date
    private(set) var gate = V2SessionGate()
    private var token: String?
    private var verified = false
    private var inFlight = Set<String>()
    private var ownedCalls: [V2CallContext] = []
    private var refreshTask: Task<V2Configuration, Error>?
    // M2/M3 attach lifecycle teardown here; no global work is started in M1.
    var onAuthenticationInvalidated: (() -> Void)?
    var onControlInvalidated: (() -> Void)?
    var onRefreshConfiguration: ((V2Configuration) async throws -> V2Configuration?)?
    init(transport: V2HTTPTransport, tokens: V2TokenStore, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.tokens = tokens; self.now = now
    }
    var configuration: V2Configuration? { gate.configuration }
    var stamp: V2SessionStamp? { configuration.map { V2SessionStamp(identity: $0.identity, generation: gate.generation) } }
    func stop() {
        refreshTask?.cancel(); refreshTask = nil
        gate.stop(); token = nil; verified = false; inFlight.removeAll(); ownedCalls.removeAll()
    }
    func connect(_ config: V2Configuration) async throws -> V2Discovery {
        stop()
        guard try V2Validation.origin(config.identity.apiOrigin) == config.identity.apiOrigin,
              try V2Validation.origin(config.mediaOrigin) == config.mediaOrigin else { throw V2Error.invalidValue }
        try V2Validation.uuid(config.identity.serverID); try V2Validation.uuid(config.identity.clientInstallationID)
        guard config.canConnect(at: now()) else { throw V2Error.expired }
        let stamp = gate.start(config)
        do {
            try await prepareAccess(stamp)
            let response = try await request(path: "/.well-known/airsim", method: "GET", body: nil, limit: 16 * 1024, authorized: false, stamp: stamp)
            guard response.status == 200 else { throw V2HTTPFailure(status: response.status) }
            let discovery = try V2JSON.decode(V2Discovery.self, from: response.body, limit: 16 * 1024)
            guard discovery.server_id == config.identity.serverID,
                  try V2Validation.origin(discovery.api_origin) == config.identity.apiOrigin,
                  try V2Validation.origin(discovery.media_origin) == config.mediaOrigin else { throw V2Error.invalidIdentity }
            let token = try tokens.read(account: config.identity.account)
            guard gate.accepts(stamp) else { throw V2Error.stale }
            self.token = token; verified = true
            return discovery
        } catch { if gate.accepts(stamp) { stop() }; throw error }
    }
    private func activeStamp() throws -> V2SessionStamp {
        guard verified, token != nil, let stamp else { throw V2Error.unauthorized }
        return stamp
    }
    private func request(path: String, method: String, body: Data?, limit: Int, authorized: Bool = true, stamp: V2SessionStamp) async throws -> V2HTTPResponse {
        guard gate.accepts(stamp), configuration != nil else { throw V2Error.stale }
        if authorized { try await prepareAccess(stamp) }
        guard let config = configuration, config.accessIsValid(at: now()) else { throw V2Error.expired }
        guard let url = URL(string: config.identity.apiOrigin + path) else { throw V2Error.invalidValue }
        let flight = "\(stamp.generation):\(method):\(path)"
        guard inFlight.insert(flight).inserted else { throw V2Error.busy }
        defer { inFlight.remove(flight) }
        for attempt in 0..<2 {
            guard gate.accepts(stamp), let current = configuration else { throw V2Error.stale }
            if !current.accessIsValid(at: now()), attempt == 0, authorized {
                try await refreshAccess(stamp)
                continue
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = method; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if authorized {
                guard verified, let token else { throw V2Error.unauthorized }
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            let response: V2HTTPResponse
            do { response = try await transport.send(request, limit: limit) }
            catch { guard gate.accepts(stamp) else { throw V2Error.stale }; throw (error as? V2Error ?? .transport) }
            if method == "GET" { try Task.checkCancellation() }
            guard gate.accepts(stamp) else { throw V2Error.stale }
            guard response.body.count <= limit else { throw V2Error.oversized }
            if authorized, response.status == 401, attempt == 0 {
                do {
                    try await refreshAccess(stamp)
                    continue
                } catch {
                    invalidateAuthentication()
                    throw error
                }
            }
            if response.status == 401 { invalidateAuthentication(); throw V2HTTPFailure(status: 401) }
            if response.status == 409 || response.status == 503 { ownedCalls.removeAll(); onControlInvalidated?() }
            guard (200..<300).contains(response.status) else { throw V2HTTPFailure(status: response.status) }
            return response
        }
        throw V2Error.unauthorized
    }
    private func prepareAccess(_ stamp: V2SessionStamp) async throws {
        guard gate.accepts(stamp), let config = configuration else { throw V2Error.stale }
        if config.persistentSession == true { return }
        guard let expiry = config.expiresAt else {
            try await refreshAccess(stamp)
            return
        }
        let remaining = expiry.timeIntervalSince(now())
        guard remaining <= 5 * 60 else { return }
        guard config.canRenew(at: now()) else {
            if remaining > 0 { return }
            throw V2Error.expired
        }
        do { try await refreshAccess(stamp) }
        catch let error as V2Error where error == .transport && remaining > 0 { return }
    }
    private func refreshAccess(_ stamp: V2SessionStamp) async throws {
        guard gate.accepts(stamp), let current = configuration,
              current.canRenew(at: now()),
              let refresh = onRefreshConfiguration else { throw V2Error.expired }
        let task: Task<V2Configuration, Error>
        if let refreshTask { task = refreshTask }
        else {
            task = Task {
                guard let renewed = try await refresh(current) else { throw V2Error.expired }
                return renewed
            }
            refreshTask = task
        }
        do {
            let renewed = try await task.value
            guard gate.accepts(stamp), renewed.identity == current.identity,
                  renewed.moduleID == current.moduleID, renewed.canConnect(at: now()),
                  renewed.canRenew(at: now()) else {
                throw V2Error.invalidIdentity
            }
            if renewed.persistentSession != true {
                guard let renewedRefresh = renewed.refreshExpiresAt,
                      renewedRefresh.timeIntervalSince(now()) <= 90 * 86400 + 300 else {
                    throw V2Error.invalidIdentity
                }
            }
            gate.refresh(renewed)
            token = try tokens.read(account: renewed.identity.account)
            verified = true
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }
    private func invalidateAuthentication() { stop(); onAuthenticationInvalidated?() }
    private func read<T: Decodable>(_ type: T.Type, path: String, limit: Int = 256 * 1024) async throws -> T {
        let response = try await request(path: path, method: "GET", body: nil, limit: limit, stamp: activeStamp())
        guard response.status == 200 else { throw V2Error.protocolViolation }
        return try V2JSON.decode(type, from: response.body, limit: limit)
    }
    func modules() async throws -> V2Modules {
        let stamp = try activeStamp()
        let result = try await read(V2Modules.self, path: "/v2/modules")
        guard result.server_id == stamp.identity.serverID else { throw V2Error.invalidIdentity }
        return result
    }
    func snapshot(moduleID: String) async throws -> V2SnapshotResponse {
        try V2Validation.uuid(moduleID); let stamp = try activeStamp()
        let result = try await read(V2SnapshotResponse.self, path: "/v2/modules/\(moduleID)/snapshot")
        guard result.server_id == stamp.identity.serverID, result.module_id == moduleID else { throw V2Error.invalidIdentity }
        let invalidated = ownedCalls.contains { $0.binding.moduleID == moduleID && !result.matches($0, now: now()) }
        if !result.online || invalidated {
            ownedCalls.removeAll { $0.binding.moduleID == moduleID }
            onControlInvalidated?()
        }
        return result
    }
    func messages(moduleID: String) async throws -> V2MessagesResponse {
        try V2Validation.uuid(moduleID); let stamp = try activeStamp()
        let result = try await read(V2MessagesResponse.self, path: "/v2/modules/\(moduleID)/messages", limit: 2 * 1024 * 1024)
        guard result.server_id == stamp.identity.serverID, result.module_id == moduleID else { throw V2Error.invalidIdentity }
        return result
    }
    func registerPush(_ body: V2PushRegistrationBody) async throws -> V2PushRegistrationReceipt {
        let stamp = try activeStamp()
        guard stamp.identity.serverID == gate.configuration?.identity.serverID,
              stamp.identity.clientInstallationID == gate.configuration?.identity.clientInstallationID else {
            throw V2Error.invalidIdentity
        }
        let data = try JSONEncoder().encode(body)
        let response = try await request(path: "/v2/push/registration", method: "PUT", body: data, limit: 16 * 1024, stamp: stamp)
        let receipt = try V2JSON.decode(V2PushRegistrationReceipt.self, from: response.body, limit: 16 * 1024)
        guard response.status == 200, receipt.server_id == stamp.identity.serverID,
              receipt.client_installation_id == stamp.identity.clientInstallationID,
              receipt.registration_id == body.registrationID,
              receipt.module_id == body.moduleID,
              receipt.bundle_id == body.bundleID,
              receipt.environment == body.environment else {
            throw V2Error.protocolViolation
        }
        return receipt
    }
    func unregisterPush(registrationID: String) async throws {
        try V2Validation.uuid(registrationID)
        let stamp = try activeStamp()
        let body = try JSONSerialization.data(withJSONObject: ["registration_id": registrationID])
        let response = try await request(path: "/v2/push/registration", method: "DELETE", body: body, limit: 16 * 1024, stamp: stamp)
        guard response.status == 204, response.body.isEmpty else { throw V2Error.protocolViolation }
    }
    func submit(_ command: V2Command, binding: V2ControlBinding) async throws -> V2CommandRecord {
        let stamp = try activeStamp()
        guard stamp.identity == binding.identity, command.agent_boot_id == binding.bootID, command.backend_epoch == binding.backendEpoch else { throw V2Error.invalidIdentity }
        try V2Validation.uuid(binding.moduleID); try V2Validation.uuid(binding.connectionEpoch)
        let body = try JSONEncoder().encode(V2CommandEnvelope(connection_epoch: binding.connectionEpoch, command: command))
        let response = try await request(path: "/v2/modules/\(binding.moduleID)/commands", method: "POST", body: body, limit: 256 * 1024, stamp: stamp)
        guard [200,202].contains(response.status) else { throw V2Error.protocolViolation }
        let result = try V2JSON.decode(V2CommandRecord.self, from: response.body, limit: 256 * 1024)
        guard result.command_id == command.command_id, result.receipt == nil || result.receipt?.action == command.action else { throw V2Error.invalidIdentity }
        return result
    }
    func receipt(binding: V2ControlBinding, commandID: String) async throws -> V2CommandRecord {
        guard try activeStamp().identity == binding.identity else { throw V2Error.invalidIdentity }
        try V2Validation.uuid(binding.moduleID); try V2Validation.uuid(commandID)
        let result = try await read(V2CommandRecord.self, path: "/v2/modules/\(binding.moduleID)/commands/\(commandID)")
        guard result.command_id == commandID else { throw V2Error.invalidIdentity }
        return result
    }
    func createMedia(context: V2CallContext, requestID: String) async throws -> V2MediaCreated {
        let stamp = try activeStamp(); try validate(context, stamp: stamp); try V2Validation.uuid(requestID)
        guard ownedCalls.contains(context) else { throw V2Error.invalidIdentity }
        let body = try JSONSerialization.data(withJSONObject: ["request_id": requestID, "connection_epoch": context.binding.connectionEpoch, "generation": context.generation])
        let response = try await request(path: mediaPath(context), method: "POST", body: body, limit: 256 * 1024, stamp: stamp)
        guard [200,201].contains(response.status), let config = configuration else { throw V2Error.protocolViolation }
        let result = try V2JSON.decode(V2MediaCreated.self, from: response.body, limit: 256 * 1024)
        guard result.media_url == "wss" + config.mediaOrigin.dropFirst(5) + "/v2/media" else { throw V2Error.invalidIdentity }
        let remaining = try V2Validation.date(result.expires_at).timeIntervalSince(now())
        guard remaining > 0, remaining <= 35 else { throw V2Error.expired }
        return result
    }
    func deleteMedia(context: V2CallContext, sessionID: String) async throws {
        let stamp = try activeStamp(); try validate(context, stamp: stamp); try V2Validation.uuid(sessionID)
        let response = try await request(path: mediaPath(context) + "/" + sessionID, method: "DELETE", body: nil, limit: 256 * 1024, stamp: stamp)
        guard response.status == 204, response.body.isEmpty else { throw V2Error.protocolViolation }
    }
    func restoreOwnership(_ context: V2CallContext, snapshot: V2SnapshotResponse) throws {
        guard try activeStamp().identity == context.binding.identity, snapshot.matches(context, now: now()) else { throw V2Error.stale }
        try context.validate()
        ownedCalls.removeAll { $0.binding.moduleID == context.binding.moduleID }; ownedCalls.append(context)
    }
    func recordOwnership(_ record: V2CommandRecord, pending: V2PendingCommand) throws -> V2CallContext? {
        guard try activeStamp().identity == pending.binding.identity,
              record.command_id == pending.commandID, record.receipt?.action == pending.action else { throw V2Error.invalidIdentity }
        guard ["call.dial", "call.answer"].contains(pending.action),
              let receipt = record.receipt, ["accepted", "observed"].contains(receipt.state),
              let callID = receipt.call_id else { return nil }
        let context = V2CallContext(binding: pending.binding, callID: callID, generation: record.generation)
        ownedCalls.removeAll { $0.binding.moduleID == context.binding.moduleID }
        ownedCalls.append(context)
        return context
    }
    private func mediaPath(_ context: V2CallContext) -> String { "/v2/modules/\(context.binding.moduleID)/calls/\(context.callID)/media-sessions" }
    private func validate(_ context: V2CallContext, stamp: V2SessionStamp) throws {
        guard context.binding.identity == stamp.identity else { throw V2Error.invalidIdentity }
        try V2Validation.uuid(context.binding.moduleID); try V2Validation.uuid(context.callID); try V2Validation.uuid(context.generation); try V2Validation.uuid(context.binding.connectionEpoch)
    }
}

// Scheduling policy only. M2 owns task creation and foreground lifetime.
struct V2PollBackoff {
    private(set) var failures = 0
    mutating func failed() -> TimeInterval { failures = min(failures + 1, 5); return [1,2,4,8,15][failures - 1] }
    mutating func succeeded() -> TimeInterval { failures = 0; return 1 }
}
