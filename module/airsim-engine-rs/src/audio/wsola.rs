/// Pitch-synchronous WSOLA (Waveform Similarity Overlap-Add) time-scale modification
/// + EG25 QDSP6 Tx headroom/soft-knee conditioning + 8/16 kHz resamplers.
///
/// Designed for Cortex-A7 single-core real-time execution:
/// - Zero heap allocations
/// - 16 kHz wideband voice (320 samples / 20 ms)
/// - Pitch lag search `[32..140]` samples (114 Hz – 500 Hz), coarse stride 2 + fine ±2
/// - Raised-cosine 64-sample (4 ms) overlap-add crossfade for click-free, pitch-preserving
///   clock-drift and jitter-burst absorption.

pub const FRAME_SAMPLES: usize = 320;
pub const MAX_WSOLA_OUT: usize = 480; // up to 320 + 140 = 460 samples
const OVERLAP: usize = 64; // 4 ms @ 16 kHz
const MIN_LAG: usize = 32; // 2.0 ms (500 Hz)
const MAX_LAG: usize = 140; // 8.75 ms (114 Hz)
const SPLIT_POS: usize = 160; // middle of 320-sample frame (leaves 160 >= MAX_LAG before & 160 >= OVERLAP after)

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsolaMode {
    Normal,
    Accelerate,
    PreemptiveExpand,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct WsolaStats {
    pub accelerated_frames: u64,
    pub expanded_frames: u64,
    pub deferred_frames: u64,
    pub samples_removed: u64,
    pub samples_added: u64,
}

pub struct WsolaProcessor {
    /// Precomputed raised-cosine fade weights in Q15 [0..32768] for `OVERLAP` samples.
    fade_in_q15: [i32; OVERLAP],
    cooldown: u8,
    pub stats: WsolaStats,
}

impl WsolaProcessor {
    pub fn new() -> Self {
        let mut fade_in_q15 = [0i32; OVERLAP];
        for (i, w) in fade_in_q15.iter_mut().enumerate() {
            let phase = std::f64::consts::PI * (i as f64 + 0.5) / (OVERLAP as f64);
            let gain = 0.5 * (1.0 - phase.cos());
            *w = (gain * 32768.0).round() as i32;
        }
        Self {
            fade_in_q15,
            cooldown: 0,
            stats: WsolaStats::default(),
        }
    }

    pub fn reset(&mut self) {
        self.cooldown = 0;
    }

    /// Process one 320-sample 16 kHz decoded frame into `out`.
    /// Returns the number of output samples written (`180..=460`).
    /// When `force` is false, enforces a 1-frame cooldown and skips unvoiced consonants
    /// (`corr < 0.52`) to keep speech cadence natural.
    pub fn process(
        &mut self,
        input: &[i16; FRAME_SAMPLES],
        mode: WsolaMode,
        force: bool,
        out: &mut [i16; MAX_WSOLA_OUT],
    ) -> usize {
        if mode == WsolaMode::Normal {
            if self.cooldown > 0 {
                self.cooldown -= 1;
            }
            out[..FRAME_SAMPLES].copy_from_slice(input);
            return FRAME_SAMPLES;
        }

        if !force && self.cooldown > 0 {
            self.cooldown -= 1;
            out[..FRAME_SAMPLES].copy_from_slice(input);
            return FRAME_SAMPLES;
        }

        // Check signal energy in the splice region FIRST. For near-silence (< -48 dBFS RMS),
        // crossfade cleanly with fixed 64-sample (4 ms) shift without wasting CPU on correlation.
        let silence = region_energy(input, SPLIT_POS - 64, 128) < (128u64 * 90 * 90);
        let lag = if silence {
            64
        } else {
            let (best_lag, corr_q15) = find_best_pitch_lag(input);
            if !force && corr_q15 < 17039 {
                // 17039 / 32768 ~= 0.52: defer on unvoiced plosive/fricative to avoid smearing.
                self.stats.deferred_frames += 1;
                out[..FRAME_SAMPLES].copy_from_slice(input);
                return FRAME_SAMPLES;
            }
            best_lag
        };
        self.cooldown = if force { 0 } else { 1 };

        match mode {
            WsolaMode::Accelerate => {
                // Output length = FRAME_SAMPLES - lag:
                // [0 .. SPLIT_POS - lag) copied verbatim from input
                // [SPLIT_POS - lag .. SPLIT_POS - lag + OVERLAP) crossfade:
                //   fade-out input[SPLIT_POS - lag + i] -> fade-in input[SPLIT_POS + i]
                // [SPLIT_POS - lag + OVERLAP .. FRAME_SAMPLES - lag) copied from input[SPLIT_POS + OVERLAP .. FRAME_SAMPLES]
                let prefix = SPLIT_POS - lag;
                out[..prefix].copy_from_slice(&input[..prefix]);
                for i in 0..OVERLAP {
                    let a = input[prefix + i] as i32;
                    let b = input[SPLIT_POS + i] as i32;
                    let w = self.fade_in_q15[i];
                    let mixed = (a * (32768 - w) + b * w + 16384) >> 15;
                    out[prefix + i] = mixed.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                }
                let tail_src = SPLIT_POS + OVERLAP;
                let tail_len = FRAME_SAMPLES - tail_src;
                out[prefix + OVERLAP..prefix + OVERLAP + tail_len]
                    .copy_from_slice(&input[tail_src..]);
                self.stats.accelerated_frames += 1;
                self.stats.samples_removed += lag as u64;
                FRAME_SAMPLES - lag
            }
            WsolaMode::PreemptiveExpand => {
                // Output length = FRAME_SAMPLES + lag:
                // [0 .. SPLIT_POS) copied verbatim from input
                // [SPLIT_POS .. SPLIT_POS + OVERLAP) crossfade:
                //   fade-out input[SPLIT_POS + i] -> fade-in input[SPLIT_POS - lag + i]
                // [SPLIT_POS + OVERLAP .. FRAME_SAMPLES + lag) copied from input[SPLIT_POS - lag + OVERLAP .. FRAME_SAMPLES]
                out[..SPLIT_POS].copy_from_slice(&input[..SPLIT_POS]);
                let back = SPLIT_POS - lag;
                for i in 0..OVERLAP {
                    let a = input[SPLIT_POS + i] as i32;
                    let b = input[back + i] as i32;
                    let w = self.fade_in_q15[i];
                    let mixed = (a * (32768 - w) + b * w + 16384) >> 15;
                    out[SPLIT_POS + i] = mixed.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                }
                let tail_src = back + OVERLAP;
                let tail_len = FRAME_SAMPLES - tail_src;
                out[SPLIT_POS + OVERLAP..SPLIT_POS + OVERLAP + tail_len]
                    .copy_from_slice(&input[tail_src..]);
                self.stats.expanded_frames += 1;
                self.stats.samples_added += lag as u64;
                FRAME_SAMPLES + lag
            }
            WsolaMode::Normal => unreachable!(),
        }
    }
}

fn region_energy(samples: &[i16], start: usize, len: usize) -> u64 {
    let mut e = 0u64;
    for &s in &samples[start..start + len] {
        let v = s as i64;
        e += (v * v) as u64;
    }
    e
}

/// Finds pitch lag in `[MIN_LAG..=MAX_LAG]` maximizing normalized correlation between
/// `input[SPLIT_POS..SPLIT_POS+OVERLAP]` and `input[SPLIT_POS-lag..SPLIT_POS-lag+OVERLAP]`.
/// Returns `(best_lag, normalized_corr_q15)`.
fn find_best_pitch_lag(input: &[i16; FRAME_SAMPLES]) -> (usize, i32) {
    let target = &input[SPLIT_POS..SPLIT_POS + OVERLAP];
    let mut e_target = 0i64;
    for &s in target {
        let v = s as i64;
        e_target += v * v;
    }
    if e_target == 0 {
        return (64, 32768);
    }

    let score_lag = |lag: usize| -> i32 {
        let cand = &input[SPLIT_POS - lag..SPLIT_POS - lag + OVERLAP];
        let mut dot = 0i64;
        let mut e_cand = 0i64;
        // Stride-2 subsampling during coarse search is handled externally; here full 64-sample sum.
        for i in 0..OVERLAP {
            let a = target[i] as i64;
            let b = cand[i] as i64;
            dot += a * b;
            e_cand += b * b;
        }
        if dot <= 0 || e_cand == 0 {
            return 0;
        }
        let denom = ((e_target as f64) * (e_cand as f64)).sqrt();
        if denom <= 1.0 {
            0
        } else {
            ((dot as f64 / denom) * 32768.0).clamp(0.0, 32768.0) as i32
        }
    };

    // Coarse search with stride 2 (55 evaluations).
    let mut best_lag = 64usize;
    let mut best_corr = -1i32;
    let mut lag = MIN_LAG;
    while lag <= MAX_LAG {
        let c = score_lag(lag);
        if c > best_corr {
            best_corr = c;
            best_lag = lag;
        }
        lag += 2;
    }

    // Fine refinement ±2 around best coarse lag.
    let lo = best_lag.saturating_sub(2).max(MIN_LAG);
    let hi = (best_lag + 2).min(MAX_LAG);
    for l in lo..=hi {
        let c = score_lag(l);
        if c > best_corr {
            best_corr = c;
            best_lag = l;
        }
    }

    (best_lag, best_corr.max(0))
}

/// EG25 QDSP6 Tx conditioning:
/// -3.01 dB linear headroom (23170/32768) + C1-continuous quadratic soft-knee limiter
/// starting at -7.1 dBFS output (14481) with asymptotic ceiling ~18826 (-4.8 dBFS).
/// Keeps normal speech bit-clean and completely linear while preventing hard clipping
/// inside Qualcomm QDSP6 `acdb_id=4` voice Tx path.
pub fn condition_uplink_pcm(samples: &mut [i16]) {
    const KNEE: i32 = 14481;
    const SPAN: i32 = 8690;
    for s in samples.iter_mut() {
        let x = *s as i32;
        if x == 0 {
            continue;
        }
        let neg = x < 0;
        let ax = if neg { -x } else { x };
        let mut y = (ax * 23170 + 16384) >> 15;
        if y > KNEE {
            let excess = (y - KNEE).min(SPAN);
            y = KNEE + excess - (excess * excess) / (2 * SPAN);
        }
        *s = (if neg { -y } else { y }) as i16;
    }
}

/// Downsample 16 kHz -> 8 kHz with 3-tap `[1, 2, 1] / 4` anti-aliasing filter (for NB fallback).
pub fn reduce_16k_to_8k(input: &[i16], prev: &mut i16, out: &mut [i16]) -> usize {
    let pairs = input.len() / 2;
    for i in 0..pairs {
        let before = if i == 0 { *prev as i32 } else { input[i * 2 - 1] as i32 };
        let cur = input[i * 2] as i32;
        let next = input[i * 2 + 1] as i32;
        out[i] = ((before + 2 * cur + next) / 4) as i16;
    }
    if let Some(&last) = input.last() {
        *prev = last;
    }
    pairs
}

/// Upsample 8 kHz -> 16 kHz with linear interpolation (for RM500U 8 kHz capture).
pub fn expand_8k_to_16k(input: &[i16], prev: &mut i16, out: &mut [i16]) -> usize {
    let mut p = *prev as i32;
    for (i, &s) in input.iter().enumerate() {
        let x = s as i32;
        out[i * 2] = ((p + x) / 2) as i16;
        out[i * 2 + 1] = s;
        p = x;
    }
    if let Some(&last) = input.last() {
        *prev = last;
    }
    input.len() * 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wsola_preserves_sine_phase_without_clicks() {
        let mut proc = WsolaProcessor::new();
        // 200 Hz sine @ 16 kHz => exact pitch period is 80 samples!
        let mut frame = [0i16; FRAME_SAMPLES];
        for (i, s) in frame.iter_mut().enumerate() {
            let phase = 2.0 * std::f64::consts::PI * 200.0 * (i as f64) / 16000.0;
            *s = (16000.0 * phase.sin()).round() as i16;
        }
        let mut out = [0i16; MAX_WSOLA_OUT];
        let n_acc = proc.process(&frame, WsolaMode::Accelerate, true, &mut out);
        assert_eq!(n_acc, FRAME_SAMPLES - 80, "must lock onto exact 80-sample pitch period");
        // Check zero click (max adjacent sample diff of 200 Hz sine @ 16kHz amp 16000 is ~1256).
        let max_diff = out[..n_acc]
            .windows(2)
            .map(|w| (w[1] as i32 - w[0] as i32).abs())
            .max()
            .unwrap();
        assert!(max_diff < 1400, "click detected on accelerate: max_diff={max_diff}");

        let n_exp = proc.process(&frame, WsolaMode::PreemptiveExpand, true, &mut out);
        assert_eq!(n_exp, FRAME_SAMPLES + 80, "must expand by exact 80-sample pitch period");
        let max_diff_exp = out[..n_exp]
            .windows(2)
            .map(|w| (w[1] as i32 - w[0] as i32).abs())
            .max()
            .unwrap();
        assert!(max_diff_exp < 1400, "click detected on expand: max_diff={max_diff_exp}");
    }

    #[test]
    fn uplink_conditioner_matches_c_math_and_monotonic() {
        let mut samples = [0i16, 1000, 10000, 20480, 28000, 32767, -32768];
        condition_uplink_pcm(&mut samples);
        assert_eq!(samples[0], 0);
        // -3.01 dB linear below knee: 10000 * 23170 / 32768 = 7071
        assert!((samples[2] - 7071).abs() <= 1);
        assert!(samples[5] <= 18827 && samples[5] >= 18820);
        assert!(samples[6] >= -18827 && samples[6] <= -18820);
        // Strictly monotonic for positive inputs
        assert!(samples[1] < samples[2] && samples[2] < samples[3] && samples[3] < samples[4] && samples[4] < samples[5]);
    }
}
