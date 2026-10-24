import Foundation

struct V2Command: Encodable {
    let command_id: String
    let agent_boot_id: String
    let backend_epoch: String
    let deadline: String
    let action: String
    let args: [String: String]
    init(binding: V2ControlBinding, action: String, args: [String: String], now: Date, id: String = UUID().uuidString.lowercased()) throws {
        try V2Validation.uuid(id); try V2Validation.uuid(binding.bootID); try V2Validation.uuid(binding.backendEpoch)
        let keys: Set<String>
        switch action {
        case "call.dial": keys = ["number"]
        case "call.answer", "call.hangup": keys = ["call_id"]
        case "call.dtmf": keys = ["call_id", "tones"]
        case "sms.send": keys = ["number", "text"]
        default: throw V2Error.invalidValue
        }
        guard Set(args.keys) == keys else { throw V2Error.invalidValue }
        if let number = args["number"], !V2Validation.matches(number, "^\\+?[0-9]{7,15}$") { throw V2Error.invalidValue }
        if let call = args["call_id"] { try V2Validation.uuid(call) }
        if let tones = args["tones"], !V2Validation.matches(tones, "^[0-9A-D*#]{1,16}$") { throw V2Error.invalidValue }
        if let text = args["text"], text.utf16.isEmpty || text.utf16.count > 70 || text.contains("\0") { throw V2Error.invalidValue }
        command_id = id; agent_boot_id = binding.bootID; backend_epoch = binding.backendEpoch
        deadline = V2Validation.timestamp(now.addingTimeInterval(45)); self.action = action; self.args = args
    }
}
struct V2CommandEnvelope: Encodable { let connection_epoch: String; let command: V2Command }

struct V2PendingCommand: Codable, Equatable {
    let binding: V2ControlBinding
    let commandID: String
    let action: String
    var generation: String?
    var callID: String?
    // Deliberately no args, number, SMS body, token or raw receipt.
    func validate() throws {
        try V2Validation.uuid(commandID); try V2Validation.uuid(binding.moduleID); try V2Validation.uuid(binding.bootID)
        try V2Validation.uuid(binding.backendEpoch); try V2Validation.uuid(binding.connectionEpoch)
        try V2Validation.uuid(binding.identity.serverID); try V2Validation.uuid(binding.identity.clientInstallationID)
        guard try V2Validation.origin(binding.identity.apiOrigin) == binding.identity.apiOrigin,
              ["call.dial", "call.answer", "call.hangup", "call.dtmf", "sms.send"].contains(action) else { throw V2Error.persistence }
        if let generation { try V2Validation.uuid(generation) }; if let callID { try V2Validation.uuid(callID) }
    }
}
protocol V2PendingStore {
    func load() throws -> V2PendingCommand?
    func save(_ pending: V2PendingCommand) throws
    func clear() throws
}
struct V2FilePendingStore: V2PendingStore {
    let url: URL
    func load() throws -> V2PendingCommand? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
            let pending = try V2JSON.decode(V2PendingCommand.self, from: data, limit: 16 * 1024)
            try pending.validate(); return pending
        } catch { throw V2Error.persistence }
    }
    func save(_ pending: V2PendingCommand) throws {
        do {
            try pending.validate()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(pending).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { throw V2Error.persistence }
    }
    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch { throw V2Error.persistence }
    }
}
enum V2CommandPhase: Equatable {
    case idle, submitting, waiting, unknown
    case rejected(Int)
    case receipt(serverState: String, receiptState: String)
}

@MainActor
final class V2CommandMachine {
    private let client: V2Client
    private let store: V2PendingStore
    private(set) var pending: V2PendingCommand?
    private(set) var phase: V2CommandPhase = .idle
    private var requestInFlight = false
    private(set) var ownedCall: V2CallContext?
    var blocksConfigurationChange: Bool { pending != nil }
    init(client: V2Client, store: V2PendingStore) throws {
        self.client = client; self.store = store
        pending = try store.load()
        if let pending { try pending.validate(); phase = .unknown }
    }
    func submit(_ command: V2Command, binding: V2ControlBinding) async throws {
        guard pending == nil, !requestInFlight, let stamp = client.stamp, stamp.identity == binding.identity else { throw V2Error.busy }
        let metadata = V2PendingCommand(binding: binding, commandID: command.command_id, action: command.action, generation: nil, callID: command.args["call_id"])
        // Save first. Failure must prevent any POST.
        try store.save(metadata); pending = metadata; phase = .submitting; requestInFlight = true
        defer { requestInFlight = false }
        do {
            let record = try await client.submit(command, binding: binding)
            guard client.gate.accepts(stamp) else { phase = .unknown; return }
            try accept(record)
        } catch let failure as V2HTTPFailure where (400..<500).contains(failure.status) {
            phase = .rejected(failure.status)
        } catch {
            phase = .unknown // Never retry a POST, including cancellation or decoding failure.
        }
    }
    func recover() async throws {
        guard let pending, !requestInFlight, let stamp = client.stamp, stamp.identity == pending.binding.identity else { throw V2Error.busy }
        requestInFlight = true; defer { requestInFlight = false }
        do {
            let record = try await client.receipt(binding: pending.binding, commandID: pending.commandID)
            guard client.gate.accepts(stamp) else { phase = .unknown; return }
            try accept(record)
        } catch { phase = .unknown }
    }
    private func accept(_ record: V2CommandRecord) throws {
        guard var pending, record.command_id == pending.commandID,
              pending.generation == nil || pending.generation == record.generation,
              record.receipt == nil || record.receipt?.action == pending.action else { throw V2Error.invalidIdentity }
        pending.generation = record.generation
        if let callID = record.receipt?.call_id {
            guard pending.callID == nil || pending.callID == callID else { throw V2Error.invalidIdentity }
            pending.callID = callID
        }
        try store.save(pending); self.pending = pending
        guard let receipt = record.receipt else { phase = record.state == "outcome_unknown" ? .unknown : .waiting; return }
        if ["call.dial", "call.answer"].contains(pending.action), ["accepted", "observed"].contains(receipt.state), let callID = pending.callID {
            guard callID == receipt.call_id else { throw V2Error.invalidIdentity }
            ownedCall = try client.recordOwnership(record, pending: pending)
        }
        if receipt.state == "outcome_unknown" || record.state == "outcome_unknown" { phase = .unknown }
        else if ["prepared", "dispatched"].contains(receipt.state) { phase = .waiting }
        else { phase = .receipt(serverState: record.state, receiptState: receipt.state) }
    }
    func acknowledgeResolved() throws {
        switch phase {
        case .rejected, .receipt: try store.clear(); pending = nil; phase = .idle
        default: throw V2Error.busy
        }
    }
    func invalidateOwnedCall() { ownedCall = nil }
}


extension V2CallContext {
    func command(action: String, tones: String? = nil, now: Date) throws -> V2Command {
        guard action == "call.hangup" || action == "call.dtmf" else { throw V2Error.invalidValue }
        var args = ["call_id": callID]
        if let tones { args["tones"] = tones }
        return try V2Command(binding: binding, action: action, args: args, now: now)
    }
}
