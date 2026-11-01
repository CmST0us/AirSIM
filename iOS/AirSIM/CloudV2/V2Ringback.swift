import AVFoundation
import Foundation

/// The ringback heard while an outgoing call rings. Call audio starts only once
/// the call connects, so until then the App plays the tone itself.
@MainActor
protocol V2Ringback: AnyObject {
    /// Without CallKit the tone activates the voice session and releases it on stop.
    func start(activatingSession: Bool)
    func stop()
}

/// 450 Hz, one second on and four off.
@MainActor
final class V2RingbackTone: V2Ringback {
    private var engine: AVAudioEngine?
    private var ownsSession = false

    func start(activatingSession: Bool) {
        guard engine == nil else { return }
        do {
            if activatingSession {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
                try session.setActive(true)
                ownsSession = true
            }
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let period = Self.period()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: period.format)
            try engine.start()
            player.scheduleBuffer(period, at: nil, options: .loops)
            player.play()
            self.engine = engine
        } catch {
            stop()
        }
    }
    func stop() {
        engine?.stop(); engine = nil
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    /// One cadence period: a second of tone with 10 ms ramps, then four seconds of silence.
    private static func period() -> AVAudioPCMBuffer {
        let rate = 8_000
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 5))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0], tone = rate, ramp = rate / 100
        for i in 0..<Int(buffer.frameLength) {
            guard i < tone else { samples[i] = 0; continue }
            let edge = Float(min(i, tone - 1 - i, ramp)) / Float(ramp)
            samples[i] = 0.2 * edge * sinf(2 * .pi * 450 * Float(i) / Float(rate))
        }
        return buffer
    }
}
