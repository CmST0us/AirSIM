use std::ffi::c_int;
use std::ptr::NonNull;

pub const OPUS_SAMPLE_RATE: usize = 16000;
pub const OPUS_FRAME_SAMPLES: usize = 320;
pub const OPUS_MAX_PACKET: usize = 512;

#[repr(C)]
struct RawOpusEncoder {
    _private: [u8; 0],
}

#[repr(C)]
struct RawOpusDecoder {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn airsim_rs_opus_encoder_create() -> *mut RawOpusEncoder;
    fn airsim_rs_opus_encoder_destroy(e: *mut RawOpusEncoder);
    fn airsim_rs_opus_encode(
        e: *mut RawOpusEncoder,
        pcm: *const i16,
        frame_size: c_int,
        out: *mut u8,
        max_out: c_int,
    ) -> c_int;

    fn airsim_rs_opus_decoder_create() -> *mut RawOpusDecoder;
    fn airsim_rs_opus_decoder_destroy(d: *mut RawOpusDecoder);
    fn airsim_rs_opus_packet_nb_samples(packet: *const u8, len: c_int, fs: c_int) -> c_int;
    fn airsim_rs_opus_decode(
        d: *mut RawOpusDecoder,
        packet: *const u8,
        len: c_int,
        pcm: *mut i16,
        frame_size: c_int,
        decode_fec: c_int,
    ) -> c_int;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeKind {
    Packet,
    Fec,
    Erasure,
}

pub struct OpusEncoder {
    raw: NonNull<RawOpusEncoder>,
}

// Each encoder instance is owned by a single capture thread (never shared concurrently).
unsafe impl Send for OpusEncoder {}

impl OpusEncoder {
    pub fn new() -> Result<Self, &'static str> {
        let ptr = unsafe { airsim_rs_opus_encoder_create() };
        NonNull::new(ptr)
            .map(|raw| Self { raw })
            .ok_or("opus_encoder_create_failed")
    }

    pub fn encode(&mut self, pcm: &[i16; OPUS_FRAME_SAMPLES], out: &mut [u8]) -> Result<usize, &'static str> {
        let max_out = out.len().min(OPUS_MAX_PACKET) as c_int;
        let n = unsafe {
            airsim_rs_opus_encode(
                self.raw.as_ptr(),
                pcm.as_ptr(),
                OPUS_FRAME_SAMPLES as c_int,
                out.as_mut_ptr(),
                max_out,
            )
        };
        if n > 0 {
            Ok(n as usize)
        } else {
            Err("opus_encode_failed")
        }
    }
}

impl Drop for OpusEncoder {
    fn drop(&mut self) {
        unsafe { airsim_rs_opus_encoder_destroy(self.raw.as_ptr()) };
    }
}

pub struct OpusDecoder {
    raw: NonNull<RawOpusDecoder>,
}

unsafe impl Send for OpusDecoder {}

impl OpusDecoder {
    pub fn new() -> Result<Self, &'static str> {
        let ptr = unsafe { airsim_rs_opus_decoder_create() };
        NonNull::new(ptr)
            .map(|raw| Self { raw })
            .ok_or("opus_decoder_create_failed")
    }

    /// Validates that `packet` carries an exact 20 ms (320-sample @ 16 kHz) Opus frame.
    pub fn is_valid_20ms_packet(packet: &[u8]) -> bool {
        if packet.is_empty() || packet.len() > OPUS_MAX_PACKET {
            return false;
        }
        let n = unsafe {
            airsim_rs_opus_packet_nb_samples(
                packet.as_ptr(),
                packet.len() as c_int,
                OPUS_SAMPLE_RATE as c_int,
            )
        };
        n == OPUS_FRAME_SAMPLES as c_int
    }

    /// Decodes a 20 ms frame (normal, LBRR FEC, or PLC erasure).
    /// Returns `Ok(concealed)` where `concealed == true` if FEC or PLC was used.
    pub fn decode(
        &mut self,
        packet: Option<&[u8]>,
        kind: DecodeKind,
        out: &mut [i16; OPUS_FRAME_SAMPLES],
    ) -> Result<bool, &'static str> {
        let mut concealed = kind != DecodeKind::Packet;
        let mut n: c_int = -1;
        if kind != DecodeKind::Erasure {
            if let Some(pkt) = packet {
                if Self::is_valid_20ms_packet(pkt) {
                    let fec = if kind == DecodeKind::Fec { 1 } else { 0 };
                    n = unsafe {
                        airsim_rs_opus_decode(
                            self.raw.as_ptr(),
                            pkt.as_ptr(),
                            pkt.len() as c_int,
                            out.as_mut_ptr(),
                            OPUS_FRAME_SAMPLES as c_int,
                            fec,
                        )
                    };
                }
            }
        }
        if n != OPUS_FRAME_SAMPLES as c_int {
            concealed = true;
            n = unsafe {
                airsim_rs_opus_decode(
                    self.raw.as_ptr(),
                    std::ptr::null(),
                    0,
                    out.as_mut_ptr(),
                    OPUS_FRAME_SAMPLES as c_int,
                    0,
                )
            };
        }
        if n == OPUS_FRAME_SAMPLES as c_int {
            Ok(concealed)
        } else {
            Err("opus_decode_failed")
        }
    }
}

impl Drop for OpusDecoder {
    fn drop(&mut self) {
        unsafe { airsim_rs_opus_decoder_destroy(self.raw.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opus_encode_decode_fec_plc_roundtrip() {
        let mut enc = OpusEncoder::new().unwrap();
        let mut dec = OpusDecoder::new().unwrap();
        let mut pcm = [0i16; OPUS_FRAME_SAMPLES];
        let mut pkt = [0u8; OPUS_MAX_PACKET];
        let mut out = [0i16; OPUS_FRAME_SAMPLES];

        for frame in 0..10 {
            for (i, s) in pcm.iter_mut().enumerate() {
                let t = (frame * OPUS_FRAME_SAMPLES + i) as f32 / 16000.0;
                *s = (12000.0 * (2.0 * std::f32::consts::PI * 440.0 * t).sin()) as i16;
            }
            let len = enc.encode(&pcm, &mut pkt).unwrap();
            assert!(len > 20 && len < 300);
            assert!(OpusDecoder::is_valid_20ms_packet(&pkt[..len]));
            let concealed = dec.decode(Some(&pkt[..len]), DecodeKind::Packet, &mut out).unwrap();
            assert!(!concealed);
        }

        // Verify PLC produces valid samples without error.
        let concealed = dec.decode(None, DecodeKind::Erasure, &mut out).unwrap();
        assert!(concealed);
    }
}
