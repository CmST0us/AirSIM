import AVFoundation
import Foundation

// Conversion runs on one processing queue; the converter and fractional filter
// history survive callback boundaries. All input is explicitly mixed to mono.
final class V2PCMConverter {
    let rate: Double
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var tail = Data()
    init(rate: Double, capacity: AVAudioFrameCount = 8192) throws {
        guard rate > 0, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: pcm),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 4096) else { throw V2AudioError.format }
        self.rate = rate; self.converter = converter; self.input = input; self.output = output
        converter.primeMethod = .none
    }
    func convert(samples: UnsafeBufferPointer<Float>) throws -> [Data] {
        guard samples.count <= Int(input.frameCapacity), let address = samples.baseAddress else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        input.floatChannelData![0].update(from: address, count: samples.count)
        var supplied = false
        var frames: [Data] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, result in
                if supplied { result.pointee = .noDataNow; return nil }
                supplied = true; result.pointee = .haveData; return self.input
            }
            if error != nil || status == .error { throw V2AudioError.conversion }
            if output.frameLength > 0 {
                tail.append(Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2))
                while tail.count >= 320 { frames.append(Data(tail.prefix(320))); tail.removeFirst(320) }
            }
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { break }
        }
        return frames
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Data] {
        guard buffer.format.sampleRate == rate, let channels = buffer.floatChannelData, buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.frameLength <= input.frameCapacity else { throw V2AudioError.format }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for i in 0..<count {
            for channel in 0..<channelCount { mono[i] += buffer.format.isInterleaved ? channels[0][i * channelCount + channel] : channels[channel][i] }
            mono[i] /= Float(channelCount)
        }
        return try mono.withUnsafeBufferPointer { try convert(samples: $0) }
    }
}

enum V2AudioError: Error {
    case permission, format, conversion, voiceProcessing(Int), engine(Int), interrupted, formatChanged, speech
    var message: String {
        switch self {
        case .permission: return "麦克风权限未开启"
        case .voiceProcessing(let code): return "系统语音处理不可用（\(code)），未启用麦克风音频"
        case .engine(let code): return "音频引擎启动失败（\(code)）"
        case .format: return "不支持当前音频输入格式"
        case .conversion: return "音频转换失败"
        case .interrupted: return "音频被系统中断，请恢复音频"
        case .formatChanged: return "音频设备格式已变化，请恢复音频"
        case .speech: return "诊断提示生成失败"
        }
    }
}

#if DEBUG
enum V2AudioPortCategory: String, CaseIterable {
    case builtInMicrophone, receiver, speaker, wired, bluetooth, other, none
    static func classify(_ port: AVAudioSession.Port) -> Self {
        switch port {
        case .builtInMic: return .builtInMicrophone
        case .builtInReceiver: return .receiver
        case .builtInSpeaker: return .speaker
        case .headphones, .headsetMic, .lineIn, .lineOut, .usbAudio: return .wired
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        default: return .other
        }
    }
    static func categories(_ ports: [AVAudioSession.Port]) -> [Self] {
        let values = Set(ports.map(classify))
        return values.isEmpty ? [.none] : allCases.filter { values.contains($0) }
    }
}
#endif

struct V2AudioMetrics {
    var captured: UInt64 = 0
    var inputDrops: UInt64 = 0
    var outputDrops: UInt64 = 0
    var rendered: UInt64 = 0
    var playbackDrops: UInt64 = 0
    var sampleRate: Double = 0
    var channels: UInt32 = 0
    var voiceProcessing = false
    var running = false
    var queuedPlayback = 0
#if DEBUG
    var inputRoute: [V2AudioPortCategory] = [.none]
    var outputRoute: [V2AudioPortCategory] = [.none]
#endif
}

