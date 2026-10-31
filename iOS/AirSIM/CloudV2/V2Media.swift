import Foundation

struct V2ASMPFrame: Equatable {
    let sessionID: String
    let direction: UInt8
    let sequence: UInt64
    let payload: Data
    var erasure = false
    func encode() throws -> Data {
        try V2Validation.uuid(sessionID)
        guard [1,2].contains(direction), sequence > 0, payload.count == 80, !erasure || payload.allSatisfy({ $0 == 0 }), let uuid = UUID(uuidString: sessionID) else { throw V2Error.protocolViolation }
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes.replaceSubrange(0..<4, with: [65,83,77,80]); bytes[4] = 2; bytes[5] = direction; bytes[6] = 40
        var raw = uuid.uuid
        withUnsafeBytes(of: &raw) { bytes.replaceSubrange(8..<24, with: $0) }
        for i in 0..<8 { bytes[24+i] = UInt8(truncatingIfNeeded: sequence >> (i * 8)) }
        bytes[32] = 80; bytes[36] = erasure ? 1 : 0
        return Data(bytes) + payload
    }
    static func decode(_ data: Data, sessionID: String, direction: UInt8, after last: UInt64) throws -> (frame: Self, gaps: UInt64) {
        try V2Validation.uuid(sessionID)
        guard data.count == 120, [1,2].contains(direction), let uuid = UUID(uuidString: sessionID) else { throw V2Error.protocolViolation }
        let b = Array(data); var raw = uuid.uuid
        let expected = withUnsafeBytes(of: &raw) { Array($0) }
        guard Array(b[0..<4]) == [65,83,77,80], b[4] == 2, b[5] == direction, b[6] == 40, b[7] == 0,
              Array(b[8..<24]) == expected, Array(b[32..<36]) == [80,0,0,0], b[36] <= 1, Array(b[37..<40]) == [0,0,0],
              b[36] == 0 || b[40..<120].allSatisfy({ $0 == 0 }) else { throw V2Error.protocolViolation }
        var sequence: UInt64 = 0
        for i in 0..<8 { sequence |= UInt64(b[24+i]) << (8*i) }
        guard sequence > last else { throw V2Error.protocolViolation }
        return (Self(sessionID: sessionID, direction: direction, sequence: sequence, payload: Data(b[40..<120]), erasure: b[36] == 1), sequence - last - 1)
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
struct V2MediaQueue {
    struct Packet { let payload: Data; var erasure = false; var sequence: UInt64 = 0 }
    struct Entry { let packet: Packet; let time: UInt64 }
    enum EmptyPolicy { case skip, erasure }
    let generation: UUID
    let emptyPolicy: EmptyPolicy
    let payloadSize: Int
    let startDelay: UInt64
    let capacity: Int
    let maxAge: UInt64
    /// Late ticks drain the backlog one packet per tick instead of skipping
    /// slots; the player or the remote jitter buffer absorbs the short burst.
    let catchUp: Bool
    private(set) var queueDrops: UInt64 = 0
    private(set) var erasureFrames: UInt64 = 0
    private(set) var skippedSlots: UInt64 = 0
    private(set) var nextDeadline: UInt64?
    private var entries: [Entry] = []
    private var lastOutput: UInt64?
    private var lastArrival: UInt64?
    var count: Int { entries.count }
    init(generation: UUID, emptyPolicy: EmptyPolicy, payloadSize: Int = V2PCM.frameBytes,
         startDelay: UInt64 = 40_000_000, capacity: Int = 5, maxAge: UInt64 = 100_000_000, catchUp: Bool = false) {
        self.generation = generation; self.emptyPolicy = emptyPolicy; self.payloadSize = payloadSize
        self.startDelay = startDelay; self.capacity = capacity; self.maxAge = maxAge; self.catchUp = catchUp
    }
    /// Downlink jitter buffer sized for a module on a cellular uplink.
    static func downlink(generation: UUID) -> V2MediaQueue {
        V2MediaQueue(generation: generation, emptyPolicy: .erasure, payloadSize: 80,
                     startDelay: 100_000_000, capacity: 12, maxAge: 240_000_000, catchUp: true)
    }
    /// Microphone taps deliver up to ~100 ms per callback; the queue paces them out.
    static func uplink(generation: UUID) -> V2MediaQueue {
        V2MediaQueue(generation: generation, emptyPolicy: .skip, capacity: 12, maxAge: 240_000_000, catchUp: true)
    }
    mutating func enqueue(_ payload: Data, erasure: Bool = false, sequence: UInt64 = 0, at now: UInt64, generation: UUID) throws {
        guard generation == self.generation else { return }
        guard payload.count == payloadSize, !erasure || payload.allSatisfy({ $0 == 0 }), now <= UInt64.max - startDelay,
              lastArrival == nil || now >= lastArrival! else { throw V2Error.invalidValue }
        lastArrival = now
        if nextDeadline == nil { nextDeadline = now + startDelay }
        if entries.count == capacity { entries.removeFirst(); queueDrops += 1 }
        entries.append(Entry(packet: Packet(payload: payload, erasure: erasure, sequence: sequence), time: now))
    }
    mutating func output(at now: UInt64, generation: UUID) -> Packet? {
        guard generation == self.generation, let deadline = nextDeadline, now >= deadline else { return nil }
        let period: UInt64 = 20_000_000
        if now - deadline >= (catchUp ? maxAge : period) {
            let skip = (now - deadline) / period + 1
            guard deadline <= UInt64.max - skip * period else { return nil }
            nextDeadline = deadline + skip * period; skippedSlots += skip
            discardExpired(at: now); return nil
        }
        guard deadline <= UInt64.max - period else { return nil }
        nextDeadline = deadline + period
        if !catchUp, let lastOutput, now < lastOutput || now - lastOutput < 10_000_000 { skippedSlots += 1; return nil }
        discardExpired(at: now)
        let result: Packet?
        if !entries.isEmpty { result = entries.removeFirst().packet }
        else if emptyPolicy != .skip {
            result = Packet(payload: Data(repeating: 0, count: payloadSize), erasure: emptyPolicy == .erasure); erasureFrames += 1
        }
        else { result = nil }
        if result != nil { lastOutput = now }
        return result
    }
    // Called after an asynchronous write/render scheduling operation completes.
    mutating func completed(at now: UInt64, generation: UUID) {
        guard !catchUp, generation == self.generation, let deadline = nextDeadline, now >= deadline else { return }
        let skip = (now - deadline) / 20_000_000 + 1
        guard deadline <= UInt64.max - skip * 20_000_000 else { return }
        nextDeadline = deadline + skip * 20_000_000; skippedSlots += skip
    }
    private mutating func discardExpired(at now: UInt64) {
        while let first = entries.first, now >= first.time, now - first.time > maxAge { entries.removeFirst(); queueDrops += 1 }
    }
}
