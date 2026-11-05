import Foundation
import AudioToolbox
import WebRTC

/// Offline test device. Generates a tone in memory, discards playout, and never
/// opens a microphone, speaker, recording file or AVAudioSession.
final class SyntheticAudioDevice: NSObject, RTCAudioDevice {
    let deviceInputSampleRate = 48000.0, deviceOutputSampleRate = 48000.0
    let inputIOBufferDuration = 0.01, outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1, outputNumberOfChannels = 1
    let inputLatency = 0.0, outputLatency = 0.0
    private let lock = NSLock()
    private var delegate: RTCAudioDeviceDelegate?
    private var initialized = false, recording = false, playing = false
    var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }
    var isPlayoutInitialized: Bool { true }
    var isRecordingInitialized: Bool { true }
    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock(); self.delegate = delegate; initialized = true; lock.unlock()
        Thread.detachNewThread { [self] in
            var tick = 0
            var input = [Int16](repeating: 0, count: 480)
            var output = [Int16](repeating: 0, count: 480)
            while true {
                lock.lock(); let active = initialized, rec = recording, play = playing, target = self.delegate; lock.unlock()
                guard active, let target else { break }
                var flags: AudioUnitRenderActionFlags = []
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = Double(tick * 480)
                timestamp.mFlags = .sampleTimeValid
                if rec {
                    for i in input.indices { input[i] = Int16(sin(Double(tick * 480 + i) * 2 * .pi * 440 / 48000) * 3000) }
                    input.withUnsafeMutableBytes { raw in
                        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                        _ = target.deliverRecordedData(&flags, &timestamp, 0, 480, &buffers, nil, nil)
                    }
                }
                if play {
                    output.withUnsafeMutableBytes { raw in
                        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                        _ = target.getPlayoutData(&flags, &timestamp, 0, 480, &buffers)
                    }
                }
                tick += 1
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return true
    }
    func terminateDevice() -> Bool { lock.lock(); initialized = false; delegate = nil; lock.unlock(); return true }
    func initializePlayout() -> Bool { true }
    func initializeRecording() -> Bool { true }
    func startPlayout() -> Bool { lock.lock(); playing = true; lock.unlock(); return true }
    func stopPlayout() -> Bool { lock.lock(); playing = false; lock.unlock(); return true }
    func startRecording() -> Bool { lock.lock(); recording = true; lock.unlock(); return true }
    func stopRecording() -> Bool { lock.lock(); recording = false; lock.unlock(); return true }
}
