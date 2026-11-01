import AVFoundation
import Foundation
import Combine

struct V2MediaStatistics: Equatable {
    var peer = V2PeerStatistics()
    var connectedMilliseconds: UInt64 = 0
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

enum V2MediaFailure: Error { case timeout, stale, disconnected, downlinkStopped }
enum V2MediaFailureStage: String {
    case preparing, creatingSession, gathering, signaling, connecting, streaming, speaker
}
enum V2MediaFailureCode: String {
    case timeout, stale, disconnected, downlinkStopped, offer, gathering, answer, audioSession
    case http, urlSession, posix, cocoa, unknown
}
struct V2MediaFailureDiagnostic: Equatable {
    let code: V2MediaFailureCode
    let stage: V2MediaFailureStage
    let numericCode: Int?
    // Fixed domain only; never retain NSError/userInfo or arbitrary descriptions.
    var domain: String? {
        switch code {
        case .urlSession: return NSURLErrorDomain
        case .posix: return NSPOSIXErrorDomain
        case .cocoa: return NSCocoaErrorDomain
        default: return nil
        }
    }
    init(error: Error, stage: V2MediaFailureStage) {
        self.stage = stage
        var number: Int?
        if let failure = error as? V2MediaFailure {
            switch failure {
            case .timeout: code = .timeout
            case .stale: code = .stale
            case .disconnected: code = .disconnected
            case .downlinkStopped: code = .downlinkStopped
            }
        } else if let peer = error as? V2PeerError {
            switch peer {
            case .offer: code = .offer
            case .gathering: code = .gathering
            case .answer: code = .answer
            }
        } else if let http = error as? V2HTTPFailure {
            code = .http; number = http.status
        } else {
            let nsError = error as NSError
            switch nsError.domain {
            case NSURLErrorDomain: code = .urlSession; number = nsError.code
            case NSPOSIXErrorDomain: code = .posix; number = nsError.code
            case NSCocoaErrorDomain: code = .cocoa; number = nsError.code
            case NSOSStatusErrorDomain: code = .audioSession; number = nsError.code
            default: code = .unknown
            }
        }
        numericCode = number
    }
}

/// One WebRTC audio session at a time for the owned active call. The App offers
/// with every candidate gathered, the module answers through signaling, and
/// libwebrtc owns capture, echo cancellation, Opus, jitter buffering and
/// playout. A failed session is replaced by a new one for the same call, which
/// keeps its mute and audio route choices.
@MainActor
final class V2MediaCoordinator: ObservableObject {
    @Published private(set) var state = V2MediaState.idle
    @Published private(set) var lastFailure: V2MediaFailureDiagnostic?
    @Published private(set) var statistics = V2MediaStatistics()
    @Published private(set) var muted = false
    /// Outputs the call can switch between, and the one in use.
    @Published private(set) var routes: [V2AudioRoute] = []
    @Published private(set) var route: V2AudioRoute?
    var speaker: Bool { route?.kind == .speaker }
    /// A new session is restoring audio the same call had before.
    @Published private(set) var recovering = false
    /// Called after a session failed and stopped, so its owner can start the next one.
    var onFailure: (() -> Void)?
    private let audio: V2MediaAudio
    private let peerFactory: @MainActor ([V2ICEServer]) throws -> V2MediaPeer
    private let create: (V2CallContext, String) async throws -> V2MediaCreated
    private let offer: (V2CallContext, String, String) async throws -> String
    private let delete: (V2CallContext, String) async -> Void
    private let timing: V2MediaTiming
    private(set) var context: V2CallContext?
    private var lastContext: V2CallContext?
    private var chosenRoute: V2AudioRoute?
    private var routeObserver: NSObjectProtocol?
    private var callKitManaged = false
    private var ownsVoiceSession = false
    private var generation = UUID()
    private var sessionID: String?
    private var peer: V2MediaPeer?
    private var startTask: Task<Void, Never>?, monitorTask: Task<Void, Never>?, stopTask: Task<Void, Never>?
    private var connectedAt: ContinuousClock.Instant?, disconnectedAt: ContinuousClock.Instant?
    private var lastReceivedAt: ContinuousClock.Instant?
    private var statisticsFrozen = true
    var active: Bool { context != nil || startTask != nil || stopTask != nil || state == .stopping }
    var statusTitle: String {
        if recovering, state != .paired, state != .idle { return "正在恢复音频" }
        return state.title
    }
    init(audio: V2MediaAudio? = nil, peerFactory: (@MainActor ([V2ICEServer]) throws -> V2MediaPeer)? = nil, timing: V2MediaTiming = V2MediaTiming(),
         create: @escaping (V2CallContext, String) async throws -> V2MediaCreated,
         offer: @escaping (V2CallContext, String, String) async throws -> String,
         delete: @escaping (V2CallContext, String) async -> Void) {
        self.audio = audio ?? V2WebRTCAudio()
        self.peerFactory = peerFactory ?? { try V2WebRTCPeer(servers: $0) }
        self.timing = timing; self.create = create; self.offer = offer; self.delete = delete
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoutes() }
        }
    }
    deinit { routeObserver.map(NotificationCenter.default.removeObserver) }
    /// CallKit activates the voice session; otherwise media activates it.
    func useCallKitAudioSession() { callKitManaged = true }
    func callKitAudioActivated(_ session: AVAudioSession) { audio.callKitActivated(session) }
    func callKitAudioDeactivated(_ session: AVAudioSession) { audio.callKitDeactivated(session) }

    func start(context: V2CallContext, validate: @escaping () -> Bool) {
        guard !active else { return }
        let resuming = lastContext?.sameCall(context) == true
        let stamp = UUID(); generation = stamp; self.context = context; lastContext = context
        lastFailure = nil; statistics = V2MediaStatistics(); statisticsFrozen = false
        connectedAt = nil; disconnectedAt = nil; lastReceivedAt = nil
        if !resuming { muted = false; chosenRoute = nil }
        refreshRoutes()
        recovering = resuming
        state = .preparing
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == stamp { self.startTask = nil } }
            var stage = V2MediaFailureStage.preparing
            do {
                if !self.callKitManaged { try self.audio.activateVoice(); self.ownsVoiceSession = true }
                stage = .creatingSession
                let created = try await self.create(context, UUID().uuidString.lowercased())
                guard self.generation == stamp, !Task.isCancelled else {
                    Task { await self.delete(context, created.session_id) }; return
                }
                self.sessionID = created.session_id
                guard validate() else { throw V2MediaFailure.stale }
                let peer = try self.peerFactory(created.ice_servers)
                self.peer = peer
                peer.setMuted(self.muted)
                peer.onState = { [weak self] state in self?.peerChanged(state, stamp: stamp) }
                self.state = .authenticating
                stage = .gathering
                let description = try await peer.offer()
                guard self.generation == stamp, !Task.isCancelled, validate() else { throw V2MediaFailure.stale }
                stage = .signaling
                let answer = try await self.offer(context, created.session_id, description)
                guard self.generation == stamp, !Task.isCancelled, validate() else { throw V2MediaFailure.stale }
                try await peer.accept(answer: answer)
                stage = .connecting
                if self.state == .authenticating { self.state = .waiting }
                self.monitor(stamp: stamp, validate: validate)
            } catch { self.fail(error, stamp: stamp, stage: stage) }
        }
    }
    private func peerChanged(_ change: V2PeerState, stamp: UUID) {
        guard generation == stamp else { return }
        switch change {
        case .connected:
            disconnectedAt = nil
            if connectedAt == nil {
                connectedAt = timing.now(); lastReceivedAt = connectedAt
                // Starting the audio unit can reset the route the user chose.
                if let chosenRoute { try? audio.select(chosenRoute) }
                refreshRoutes()
            }
            if state == .waiting || state == .authenticating { state = .paired; recovering = false }
        case .disconnected:
            if disconnectedAt == nil { disconnectedAt = timing.now() }
        case .failed, .closed:
            fail(V2MediaFailure.disconnected, stamp: stamp, stage: connectedAt == nil ? .connecting : .streaming)
        case .connecting: break
        }
    }
    /// Checks ownership, connection progress and inbound audio once a period.
    private func monitor(stamp: UUID, validate: @escaping () -> Bool) {
        let started = timing.now()
        monitorTask = Task { [weak self] in
            while let self, self.generation == stamp, !Task.isCancelled {
                do { try await self.timing.sleep(self.timing.period) } catch { return }
                guard self.generation == stamp, let peer = self.peer else { return }
                guard validate() else { self.fail(V2MediaFailure.stale, stamp: stamp, stage: .streaming); return }
                let now = self.timing.now()
                if self.connectedAt == nil, now - started >= self.timing.connect {
                    self.fail(V2MediaFailure.timeout, stamp: stamp, stage: .connecting); return
                }
                if let since = self.disconnectedAt, now - since >= self.timing.disconnected {
                    self.fail(V2MediaFailure.disconnected, stamp: stamp, stage: .streaming); return
                }
                let current = await peer.statistics()
                guard self.generation == stamp else { return }
                if current.packetsReceived > self.statistics.peer.packetsReceived { self.lastReceivedAt = now }
                self.record(current)
                if let last = self.lastReceivedAt, now - last >= self.timing.silence {
                    self.fail(V2MediaFailure.downlinkStopped, stamp: stamp, stage: .streaming); return
                }
            }
        }
    }
    private func record(_ peer: V2PeerStatistics) {
        guard !statisticsFrozen else { return }
        var next = statistics
        next.peer = peer
        if let connectedAt { next.connectedMilliseconds = UInt64(max(0, (timing.now() - connectedAt) / .milliseconds(1))) }
        statistics = next
    }
    private func fail(_ error: Error, stamp: UUID, stage: V2MediaFailureStage) {
        guard generation == stamp, state != .stopping else { return }
        if case .failed = state { return }
        lastFailure = V2MediaFailureDiagnostic(error: error, stage: stage)
#if DEBUG
        if let failure = lastFailure {
            NSLog("[AirSIM Media] stage=fail failureStage=%@ code=%@ numeric=%ld received=%llu sent=%llu", failure.stage.rawValue, failure.code.rawValue, failure.numericCode ?? 0, statistics.peer.packetsReceived, statistics.peer.packetsSent)
        }
#endif
        state = .failed("音频连接中断，正在恢复")
        Task { [weak self] in
            guard let self, self.generation == stamp else { return }
            await self.stop(keepFailure: true)
            self.onFailure?()
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
        let tasks = [startTask, monitorTask].compactMap { $0 }
        startTask = nil; monitorTask = nil
        tasks.forEach { $0.cancel() }
        if let peer {
            let last = await peer.statistics()
            record(last)
            peer.close()
        }
        peer = nil
#if DEBUG
        if !statisticsFrozen, statistics.peer.packetsReceived > 0 || statistics.peer.packetsSent > 0 { recordLastCallStatistics() }
#endif
        statisticsFrozen = true
        if let context, let sessionID { Task { await delete(context, sessionID) } }
        context = nil; sessionID = nil
        if ownsVoiceSession { audio.deactivateVoice(); ownsVoiceSession = false }
        let task = Task { [self] in
            for task in tasks { await task.value }
            state = keepFailure ? failed : .idle
            if !keepFailure { recovering = false }
            stopTask = nil
        }
        stopTask = task
        await task.value
    }
    func setMuted(_ value: Bool) { muted = value; peer?.setMuted(value) }
    func setSpeaker(_ value: Bool) { select(value ? .speaker : routes.first { $0.kind == .receiver } ?? .speaker) }
    func select(_ route: V2AudioRoute) {
        do { try audio.select(route); chosenRoute = route } catch {
            lastFailure = V2MediaFailureDiagnostic(error: error, stage: .speaker)
        }
        refreshRoutes()
    }
    func refreshRoutes() { routes = audio.routes; route = audio.currentRoute }
#if DEBUG
    /// Counts only; read from the device container after a real call.
    private func recordLastCallStatistics() {
        let p = statistics.peer
        let values: [String: Any] = [
            "received": p.packetsReceived, "sent": p.packetsSent, "lost": p.packetsLost,
            "concealed_samples": p.concealedSamples, "received_samples": p.receivedSamples,
            "jitter_buffer_ms": Int(p.jitterBufferMilliseconds.rounded()), "rtt_ms": Int(p.roundTripMilliseconds.rounded()),
            "candidate": p.candidate, "connected_ms": statistics.connectedMilliseconds,
            "failure": lastFailure.map { "\($0.stage.rawValue):\($0.code.rawValue)" } ?? ""
        ]
        UserDefaults.standard.set(values, forKey: "airsim.v2.last-media-stats")
    }
#endif
}

/// Media deadlines; tests shorten them.
struct V2MediaTiming {
    var period: Duration = .seconds(1)
    /// From submitting the answer until ICE and DTLS connect.
    var connect: Duration = .seconds(10)
    /// A disconnected transport that does not recover in time is replaced.
    var disconnected: Duration = .seconds(3)
    /// The module sends audio every 20 ms; this long without packets replaces the session.
    var silence: Duration = .seconds(3)
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}
