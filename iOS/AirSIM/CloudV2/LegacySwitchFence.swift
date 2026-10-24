import Foundation
import CryptoKit

struct LegacySwitchOperation: Codable, Identifiable {
    let id: String
    let service: String
    let device: String
    let action: String
    let commandID: String?
    let callID: String?
    let callUUID: String?
    let callGeneration: UInt64?
    let traceID: String?
    let created: Date
    let runtime: UInt64
    var awaitingIdle = false
}
final class LegacySwitchFence: @unchecked Sendable {
    static let shared = LegacySwitchFence(url: V2LocalPaths.root.deletingLastPathComponent().appendingPathComponent("AirSIMLegacySwitch/operations.json"))
    private let lock = NSLock()
    private let file: V2ProtectedFile<[LegacySwitchOperation]>
    private var operations: [LegacySwitchOperation] = []
    private var failed = false
    init(url: URL) {
        file = V2ProtectedFile(url: url)
        do { operations = try file.load() ?? [] } catch { failed = true }
    }
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return failed || !operations.isEmpty }
    var pending: [LegacySwitchOperation] { lock.lock(); defer { lock.unlock() }; return operations }
    static func localDevice(_ credential: VoWLANCredential?) -> String {
        guard let credential else { return "unpaired" }
        return SHA256.hash(data: credential.secret).map { String(format: "%02x", $0) }.joined()
    }
    func begin(service: String, device: String, action: String, commandID: String? = nil, callID: String? = nil, callUUID: String? = nil, callGeneration: UInt64? = nil, traceID: String? = nil) throws -> String {
        let stamp = LegacyRuntimeGate.generation
        guard LegacyRuntimeGate.accepts(stamp) else { throw CancellationError() }
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw V2Error.persistence }
        let id = UUID().uuidString
        let op = LegacySwitchOperation(id: id, service: service, device: device, action: action, commandID: commandID, callID: callID, callUUID: callUUID, callGeneration: callGeneration, traceID: traceID, created: Date(), runtime: stamp)
        var next = operations; next.append(op); try file.save(next); operations = next
        return id
    }
    func resolve(_ id: String, runtime: UInt64, awaitIdle: Bool = false) throws {
        guard LegacyRuntimeGate.accepts(runtime) else { return }
        lock.lock(); defer { lock.unlock() }
        var next = operations
        if awaitIdle, let index = next.firstIndex(where: { $0.id == id }) { next[index].awaitingIdle = true }
        else { next.removeAll { $0.id == id } }
        try file.save(next); operations = next
    }
    func resolveCommand(service: String, device: String, commandID: String, runtime: UInt64) throws {
        for op in pending where op.service == service && op.device == device && op.commandID == commandID { try resolve(op.id, runtime: runtime) }
    }
    func observeLocal(_ status: CallStatus, service: String, device: String, runtime: UInt64) throws {
        guard status.lastPollError.isEmpty else { return }
        for op in pending where op.service == service && op.device == device {
            if op.awaitingIdle, status.active == nil { try resolve(op.id, runtime: runtime); continue }
            guard let callID = op.callID else { continue }
            let calls = (status.history ?? []) + [status.active].compactMap { $0 }
            guard let call = calls.first(where: { $0.id == callID }), call.updatedAt >= op.created,
                  Date().timeIntervalSince(call.updatedAt) <= 8 else { continue }
            if op.action == "api/calls/answer", ["active", "held"].contains(call.state) { try resolve(op.id, runtime: runtime) }
            if ["api/calls/hangup", "api/calls/reject"].contains(op.action), call.endedAt != nil, status.active == nil { try resolve(op.id, runtime: runtime) }
        }
    }
    static func businessPath(_ path: String) -> Bool {
        ["api/calls/dial", "api/calls/answer", "api/calls/reject", "api/calls/hangup", "api/calls/dtmf", "api/sms/send"].contains(path)
    }
}

// Synchronous reservation closes the stop-media → enqueue-task scheduling window.
enum LegacyBusinessReservations {
    private static let lock = NSLock()
    private static var ids = Set<UUID>()
    static var pending: Bool { lock.lock(); defer { lock.unlock() }; return !ids.isEmpty }
    static func reserve() -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); ids.insert(id); return id }
    static func release(_ id: UUID) { lock.lock(); ids.remove(id); lock.unlock() }
}
