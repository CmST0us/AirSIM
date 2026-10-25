import Foundation
import CryptoKit

struct V2ProtectedFile<Value: Codable> {
    let url: URL
    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url)) }
        catch { throw V2Error.persistence }
    }
    func save(_ value: Value) throws {
        do {
            let root = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
            var destination = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try destination.setResourceValues(flags)
        } catch { throw V2Error.persistence }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { throw V2Error.persistence }
        }
    }
}
protocol V2OwnedCallStore {
    func load() throws -> V2CallContext?
    func save(_ context: V2CallContext) throws
    func clear() throws
}
struct V2FileOwnedCallStore: V2OwnedCallStore {
    let file: V2ProtectedFile<V2CallContext>
    func load() throws -> V2CallContext? { let value = try file.load(); try value?.validate(); return value }
    func save(_ context: V2CallContext) throws { try context.validate(); try file.save(context) }
    func clear() throws { try file.clear() }
}
extension V2CallContext {
    func validate() throws {
        try V2PendingCommand(binding: binding, commandID: callID, action: "call.hangup", generation: generation, callID: callID).validate()
    }
}
struct V2HistoryDomain: Codable, Equatable {
    let identity: V2Identity
    let moduleID: String
    let bootID: String
    let backendEpoch: String
}
struct V2StoredMessage: Codable, Identifiable, Equatable {
    let domain: V2HistoryDomain
    let message: V2Message
    let inboxGap: Bool
    let inboxDropped: UInt64
    var id: String { domain.identity.account + domain.moduleID + domain.bootID + domain.backendEpoch + message.message_id }
}
struct V2StoredCall: Codable, Identifiable, Equatable {
    let domain: V2HistoryDomain
    let call: V2Call
    var id: String { domain.identity.account + domain.moduleID + domain.bootID + domain.backendEpoch + call.call_id }
}
struct V2History: Codable {
    var messages: [V2StoredMessage] = []
    var calls: [V2StoredCall] = []
    var clearedMessageIDs: [String]? = nil
    @discardableResult
    mutating func merge(messages incoming: [V2StoredMessage]) -> Bool {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var changed = byID.count != messages.count || messages.count > 2000
        let cleared = Set(clearedMessageIDs ?? [])
        for item in incoming where !cleared.contains(item.id) && byID[item.id] != item { byID[item.id] = item; changed = true }
        guard changed else { return false }
        let candidate = Array(byID.values.sorted {
            if $0.message.observedAt != $1.message.observedAt { return $0.message.observedAt > $1.message.observedAt }
            return $0.id < $1.id
        }.prefix(2000))
        guard candidate != messages else { return false }
        messages = candidate
        return true
    }
    @discardableResult
    mutating func merge(calls incoming: [V2StoredCall]) -> Bool {
        var byID = Dictionary(calls.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var changed = byID.count != calls.count || calls.count > 500
        for item in incoming where byID[item.id] != item { byID[item.id] = item; changed = true }
        guard changed else { return false }
        let candidate = Array(byID.values.sorted {
            if $0.call.observedAt != $1.call.observedAt { return $0.call.observedAt > $1.call.observedAt }
            return $0.id < $1.id
        }.prefix(500))
        guard candidate != calls else { return false }
        calls = candidate
        return true
    }
}
enum V2LocalPaths {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirSIMCloudV2", isDirectory: true) }
    static func selectionKey(_ identity: V2Identity) -> String {
        "airsim.v2.selected-module." + SHA256.hash(data: Data(identity.account.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
