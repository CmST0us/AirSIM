import Foundation
import Security

struct V2PairingLookup: Codable, Equatable {
    let request_id: String
    let server_id: String
    let module_id: String
    let name: String
    let short_id: String
    let online: Bool
    let expires_at: String
    func validate(now: Date) throws {
        try V2Validation.uuid(request_id); try V2Validation.uuid(server_id); try V2Validation.uuid(module_id)
        let remaining = try V2Validation.date(expires_at).timeIntervalSince(now)
        guard !name.isEmpty, name.count <= 100, short_id == String(module_id.suffix(8)),
              remaining > 0, remaining <= 305 else { throw V2Error.expired }
    }
}
struct V2PairingPending: Codable, Equatable {
    let origin: String
    let code: String
    let device: V2PairingLookup
    let claimID: String
    let installationID: String
    let refreshToken: String
}
struct V2PairedSession: Codable, Equatable {
    let configuration: V2Configuration
    let token: String
    let refreshToken: String
    let name: String
}
struct V2PairingState: Codable {
    var pending: V2PairingPending?
    var session: V2PairedSession?
}
protocol V2PairingStore {
    func load() throws -> V2PairingState
    func save(_ state: V2PairingState) throws
}
struct V2KeychainPairingStore: V2PairingStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cc.eric3u.airsim.cloud.v2", kSecAttrAccount as String: "pairing-session", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> V2PairingState {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return V2PairingState() }
        guard status == errSecSuccess, let data = result as? Data else { throw V2Error.keychain }
        do { return try JSONDecoder().decode(V2PairingState.self, from: data) } catch { throw V2Error.keychain }
    }
    func save(_ state: V2PairingState) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(state), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw V2Error.keychain }
        } else if status != errSecSuccess { throw V2Error.keychain }
    }
}
struct V2SessionResponse: Decodable {
    let schema_version: Int
    let api_origin: String
    let media_origin: String
    let server_id: String
    let module_id: String
    let client_installation_id: String
    let token: String
    let expires_at: String?
    let refresh_expires_at: String?
    let persistent_session: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields(
            "schema_version api_origin media_origin server_id module_id client_installation_id token",
            optional: "expires_at refresh_expires_at persistent_session"
        )
        schema_version = try c.get("schema_version")
        api_origin = try c.get("api_origin")
        media_origin = try c.get("media_origin")
        server_id = try c.get("server_id")
        module_id = try c.get("module_id")
        client_installation_id = try c.get("client_installation_id")
        token = try c.get("token")
        expires_at = try c.nullable("expires_at")
        refresh_expires_at = try c.nullable("refresh_expires_at")
        persistent_session = try c.optional("persistent_session")
    }
    func session(origin: String, server: String, module: String, installation: String, refreshToken: String, name: String, now: Date) throws -> V2PairedSession {
        guard [2, 3].contains(schema_version), api_origin == origin, server_id == server, module_id == module,
              client_installation_id == installation, V2Validation.matches(token, "^[0-9a-f]{64}$") else { throw V2Error.invalidIdentity }
        try V2Validation.uuid(server_id); try V2Validation.uuid(module_id); try V2Validation.uuid(client_installation_id)
        let expiry = try expires_at.map(V2Validation.date)
        let refreshExpiry = try refresh_expires_at.map(V2Validation.date)
        if schema_version == 3 {
            guard persistent_session == true, expiry == nil, refreshExpiry == nil else { throw V2Error.invalidIdentity }
        } else {
            guard let expiry, let refreshExpiry, (0...3900).contains(expiry.timeIntervalSince(now)), expiry > now else { throw V2Error.expired }
            if persistent_session != true {
                guard refreshExpiry > now, refreshExpiry.timeIntervalSince(now) <= 90 * 86400 + 300 else { throw V2Error.expired }
            }
        }
        let config = try V2Configuration(identity: V2Identity(apiOrigin: V2Validation.origin(api_origin), serverID: server_id, clientInstallationID: client_installation_id), mediaOrigin: V2Validation.origin(media_origin), expiresAt: expiry, moduleID: module_id, refreshExpiresAt: refreshExpiry, persistentSession: persistent_session ?? false)
        return V2PairedSession(configuration: config, token: token, refreshToken: refreshToken, name: name)
    }
}
@MainActor
final class V2PairingClient {
    let origin: String?
    let store: V2PairingStore
    private let transport: V2HTTPTransport
    private let now: () -> Date
    private var claiming = false
    init(origin: String?, store: V2PairingStore, transport: V2HTTPTransport = V2URLSessionTransport(), now: @escaping () -> Date = Date.init) {
        self.origin = origin.flatMap { try? V2Validation.origin($0) }; self.store = store; self.transport = transport; self.now = now
    }
    static var deploymentOrigin: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AirSIMV2PairingOrigin") as? String,
              !value.isEmpty, !value.contains("$("), !value.contains(".invalid") else { return nil }
        return try? V2Validation.origin(value)
    }
    func lookup(code: String) async throws -> V2PairingLookup {
        guard let origin, V2Validation.matches(code, "^[0-9]{8}$") else { throw V2Error.invalidValue }
        let response = try await Self.post(origin: origin, path: "/v2/pairing/lookup", fields: ["code": code], transport: transport)
        let device = try V2JSON.decode(V2PairingLookup.self, from: response, limit: 16 * 1024)
        try device.validate(now: now()); return device
    }
    func pendingClaim() throws -> (code: String, device: V2PairingLookup)? {
        guard let pending = try store.load().pending else { return nil }
        return (pending.code, pending.device)
    }
    func clearPendingClaim() throws {
        var state = try store.load()
        state.pending = nil
        try store.save(state)
    }
    func claim(code: String, device: V2PairingLookup) async throws -> V2PairedSession {
        guard !claiming, let origin else { throw V2Error.busy }
        claiming = true; defer { claiming = false }
        var state = try store.load()
        let pending: V2PairingPending
        if let existing = state.pending {
            guard existing.origin == origin, existing.code == code, existing.device == device else { throw V2Error.busy }
            pending = existing
        } else {
            try device.validate(now: now())
            guard V2Validation.matches(code, "^[0-9]{8}$") else { throw V2Error.invalidValue }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw V2Error.keychain }
            pending = V2PairingPending(origin: origin, code: code, device: device, claimID: UUID().uuidString.lowercased(), installationID: UUID().uuidString.lowercased(), refreshToken: bytes.map { String(format: "%02x", $0) }.joined())
            state.pending = pending
            try store.save(state)
        }
        let data = try await Self.post(origin: origin, path: "/v2/pairing/claim", fields: ["code": pending.code, "claim_id": pending.claimID, "client_installation_id": pending.installationID, "refresh_token": pending.refreshToken], transport: transport)
        let response = try V2JSON.decode(V2SessionResponse.self, from: data, limit: 16 * 1024)
        let session = try response.session(origin: origin, server: device.server_id, module: device.module_id, installation: pending.installationID, refreshToken: pending.refreshToken, name: device.name, now: now())
        // One Keychain replacement commits the complete session and removes the pending claim.
        state.session = session; state.pending = nil
        try store.save(state)
        return session
    }
    func refresh(_ current: V2Configuration, store configurationStore: V2ConfigurationStore) async throws -> V2Configuration {
        guard let origin, current.identity.apiOrigin == origin,
              current.moduleID != nil, current.canRenew(at: now()) else { throw V2Error.expired }
        let state = try self.store.load()
        guard let session = state.session, session.configuration.identity == current.identity,
              session.configuration.moduleID == current.moduleID else { throw V2Error.invalidIdentity }
        let data = try await Self.post(origin: origin, path: "/v2/client-sessions/refresh", fields: [
            "client_installation_id": current.identity.clientInstallationID,
            "refresh_token": session.refreshToken,
        ], transport: transport)
        let response = try V2JSON.decode(V2SessionResponse.self, from: data, limit: 16 * 1024)
        guard let module = current.moduleID else { throw V2Error.invalidIdentity }
        let renewed = try response.session(
            origin: origin, server: current.identity.serverID, module: module,
            installation: current.identity.clientInstallationID,
            refreshToken: session.refreshToken, name: session.name, now: now()
        )
        try configurationStore.commitPairedSession(renewed)
        return renewed.configuration
    }
    static func post(origin: String, path: String, fields: [String: String], transport: V2HTTPTransport) async throws -> Data {
        guard try V2Validation.origin(origin) == origin, let url = URL(string: origin + path) else { throw V2Error.invalidValue }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request, limit: 16 * 1024)
        guard response.body.count <= 16 * 1024 else { throw V2Error.oversized }
        guard response.status == 200 || response.status == 201 else { throw V2HTTPFailure(status: response.status) }
        return response.body
    }
}
