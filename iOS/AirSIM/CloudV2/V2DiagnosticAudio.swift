import AVFoundation
import Foundation

// No content leaves memory. Only used behind the explicit simulator DEBUG switch.
private final class V2SpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: V2PCMConverter?
    private var frames: [Data] = []
    private var continuation: CheckedContinuation<[Data], Error>?
    private var finished = false
    private var sourceFormat = "no_buffer"
    var formatDescription: String { lock.lock(); defer { lock.unlock() }; return sourceFormat }
    func install(_ continuation: CheckedContinuation<[Data], Error>) {
        lock.lock(); defer { lock.unlock() }
        if finished { continuation.resume(throwing: CancellationError()) } else { self.continuation = continuation }
    }
    func consume(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finishLocked(.failure(V2AudioError.speech)); return }
        sourceFormat = "\(Int(pcm.format.sampleRate))Hz/\(pcm.format.channelCount)ch/format=\(pcm.format.commonFormat.rawValue)/interleaved=\(pcm.format.isInterleaved)"
        if pcm.frameLength == 0 { finishLocked(.success(frames)); return }
        do {
            if converter == nil { converter = try V2PCMConverter(rate: pcm.format.sampleRate, capacity: max(8192, pcm.frameCapacity)) }
            let converted = try converter!.convert(pcm)
            guard frames.count + converted.count <= 1500 else { throw V2AudioError.speech }
            frames.append(contentsOf: converted)
        } catch { finishLocked(.failure(V2AudioError.speech)) }
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; finishLocked(.failure(CancellationError())) }
    private func finishLocked(_ result: Result<[Data], Error>) {
        guard !finished else { return }
        finished = true
        let pending = continuation; continuation = nil
        frames.removeAll(); converter = nil
        pending?.resume(with: result)
    }
}

@MainActor
final class V2DiagnosticAudio {
    private var synthesizer: AVSpeechSynthesizer?
    private var collector: V2SpeechCollector?
    private var prompt: [Data] = []
    private var promptIndex = 0
    private var echoes: [(UInt64, Data)] = []
    private var deadline: UInt64?
    private(set) var sourceFormat = "no_buffer"
    private(set) var zeroFrames: UInt64 = 0
    private(set) var echoDrops: UInt64 = 0
    var echoCount: Int { echoes.count }
    init(prompt: [Data] = []) { self.prompt = Array(prompt.prefix(1500)) }
    func prepare() async throws {
#if DEBUG && targetEnvironment(simulator)
        let synthesizer = AVSpeechSynthesizer(), collector = V2SpeechCollector()
        self.synthesizer = synthesizer; self.collector = collector
        defer { sourceFormat = collector.formatDescription }
        let utterance = AVSpeechUtterance(string: "这里是 AirSIM App 云端音频测试，口令是云朵三六。听到提示后，请说一句短句，确认能听到自己的回声。")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        prompt = try await V2MediaDeadline<[Data]>().run(clock: V2SystemMediaClock(), until: DispatchTime.now().uptimeNanoseconds + 30_000_000_000, cancel: { collector.cancel(); synthesizer.stopSpeaking(at: .immediate) }) {
            try await withCheckedThrowingContinuation { continuation in
                collector.install(continuation)
                synthesizer.write(utterance) { collector.consume($0) }
            }
        }
        guard !prompt.isEmpty else { throw V2AudioError.speech }
#else
        throw V2MediaFailure.inactive
#endif
    }
    func start(at now: UInt64) { deadline = now }
    func receive(_ pcm: Data, at now: UInt64) {
        guard deadline != nil, promptIndex >= prompt.count, pcm.count == 320 else { return }
        discardExpired(at: now)
        guard echoes.count < 20 else { echoDrops += 1; return }
        echoes.append((now, pcm))
    }
    func output(at now: UInt64) -> Data? {
        guard let deadline, now >= deadline else { return nil }
        discardExpired(at: now)
        if now - deadline >= 20_000_000 {
            let skip = (now - deadline) / 20_000_000 + 1
            self.deadline = deadline + skip * 20_000_000
            promptIndex = min(prompt.count, promptIndex + Int(skip)); return nil
        }
        self.deadline = deadline + 20_000_000
        if promptIndex < prompt.count { defer { promptIndex += 1 }; return prompt[promptIndex] }
        if let first = echoes.first, now >= first.0 + 400_000_000 { echoes.removeFirst(); return first.1 }
        zeroFrames += 1; return Data(repeating: 0, count: 320)
    }
    private func discardExpired(at now: UInt64) {
        while let first = echoes.first, now > first.0, now - first.0 > 500_000_000 { echoes.removeFirst(); echoDrops += 1 }
    }
    func stop() {
        collector?.cancel(); synthesizer?.stopSpeaking(at: .immediate)
        collector = nil; synthesizer = nil; prompt.removeAll(); echoes.removeAll(); deadline = nil
    }
}