// Use the established v1 voice-bandlimited encoder directly from the audio tap.
// The queue keeps at most five complete 20 ms frames and never drops frames by age.
final class V2CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = VoicePCMEncoder()
    private var tail = Data()
    private var stopped = false
    private var frames: [Data] = []
    private var metrics = V2AudioMetrics()
    let capacity: Int
    init(rate: Double) throws {
        guard rate > 0 else { throw V2AudioError.format }
        capacity = max(1, Int(rate * 0.02))
    }
    func push(_ buffer: AVAudioPCMBuffer) {
        guard buffer.floatChannelData != nil, buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        let encoded = encoder.encode(buffer)
        guard !encoded.isEmpty else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        tail.append(encoded)
        while tail.count >= 320 {
            let frame = Data(tail.prefix(320))
            tail.removeFirst(320)
            if frames.count == 5 {
                frames.removeFirst()
                metrics.inputDrops += 1
            }
            metrics.captured += 1
            frames.append(frame)
        }
        lock.unlock()
    }
    func pull() -> (frames: [Data], metrics: V2AudioMetrics, error: V2AudioError?) {
        lock.lock(); defer { lock.unlock() }
        let result = frames
        frames.removeAll(keepingCapacity: true)
        return (result, metrics, nil)
    }
    func setMuted(_ value: Bool) { encoder.setMuted(value) }
    func stop() async {
        lock.lock()
        stopped = true
        frames.removeAll()
        tail.removeAll()
        lock.unlock()
    }
}

struct V2PlaybackWindow {
    private(set) var pending = 0
    private(set) var generation = UUID()
    mutating func reserve() -> UUID? { guard pending < 3 else { return nil }; pending += 1; return generation }
    mutating func complete(_ stamp: UUID) -> Bool { guard stamp == generation, pending > 0 else { return false }; pending -= 1; return true }
    mutating func reset() { generation = UUID(); pending = 0 }
}

@MainActor
protocol V2AudioIO: AnyObject {
    var metrics: V2AudioMetrics { get }
    var onFailure: ((V2AudioError) -> Void)? { get set }
    func prepare(microphone: Bool) async throws
    func takeCaptured() -> [Data]
    func play(_ pcm: Data) -> Bool
    func setMuted(_ value: Bool)
    func setSpeaker(_ value: Bool) throws
    func stop() async
}

@MainActor
final class V2AudioEngine: V2AudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: V2CaptureBuffer?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var playbackWindow = V2PlaybackWindow()
    var callKitManaged = false
    private var sessionActive = false
    private var installedTap = false
    private var preparing = false
    private var stopTask: Task<Void, Never>?
    private var permission: CheckedContinuation<Bool, Error>?
    private let requestPermission: (@escaping (Bool) -> Void) -> Void
    private let drainHook: (() async -> Void)?
    init(requestPermission: @escaping (@escaping (Bool) -> Void) -> Void = { AVAudioSession.sharedInstance().requestRecordPermission($0) }, drainHook: (() async -> Void)? = nil) {
        self.requestPermission = requestPermission; self.drainHook = drainHook
    }
    private(set) var metrics = V2AudioMetrics()
    var onFailure: ((V2AudioError) -> Void)?
    func prepare(microphone: Bool) async throws {
        if let stopTask { await stopTask.value }
        guard !preparing, engine == nil else { throw V2Error.busy }
        preparing = true; generation = UUID(); let stamp = generation
        metrics = V2AudioMetrics()
        defer { if generation == stamp { preparing = false } }
        do {
            if microphone {
                let granted = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        permission = continuation
                        requestPermission { [weak self] granted in
                            Task { @MainActor in
                                guard let self, self.generation == stamp else { return }
                                let pending = self.permission; self.permission = nil
                                pending?.resume(returning: granted)
                            }
                        }
                        if Task.isCancelled { cancelPermission() }
                    }
                } onCancel: { Task { @MainActor in if self.generation == stamp { self.cancelPermission() } } }
                guard generation == stamp, !Task.isCancelled else { throw CancellationError() }
                guard granted else { throw V2AudioError.permission }
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            if !callKitManaged { try session.setActive(true); sessionActive = true }
            try session.overrideOutputAudioPort(.none)
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            self.engine = engine; self.player = player
            engine.attach(player)
            let playback = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: playback)
            if microphone {
                do { try engine.inputNode.setVoiceProcessingEnabled(true) }
                catch { throw V2AudioError.voiceProcessing((error as NSError).code) }
                guard engine.inputNode.isVoiceProcessingEnabled else { throw V2AudioError.voiceProcessing(-1) }
                metrics.voiceProcessing = true
                let format = engine.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw V2AudioError.format }
                inputFormat = format
                metrics.sampleRate = format.sampleRate; metrics.channels = format.channelCount
                let capture = try V2CaptureBuffer(rate: format.sampleRate); self.capture = capture
                engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.02), format: format) { [weak capture] buffer, _ in capture?.push(buffer) }
                installedTap = true
            }
            outputFormat = engine.outputNode.inputFormat(forBus: 0)
            engine.prepare()
            do { try engine.start() } catch { throw V2AudioError.engine((error as NSError).code) }
            player.play()
            metrics.running = true
