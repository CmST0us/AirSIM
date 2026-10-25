import Foundation
import Combine

struct V2MediaStatistics {
    var received: UInt64 = 0, sent: UInt64 = 0, sequenceGaps: UInt64 = 0
    var queueDrops: UInt64 = 0, skippedSlots: UInt64 = 0, playbackZero: UInt64 = 0
    var rendered: UInt64 = 0, captureFrames: UInt64 = 0, writeTimeouts: UInt64 = 0
    var diagnosticZero: UInt64 = 0
#if DEBUG
    var pairedElapsedMilliseconds: UInt64 = 0
    var tickIntervalsAtLeast20ms: UInt64 = 0, maxTickIntervalMilliseconds: UInt64 = 0
    var validationCount: UInt64 = 0, validationTotalNanoseconds: UInt64 = 0, validationMaxMicroseconds: UInt64 = 0
    var maxSuccessfulWriteMilliseconds: UInt64 = 0
    var upQueueDrops: UInt64 = 0, downQueueDrops: UInt64 = 0
    var upSkippedSlots: UInt64 = 0, downSkippedSlots: UInt64 = 0
    var captureOutputDrops: UInt64 = 0, playbackDrops: UInt64 = 0
    var sentPCMEnergy = V2PCMEnergySummary()
    var receivedPCMEnergy = V2PCMEnergySummary()
    var diagnosticReceivedEnergy = V2PCMEnergySummary()
    var diagnosticEchoEnergy = V2PCMEnergySummary()
#endif
}
enum V2MediaState: Equatable {
    case idle, preparing, authenticating, waiting, paired, failed(String), stopping
    var title: String {
        switch self {
        case .idle: return "音频未连接"
        case .preparing: return "正在准备音频"
        case .authenticating: return "正在连接音频"
        case .waiting: return "等待模块音频"
        case .paired: return "音频已连接"
        case .failed(let message): return message
        case .stopping: return "正在停止音频"
        }
    }
}

enum V2MediaFailureStage: String {
    case preparing, creatingSession, openingSocket, sendingAuthentication, waiting, pairing
    case receiving, sending, ticking, audio, speaker
}
enum V2MediaFailureCode: String {
    case timeout, handshake, stale, inactive, inputStopped, downlinkStopped, disconnected
    case audioPermission, audioFormat, audioConversion, audioVoiceProcessing, audioEngine
    case audioInterrupted, audioFormatChanged, audioSpeech
    case urlSession, unknown
}
struct V2MediaFailureDiagnostic: Equatable {
    let code: V2MediaFailureCode
    let stage: V2MediaFailureStage
    let numericCode: Int?
    let downlinkAgeMilliseconds: UInt64?
    // Fixed domain only; never retain NSError/userInfo or arbitrary descriptions.
    var domain: String? { code == .urlSession ? NSURLErrorDomain : nil }
    init(error: Error, stage: V2MediaFailureStage, downlinkAgeMilliseconds: UInt64?) {
        self.stage = stage; self.downlinkAgeMilliseconds = downlinkAgeMilliseconds
        var number: Int?
        if let failure = error as? V2MediaFailure {
            switch failure {
            case .timeout: code = .timeout
            case .handshake: code = .handshake
            case .stale: code = .stale
            case .inactive: code = .inactive
            case .inputStopped: code = .inputStopped
            case .downlinkStopped: code = .downlinkStopped
            case .disconnected: code = .disconnected
            }
        } else if let audio = error as? V2AudioError {
            switch audio {
            case .permission: code = .audioPermission
            case .format: code = .audioFormat
            case .conversion: code = .audioConversion
            case .voiceProcessing(let value): code = .audioVoiceProcessing; number = value
            case .engine(let value): code = .audioEngine; number = value
            case .interrupted: code = .audioInterrupted
            case .formatChanged: code = .audioFormatChanged
            case .speech: code = .audioSpeech
            }
        } else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { code = .urlSession; number = nsError.code }
            else { code = .unknown }
        }
        numericCode = number
    }
}

