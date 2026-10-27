import Foundation
import Security

struct V2Identity: Codable, Equatable, Hashable {
    let apiOrigin: String
    let serverID: String
    let clientInstallationID: String
    var account: String {
        // Length-prefixed components are unambiguous even for IPv6/explicit ports.
        ["v2", apiOrigin, serverID, clientInstallationID].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
struct V2Configuration: Codable, Equatable {
    let identity: V2Identity
    let mediaOrigin: String
    let expiresAt: Date
    var moduleID: String? = nil
    var refreshExpiresAt: Date? = nil
    var persistentSession: Bool? = nil
    func canRenew(at date: Date) -> Bool {
        persistentSession == true || moduleID != nil || (refreshExpiresAt ?? .distantPast) > date
    }
    func canConnect(at date: Date) -> Bool {
        expiresAt > date || canRenew(at: date)
    }
}
struct V2ConfigurationImport: Decodable {
    let configuration: V2Configuration
    let token: String
    init(from decoder: Decoder) throws {
        let c = try decoder.v2Fields("schema_version api_origin media_origin server_id client_installation_id token expires_at")
        let version: Int = try c.get("schema_version")
        let api: String = try c.get("api_origin"), media: String = try c.get("media_origin")
        let server: String = try c.get("server_id"), client: String = try c.get("client_installation_id")
        token = try c.get("token")
        guard version == 1, V2Validation.matches(token, "^[0-9a-f]{64}$") else { throw V2Error.invalidValue }
        try V2Validation.uuid(server); try V2Validation.uuid(client)
        configuration = try V2Configuration(identity: V2Identity(apiOrigin: V2Validation.origin(api), serverID: server, clientInstallationID: client), mediaOrigin: V2Validation.origin(media), expiresAt: V2Validation.date(c.get("expires_at")))
    }
    static func parse(_ data: Data, now: Date) throws -> Self {
        let value = try V2JSON.decode(Self.self, from: data, limit: 16 * 1024)
        let remaining = value.configuration.expiresAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= 65 * 60 else { throw V2Error.expired }
        return value
    }
}
protocol V2TokenStore {
    func save(_ token: String, account: String) throws
    func read(account: String) throws -> String
    func remove(account: String) throws
}
struct V2KeychainTokenStore: V2TokenStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cc.eric3u.airsim.cloud.v2", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func save(_ token: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw V2Error.keychain }
        } else if status != errSecSuccess { throw V2Error.keychain }
    }
    func read(account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), V2Validation.matches(token, "^[0-9a-f]{64}$") else { throw V2Error.keychain }
        return token
    }
    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw V2Error.keychain }
    }
}
struct V2ConfigurationStore {
    let tokens: V2TokenStore
    let defaults: UserDefaults
    var pairings: V2PairingStore? = nil
    func importConfiguration(_ data: Data, now: Date) throws -> V2Configuration {
        let imported = try V2ConfigurationImport.parse(data, now: now)
        try tokens.save(imported.token, account: imported.configuration.identity.account)
        guard let metadata = try? JSONEncoder().encode(imported.configuration) else { throw V2Error.persistence }
        if let pairings {
            var state = try pairings.load(); state.session = nil
            try pairings.save(state)
        }
        defaults.set(metadata, forKey: "airsim.v2.configuration")
        return imported.configuration
    }
    func commitPairedSession(_ session: V2PairedSession) throws {
        guard let pairings else { throw V2Error.persistence }
        try tokens.save(session.token, account: session.configuration.identity.account)
        guard let metadata = try? JSONEncoder().encode(session.configuration) else { throw V2Error.persistence }
        var state = try pairings.load()
        state.session = session
        state.pending = nil
        try pairings.save(state)
        defaults.set(metadata, forKey: "airsim.v2.configuration")
    }
    func load() throws -> V2Configuration? {
        if let session = try pairings?.load().session {
            if (try? tokens.read(account: session.configuration.identity.account)) == nil {
                try tokens.save(session.token, account: session.configuration.identity.account)
            }
            return session.configuration
        }
        guard let data = defaults.data(forKey: "airsim.v2.configuration") else { return nil }
        guard let config = try? JSONDecoder().decode(V2Configuration.self, from: data),
              (try? V2Validation.origin(config.identity.apiOrigin)) == config.identity.apiOrigin,
              (try? V2Validation.origin(config.mediaOrigin)) == config.mediaOrigin else { throw V2Error.persistence }
        try V2Validation.uuid(config.identity.serverID); try V2Validation.uuid(config.identity.clientInstallationID)
        return config
    }
}
struct V2SessionStamp: Equatable { let identity: V2Identity; let generation: UInt64 }
struct V2SessionGate {
    private(set) var generation: UInt64 = 0
    private(set) var configuration: V2Configuration?
    mutating func start(_ configuration: V2Configuration) -> V2SessionStamp {
        generation &+= 1; self.configuration = configuration
        return V2SessionStamp(identity: configuration.identity, generation: generation)
    }
    mutating func refresh(_ configuration: V2Configuration) { self.configuration = configuration }
    mutating func stop() { generation &+= 1; configuration = nil }
    func accepts(_ stamp: V2SessionStamp) -> Bool { configuration?.identity == stamp.identity && generation == stamp.generation }
}