#if DEBUG
            updateRoute()
#endif
            let center = NotificationCenter.default
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification, .AVAudioEngineConfigurationChange] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    Task { @MainActor in
                        guard let self, self.generation == stamp else { return }
#if DEBUG
                        if notification.name == AVAudioSession.routeChangeNotification { self.updateRoute() }
#endif
                        if notification.name == AVAudioSession.interruptionNotification {
                            guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
                            self.onFailure?(.interrupted)
                        } else if notification.name == AVAudioSession.mediaServicesWereResetNotification { self.onFailure?(.interrupted) }
                        else {
                            let changedInput = self.inputFormat.map { $0 != engine.inputNode.outputFormat(forBus: 0) } ?? false
                            if changedInput || self.outputFormat != engine.outputNode.inputFormat(forBus: 0) { self.onFailure?(.formatChanged) }
                        }
                    }
                })
            }
        } catch { if generation == stamp { await stop() }; throw error }
    }
    func takeCaptured() -> [Data] {
        guard let result = capture?.pull() else { return [] }
        metrics.captured = result.metrics.captured; metrics.inputDrops = result.metrics.inputDrops; metrics.outputDrops = result.metrics.outputDrops
        if let error = result.error { onFailure?(error) }
        return result.frames
    }
    func play(_ pcm: Data) -> Bool {
        guard metrics.running, let player, pcm.count == 320 else { return false }
        guard let playbackStamp = playbackWindow.reserve() else { metrics.playbackDrops += 1; return false }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let bytes = Array(pcm)
        for i in 0..<160 { buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) / 32768 }
        let stamp = generation
        metrics.queuedPlayback += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == stamp, self.playbackWindow.complete(playbackStamp) else { return }
                self.metrics.queuedPlayback = self.playbackWindow.pending; self.metrics.rendered += 1
            }
        }
        if !player.isPlaying, metrics.queuedPlayback >= 2 { player.play() }
        return true
    }
    func setMuted(_ value: Bool) { capture?.setMuted(value) }
    func setSpeaker(_ value: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(value ? .speaker : .none)
#if DEBUG
        updateRoute()
#endif
    }
#if DEBUG
    private func updateRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        metrics.inputRoute = V2AudioPortCategory.categories(route.inputs.map(\.portType))
        metrics.outputRoute = V2AudioPortCategory.categories(route.outputs.map(\.portType))
    }
#endif
    private func cancelPermission() {
        let pending = permission; permission = nil; pending?.resume(throwing: CancellationError())
    }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        generation = UUID(); preparing = false; cancelPermission()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        let old = capture; capture = nil
        if installedTap { engine?.inputNode.removeTap(onBus: 0); installedTap = false }
        player?.stop(); engine?.stop(); player = nil; engine = nil
        inputFormat = nil; outputFormat = nil
        playbackWindow.reset(); metrics.running = false; metrics.queuedPlayback = 0
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        let drainHook = drainHook
        let task = Task { [self] in
            await old?.stop(); await drainHook?()
            stopTask = nil // Release before waking any prepare/stop waiters.
        }
        stopTask = task
        await task.value
    }
}