@MainActor
final class V2MediaCoordinator: ObservableObject {
    @Published private(set) var state = V2MediaState.idle
    @Published private(set) var lastFailure: V2MediaFailureDiagnostic?
    @Published private(set) var statistics = V2MediaStatistics()
    @Published private(set) var audioMetrics = V2AudioMetrics()
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    private let audio: V2AudioIO
    private let socketFactory: @MainActor () -> V2MediaSocket
    private let clock: V2MediaClock
    private let create: (V2CallContext, String) async throws -> V2MediaCreated
    private let delete: (V2CallContext, String) async -> Void
    private let wallNow: () -> Date
    private(set) var context: V2CallContext?
    private var stopTask: Task<Void, Never>?
    private var socket: V2MediaSocket?
    private var generation = UUID()
    private var sessionID: String?
    private var startTask: Task<Void, Never>?, receiveTask: Task<Void, Never>?, tickTask: Task<Void, Never>?, sendTask: Task<Void, Never>?
    private var up: V2PCMQueue?, down: V2PCMQueue?
    private var sendSequence: UInt64 = 0, receiveSequence: UInt64 = 0
    private var lastCapture: UInt64 = 0, lastDownlink: UInt64 = 0, pairedAt: UInt64 = 0
    private var lastDownlinkFrame: UInt64?
    private var counters = V2MediaStatistics()
    private var statisticsFrozen = true
#if DEBUG
    private var diagnosticPairedAt: UInt64?
    private var previousTickAt: UInt64?
#endif
    private var diagnostic: V2DiagnosticAudio?
    var onDiagnosticTimeout: ((V2CallContext) -> Void)?
    var active: Bool { context != nil || startTask != nil || stopTask != nil || state == .stopping }
    init(audio: V2AudioIO? = nil, socketFactory: @escaping @MainActor () -> V2MediaSocket = { V2URLMediaSocket() }, clock: V2MediaClock? = nil, now: @escaping () -> Date = Date.init, create: @escaping (V2CallContext, String) async throws -> V2MediaCreated, delete: @escaping (V2CallContext, String) async -> Void) {
        self.audio = audio ?? V2AudioEngine(); self.socketFactory = socketFactory; self.clock = clock ?? V2SystemMediaClock(); wallNow = now
        self.create = create; self.delete = delete
    }
    func start(context: V2CallContext, diagnosticMode: Bool, validate: @escaping () -> Bool) {
        guard !active else { return }
        let stamp = UUID(); generation = stamp; self.context = context
        lastFailure = nil; lastDownlinkFrame = nil
        statisticsFrozen = false
#if DEBUG
        diagnosticPairedAt = nil; previousTickAt = nil
#endif
        state = .preparing; counters = V2MediaStatistics(); statistics = counters
        muted = false; speaker = false
        audio.onFailure = { [weak self] error in self?.fail(error, stamp: stamp, stage: .audio) }
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == stamp { self.startTask = nil } }
            var stage = V2MediaFailureStage.preparing
            do {
                var diagnostic: V2DiagnosticAudio?
#if DEBUG && targetEnvironment(simulator)
                if diagnosticMode { let value = V2DiagnosticAudio(); self.diagnostic = value; try await value.prepare(); diagnostic = value }
#else
                guard !diagnosticMode else { throw V2MediaFailure.inactive }
#endif
                try await self.audio.prepare(microphone: diagnostic == nil)
                guard self.generation == stamp, !Task.isCancelled, validate() else { throw V2MediaFailure.stale }
                stage = .creatingSession
                let created = try await self.create(context, UUID().uuidString.lowercased())
                guard self.generation == stamp, !Task.isCancelled else {
                    Task { await self.delete(context, created.session_id) }; return
                }
                self.sessionID = created.session_id
                guard validate(), let url = URL(string: created.media_url), url.scheme == "wss" else { throw V2MediaFailure.stale }
                let remaining = try V2Validation.date(created.expires_at).timeIntervalSince(self.wallNow())
                guard remaining > 0 else { throw V2Error.expired }
                let ticketDeadline = self.clock.now + UInt64(remaining * 1_000_000_000)
                let socket = self.socketFactory(); self.socket = socket; self.state = .authenticating
                stage = .openingSocket
                let selected = try await V2MediaDeadline<String?>().run(clock: self.clock, until: min(ticketDeadline, self.clock.now + 3_000_000_000), cancel: { socket.cancel() }) { try await socket.open(url) }
                guard selected == "airsim.media.v2" else { throw V2MediaFailure.handshake }
                guard self.generation == stamp, !Task.isCancelled, validate() else { throw V2MediaFailure.stale }
                let auth = try JSONEncoder().encode(V2MediaHandshake(session_id: created.session_id, ticket: created.ticket))
                stage = .sendingAuthentication
                try await self.write(.string(String(decoding: auth, as: UTF8.self)), socket: socket)
                let pairingDeadline = min(ticketDeadline, self.clock.now + 5_000_000_000)
                stage = .waiting
                let first = try await self.handshake(socket, deadline: min(pairingDeadline, self.clock.now + 3_000_000_000), id: created.session_id)
                guard case .waiting = first else { throw V2MediaFailure.handshake }
                self.state = .waiting
                stage = .pairing
                let second = try await self.handshake(socket, deadline: pairingDeadline, id: created.session_id)
                guard case .paired = second, self.generation == stamp, !Task.isCancelled, validate() else { throw V2MediaFailure.handshake }
                socket.limit(360)
                self.state = .paired; self.pairedAt = self.clock.now
#if DEBUG
                self.diagnosticPairedAt = self.pairedAt
#endif
                self.lastCapture = self.pairedAt; self.lastDownlink = self.pairedAt
                self.sendSequence = 0; self.receiveSequence = 0
                self.up = V2PCMQueue(generation: stamp, emptyPolicy: .skip)
                self.down = V2PCMQueue(generation: stamp, emptyPolicy: .silence)
                diagnostic?.start(at: self.pairedAt)
                self.beginReceive(socket, id: created.session_id, stamp: stamp)
                self.beginTicks(socket, id: created.session_id, stamp: stamp, validate: validate)
            } catch { self.fail(error, stamp: stamp, stage: stage) }
        }
    }
    private func handshake(_ socket: V2MediaSocket, deadline: UInt64, id: String) async throws -> V2MediaServerMessage {
        let message = try await V2MediaDeadline<URLSessionWebSocketTask.Message>().run(clock: clock, until: deadline, cancel: { socket.cancel() }) { try await socket.receive() }
        guard case .string(let text) = message, text.utf8.count <= 2048 else { throw V2MediaFailure.handshake }
        return try V2MediaServerMessage.parse(Data(text.utf8), sessionID: id)
    }
    private func write(_ message: URLSessionWebSocketTask.Message, socket: V2MediaSocket) async throws {
        try await V2MediaDeadline<Void>().run(clock: clock, until: clock.now + 100_000_000, cancel: { socket.cancel() }) { try await socket.send(message) }
    }
    private func beginReceive(_ socket: V2MediaSocket, id: String, stamp: UUID) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.generation == stamp, !Task.isCancelled {
                    let message = try await socket.receive()
                    guard self.generation == stamp, !Task.isCancelled else { return }
                    guard case .data(let data) = message else { throw V2MediaFailure.handshake }
                    let result = try V2ASMPFrame.decode(data, sessionID: id, direction: 2, after: self.receiveSequence)
#if DEBUG
                    self.counters.receivedPCMEnergy.record(result.frame.pcm)
#endif
                    self.receiveSequence = result.frame.sequence
                    self.counters.received += 1; self.counters.sequenceGaps += result.gaps
                    self.lastDownlink = self.clock.now; self.lastDownlinkFrame = self.lastDownlink
                    try self.down?.enqueue(result.frame.pcm, at: self.clock.now, generation: stamp)
                    self.diagnostic?.receive(result.frame.pcm, at: self.clock.now)
                }
            } catch { self.fail(error, stamp: stamp, stage: .receiving) }
        }
    }
    private func beginTicks(_ socket: V2MediaSocket, id: String, stamp: UUID, validate: @escaping () -> Bool) {
        tickTask = Task { [weak self] in
            guard let self else { return }
            var next = self.clock.now, nextPublish = next
            while self.generation == stamp, !Task.isCancelled, self.state == .paired {
#if DEBUG
                let validationStart = self.clock.now
                if let previous = self.previousTickAt {
                    let interval = validationStart >= previous ? validationStart - previous : 0
                    if interval >= 20_000_000 { self.counters.tickIntervalsAtLeast20ms += 1 }
                    self.counters.maxTickIntervalMilliseconds = max(self.counters.maxTickIntervalMilliseconds, interval / 1_000_000)
                }
                self.previousTickAt = validationStart
                let valid = validate()
                let validationEnd = self.clock.now
                let duration = validationEnd >= validationStart ? validationEnd - validationStart : 0
                self.counters.validationCount += 1
                self.counters.validationTotalNanoseconds += duration
                self.counters.validationMaxMicroseconds = max(self.counters.validationMaxMicroseconds, duration / 1_000)
#else
                let valid = validate()
#endif
                guard valid else { self.fail(V2MediaFailure.stale, stamp: stamp, stage: .ticking); return }
                let now = self.clock.now
                let frames = self.audio.takeCaptured()
                guard self.generation == stamp, self.state == .paired else { return }
                if !frames.isEmpty { self.lastCapture = now }
                do {
                    for frame in frames { try self.up?.enqueue(frame, at: now, generation: stamp) }
                    if let diagnostic = self.diagnostic {
                        if let pcm = diagnostic.output(at: now) { try self.up?.enqueue(pcm, at: now, generation: stamp) }
                        self.lastCapture = now // Explicit injection, never represented as a real microphone.
                        self.counters.diagnosticZero = diagnostic.zeroFrames
                        if now - self.pairedAt >= 75_000_000_000, let context = self.context {
                            self.fail(V2MediaFailure.inactive, stamp: stamp, stage: .ticking); self.onDiagnosticTimeout?(context); return
                        }
                    }
                    guard now - self.lastCapture < 2_000_000_000 else { throw V2MediaFailure.inputStopped }
                    guard now - self.lastDownlink < 2_000_000_000 else { throw V2MediaFailure.downlinkStopped }
                    if self.sendTask == nil, let pcm = self.up?.output(at: now, generation: stamp) {
                        self.sendSequence += 1
                        let binary = try V2ASMPFrame(sessionID: id, direction: 1, sequence: self.sendSequence, pcm: pcm).encode()
                        self.sendTask = Task { [weak self] in
                            guard let self else { return }
                            defer { if self.generation == stamp { self.sendTask = nil } }
                            guard self.generation == stamp, self.state == .paired, !Task.isCancelled else { return }
                            do {
#if DEBUG
                                let writeStart = self.clock.now
#endif
                                try await self.write(.data(binary), socket: socket)
                                guard self.generation == stamp else { return }
#if DEBUG
                                let writeEnd = self.clock.now
                                let duration = writeEnd >= writeStart ? writeEnd - writeStart : 0
                                self.counters.maxSuccessfulWriteMilliseconds = max(self.counters.maxSuccessfulWriteMilliseconds, duration / 1_000_000)
                                self.counters.sentPCMEnergy.record(pcm)
#endif
                                self.counters.sent += 1; self.up?.completed(at: self.clock.now, generation: stamp)
                            } catch {
                                if case V2MediaFailure.timeout = error { self.counters.writeTimeouts += 1 }
                                self.fail(error, stamp: stamp, stage: .sending)
                            }
                        }
                    }
                    if let pcm = self.down?.output(at: now, generation: stamp) {
                        _ = self.audio.play(pcm); self.down?.completed(at: self.clock.now, generation: stamp)
                    }
                } catch { self.fail(error, stamp: stamp, stage: .ticking); return }
                if now >= nextPublish {
                    self.publish(); nextPublish = now + 1_000_000_000
                }
                next += 5_000_000
                if next <= now { next += ((now - next) / 5_000_000 + 1) * 5_000_000 }
                do { try await self.clock.sleep(until: next) } catch { return }
            }
        }
    }
    private func publish() {
        guard !statisticsFrozen else { return }
        audioMetrics = audio.metrics
        counters.captureFrames = audio.metrics.captured; counters.rendered = audio.metrics.rendered
        counters.queueDrops = (up?.queueDrops ?? 0) + (down?.queueDrops ?? 0) + audio.metrics.outputDrops + audio.metrics.playbackDrops + (diagnostic?.echoDrops ?? 0)
        counters.skippedSlots = (up?.skippedSlots ?? 0) + (down?.skippedSlots ?? 0)
        counters.playbackZero = down?.zeroFrames ?? 0
#if DEBUG
        if let paired = diagnosticPairedAt {
            let now = clock.now
            counters.pairedElapsedMilliseconds = (now >= paired ? now - paired : 0) / 1_000_000
        }
        counters.upQueueDrops = up?.queueDrops ?? 0; counters.downQueueDrops = down?.queueDrops ?? 0
        counters.upSkippedSlots = up?.skippedSlots ?? 0; counters.downSkippedSlots = down?.skippedSlots ?? 0
        counters.captureOutputDrops = audio.metrics.outputDrops; counters.playbackDrops = audio.metrics.playbackDrops
        if let diagnostic {
            counters.diagnosticReceivedEnergy = diagnostic.receivedEnergy
            counters.diagnosticEchoEnergy = diagnostic.echoEnergy
        }
#endif
        statistics = counters
    }
    private func fail(_ error: Error, stamp: UUID, stage: V2MediaFailureStage) {
        guard generation == stamp, state != .stopping else { return }
        if case .failed = state { return }
        let now = clock.now
        let age = lastDownlinkFrame.map { (now >= $0 ? now - $0 : 0) / 1_000_000 }
        lastFailure = V2MediaFailureDiagnostic(error: error, stage: stage, downlinkAgeMilliseconds: age)
        let message: String
        if let audio = error as? V2AudioError { message = audio.message }
        else if error is V2MediaFailure { message = "音频连接中断，请手动恢复音频" }
        else { message = "音频不可用，请核对连接后恢复音频" }
        state = .failed(message)
        Task { [weak self] in
            guard let self, self.generation == stamp else { return }
            await self.stop(keepFailure: true)
        }
    }
    func requestStop() {
        guard state != .stopping else { return }
        let stamp = generation
        state = .stopping
        Task { [weak self] in
            guard let self, self.generation == stamp else { return }
            await self.stop()
        }
    }
    func stop(keepFailure: Bool = false) async {
        if let stopTask { await stopTask.value; return }
        let failed = state
        generation = UUID(); state = .stopping
        let tasks = [startTask, receiveTask, tickTask, sendTask].compactMap { $0 }
        startTask = nil; receiveTask = nil; tickTask = nil; sendTask = nil
        tasks.forEach { $0.cancel() }; socket?.cancel(); socket = nil
        publish()
        statisticsFrozen = true
        diagnostic?.stop(); diagnostic = nil
        if let context, let sessionID { Task { await delete(context, sessionID) } }
        context = nil; sessionID = nil
        audio.onFailure = nil
        let task = Task { [self] in
            await audio.stop()
            for task in tasks { await task.value }
            up = nil; down = nil; audioMetrics = audio.metrics
            state = keepFailure ? failed : .idle
            stopTask = nil
        }
        stopTask = task
        await task.value
    }
    func setMuted(_ value: Bool) { muted = value; audio.setMuted(value) }
    func setSpeaker(_ value: Bool) {
        do { try audio.setSpeaker(value); speaker = value } catch { fail(error, stamp: generation, stage: .speaker) }
    }
#if DEBUG && targetEnvironment(simulator)
    func disconnectForDiagnostics() { socket?.cancel() }
#endif
}
