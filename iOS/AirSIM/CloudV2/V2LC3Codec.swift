import Foundation

/// External v2 media PCM: 20 ms packets at the LC3 wrapper's 16 kHz rate.
enum V2PCM {
    static let sampleRate = Double(AIRSIM_LC3_SAMPLE_RATE)
    static let frameSamples = Int(AIRSIM_LC3_PACKET_SAMPLES)
    static let frameBytes = Int(AIRSIM_LC3_PCM_BYTES)
}

// Each media generation owns one encoder and decoder, used serially by its coordinator.
final class V2LC3Codec {
    struct Decoded { let pcm: Data; let concealed: Bool }
    private let encoder: OpaquePointer
    private let decoder: OpaquePointer

    init() throws {
        guard let encoder = airsim_lc3_encoder_create() else { throw V2AudioError.conversion }
        guard let decoder = airsim_lc3_decoder_create() else {
            airsim_lc3_encoder_destroy(encoder)
            throw V2AudioError.conversion
        }
        self.encoder = encoder; self.decoder = decoder
    }
    deinit {
        airsim_lc3_encoder_destroy(encoder)
        airsim_lc3_decoder_destroy(decoder)
    }
    func encode(_ pcm: Data) throws -> Data {
        guard pcm.count == V2PCM.frameBytes else { throw V2AudioError.format }
        var payload = Data(count: 80)
        let result = pcm.withUnsafeBytes { input in
            payload.withUnsafeMutableBytes { output in
                airsim_lc3_encode(encoder, input.bindMemory(to: UInt8.self).baseAddress!, output.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard result == 0 else { throw V2AudioError.conversion }
        return payload
    }
    func decode(_ payload: Data?, sequence: UInt64? = nil) throws -> Decoded {
        guard payload == nil || payload?.count == 80 else { throw V2AudioError.format }
        var pcm = Data(count: V2PCM.frameBytes)
        let result = pcm.withUnsafeMutableBytes { output in
            let address = output.bindMemory(to: UInt8.self).baseAddress!
            if let payload {
                return payload.withUnsafeBytes { input in
                    sequence.map { airsim_lc3_decode_packet(decoder, input.bindMemory(to: UInt8.self).baseAddress!, $0, address) }
                        ?? airsim_lc3_decode(decoder, input.bindMemory(to: UInt8.self).baseAddress!, address)
                }
            }
            return sequence.map { airsim_lc3_decode_packet(decoder, nil, $0, address) }
                ?? airsim_lc3_decode(decoder, nil, address)
        }
        guard result >= 0 else { throw V2AudioError.conversion }
        return Decoded(pcm: pcm, concealed: result == 1)
    }
}
