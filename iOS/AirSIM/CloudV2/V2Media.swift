import Foundation

struct V2ASMPFrame: Equatable {
    let sessionID: String
    let direction: UInt8
    let sequence: UInt64
    let pcm: Data
    func encode() throws -> Data {
        try V2Validation.uuid(sessionID)
        guard [1,2].contains(direction), sequence > 0, pcm.count == 320, let uuid = UUID(uuidString: sessionID) else { throw V2Error.protocolViolation }
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes.replaceSubrange(0..<4, with: [65,83,77,80]); bytes[4] = 1; bytes[5] = direction; bytes[6] = 40
        var raw = uuid.uuid
        withUnsafeBytes(of: &raw) { bytes.replaceSubrange(8..<24, with: $0) }
        for i in 0..<8 { bytes[24+i] = UInt8(truncatingIfNeeded: sequence >> (i * 8)) }
        bytes[32] = 64; bytes[33] = 1
        return Data(bytes) + pcm
    }
    static func decode(_ data: Data, sessionID: String, direction: UInt8, after last: UInt64) throws -> (frame: Self, gaps: UInt64) {
        try V2Validation.uuid(sessionID)
        guard data.count == 360, [1,2].contains(direction), let uuid = UUID(uuidString: sessionID) else { throw V2Error.protocolViolation }
        let b = Array(data); var raw = uuid.uuid
        let expected = withUnsafeBytes(of: &raw) { Array($0) }
        guard Array(b[0..<4]) == [65,83,77,80], b[4] == 1, b[5] == direction, b[6] == 40, b[7] == 0,
              Array(b[8..<24]) == expected, Array(b[32..<40]) == [64,1,0,0,0,0,0,0] else { throw V2Error.protocolViolation }
        var sequence: UInt64 = 0
        for i in 0..<8 { sequence |= UInt64(b[24+i]) << (8*i) }
        guard sequence > last else { throw V2Error.protocolViolation }
        return (Self(sessionID: sessionID, direction: direction, sequence: sequence, pcm: Data(b[40..<360])), sequence - last - 1)
    }
}

struct V2MediaHandshake: Encodable { let session_id: String; let role = "client"; let ticket: String }
enum V2MediaServerMessage {
    case waiting, paired
    private struct Message: Decodable {
        let type: String; let session: String; let format: V2MediaFormat?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: V2Key.self)
            type = try c.get("type")
            let fields = try decoder.v2Fields(type == "paired" ? "type session_id format" : "type session_id")
            session = try fields.get("session_id")
            format = type == "paired" ? try fields.get("format") : nil
        }
    }
    static func parse(_ data: Data, sessionID: String) throws -> Self {
        let message = try V2JSON.decode(Message.self, from: data, limit: 2048)
        guard message.session == sessionID else { throw V2Error.invalidIdentity }
        switch message.type { case "waiting": return .waiting; case "paired": return .paired; default: throw V2Error.protocolViolation }
    }
}

// Pure monotonic-time queue. One instance per direction and media generation.
// Nanosecond integers preserve the initial grid despite recurring late wakeups.
struct V2PCMQueue {
    struct Entry { let pcm: Data; let time: UInt64 }
    enum EmptyPolicy { case skip, silence }
    let generation: UUID
    let emptyPolicy: EmptyPolicy
    private(set) var queueDrops: UInt64 = 0
    private(set) var zeroFrames: UInt64 = 0
    private(set) var skippedSlots: UInt64 = 0
    private(set) var nextDeadline: UInt64?
    private var entries: [Entry] = []
    private var lastOutput: UInt64?
    private var lastArrival: UInt64?
    var count: Int { entries.count }
    init(generation: UUID, emptyPolicy: EmptyPolicy) { self.generation = generation; self.emptyPolicy = emptyPolicy }
    mutating func enqueue(_ pcm: Data, at now: UInt64, generation: UUID) throws {
        guard generation == self.generation else { return }
        guard pcm.count == 320, now <= UInt64.max - 40_000_000,
              lastArrival == nil || now >= lastArrival! else { throw V2Error.invalidValue }
        lastArrival = now
        if nextDeadline == nil { nextDeadline = now + 40_000_000 }
        if entries.count == 5 { entries.removeFirst(); queueDrops += 1 }
        entries.append(Entry(pcm: pcm, time: now))
    }
    mutating func output(at now: UInt64, generation: UUID) -> Data? {
        guard generation == self.generation, let deadline = nextDeadline, now >= deadline else { return nil }
        let period: UInt64 = 20_000_000
        if now - deadline >= period {
            let skip = (now - deadline) / period + 1
            guard deadline <= UInt64.max - skip * period else { return nil }
            nextDeadline = deadline + skip * period; skippedSlots += skip
            discardExpired(at: now); return nil
        }
        guard deadline <= UInt64.max - period else { return nil }
        nextDeadline = deadline + period
        if let lastOutput, now < lastOutput || now - lastOutput < 10_000_000 { skippedSlots += 1; return nil }
        discardExpired(at: now)
        let result: Data?
        if !entries.isEmpty { result = entries.removeFirst().pcm }
        else if emptyPolicy == .silence { result = Data(repeating: 0, count: 320); zeroFrames += 1 }
        else { result = nil }
        if result != nil { lastOutput = now }
        return result
    }
    // Called after an asynchronous write/render scheduling operation completes.
    mutating func completed(at now: UInt64, generation: UUID) {
        guard generation == self.generation, let deadline = nextDeadline, now >= deadline else { return }
        let skip = (now - deadline) / 20_000_000 + 1
        guard deadline <= UInt64.max - skip * 20_000_000 else { return }
        nextDeadline = deadline + skip * 20_000_000; skippedSlots += skip
    }
    private mutating func discardExpired(at now: UInt64) {
        while let first = entries.first, now >= first.time, now - first.time > 100_000_000 { entries.removeFirst(); queueDrops += 1 }
    }
}
