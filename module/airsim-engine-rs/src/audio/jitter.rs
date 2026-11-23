use crate::audio::opus::DecodeKind;
use crate::audio::ring::{IncomingOpusPacket, MAX_OPUS_PACKET};
use crate::audio::wsola::WsolaMode;

/// 128-slot (2.56 s) NetEq-grade media-time adaptive playout jitter buffer (zero heap allocations).
///
/// Key properties (tuned directly from real EG25 QCI=9 4G LTE + TURN call telemetry):
/// - Indexed by 20 ms media slot (`rtp_time_48k / 960`), tolerating arbitrary out-of-order arrivals.
/// - Adapts target depth smoothly from RFC 3550 EWMA jitter + slow-decay burst peak detector:
///   - USB local: floor 40 ms (2 frames), start 40 ms, ceiling 120 ms (6 frames)
///   - Cellular TURN relay: floor 100 ms (5 frames), start 140 ms (7 frames), ceiling 440 ms (22 frames)
/// - NetEq empty-buffer hold: when the buffer runs empty during a 4G LTE RLC burst stall,
///   `play_slot` stays parked on the expected frame instead of racing ahead, so ZERO delayed
///   voice frames are dropped as "late" and LBRR FEC can still recover isolated losses.
/// - Hysteresis-banded pitch-synchronous WSOLA:
///   - `<= target/2`: proactive `PreemptiveExpand` BEFORE starvation
///   - `(target/2 .. target+3)`: untouched 1.0x pass-through
///   - `>= target+3`: gentle `Accelerate` to drain post-burst backlog cleanly (never self-starving!)
/// - Zero sentence-chopping resyncs: hard resync ONLY on true > 1.92 s (96-slot) discontinuity.

const RING_SLOTS: usize = 128;
const RING_MASK: usize = RING_SLOTS - 1;
pub const TICKS_PER_FRAME_48K: u64 = 960;

#[derive(Clone, Copy)]
struct Slot {
    occupied: bool,
    slot_index: u64,
    len: u16,
    data: [u8; MAX_OPUS_PACKET],
}

impl Slot {
    const fn empty() -> Self {
        Self {
            occupied: false,
            slot_index: 0,
            len: 0,
            data: [0u8; MAX_OPUS_PACKET],
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct JitterStats {
    pub packets_received: u64,
    pub packets_late: u64,
    pub duplicate_packets: u64,
    pub invalid_packets: u64,
    pub queue_drops: u64,
    pub fec_frames: u64,
    pub plc_frames: u64,
    pub playout_resyncs: u64,
    pub target_delay_ms: u32,
    pub jitter_ms: u32,
}

pub struct PlayoutFrame {
    pub kind: DecodeKind,
    pub data: [u8; MAX_OPUS_PACKET],
    pub len: usize,
    pub wsola_mode: WsolaMode,
    pub wsola_force: bool,
}

pub struct AdaptiveJitterBuffer {
    relayed: bool,
    min_target_slots: u64,
    max_target_slots: u64,
    target_slots: u64,

    slots: [Slot; RING_SLOTS],
    started: bool,
    buffering: bool,
    first_rx_ms: u64,
    play_slot: u64,
    max_seen_slot: u64,
    last_played_real_slot: Option<u64>,
    consecutive_plc: u32,
    consecutive_late: u32,

    // RFC 3550 inter-arrival jitter estimator (ms * 16 fixed point)
    has_prev_transit: bool,
    prev_transit_ms: i64,
    jitter_q4: u64,
    peak_jitter_ms: u64,
    peak_decay_tick: u8,
    quiet_frames: u32,

    pub stats: JitterStats,
}

impl AdaptiveJitterBuffer {
    pub fn new(relayed: bool) -> Self {
        let (min_s, start_s, max_s) = if relayed { (5, 7, 22) } else { (2, 2, 6) };
        let mut s = Self {
            relayed,
            min_target_slots: min_s,
            max_target_slots: max_s,
            target_slots: start_s,
            slots: [Slot::empty(); RING_SLOTS],
            started: false,
            buffering: true,
            first_rx_ms: 0,
            play_slot: 0,
            max_seen_slot: 0,
            last_played_real_slot: None,
            consecutive_plc: 0,
            consecutive_late: 0,
            has_prev_transit: false,
            prev_transit_ms: 0,
            jitter_q4: 0,
            peak_jitter_ms: 0,
            peak_decay_tick: 0,
            quiet_frames: 0,
            stats: JitterStats::default(),
        };
        s.stats.target_delay_ms = (start_s * 20) as u32;
        s
    }

    pub fn clear(&mut self) {
        for s in &mut self.slots {
            s.occupied = false;
        }
        self.started = false;
        self.buffering = true;
        self.last_played_real_slot = None;
        self.consecutive_plc = 0;
        self.consecutive_late = 0;
        self.has_prev_transit = false;
        self.jitter_q4 = 0;
        self.peak_jitter_ms = 0;
        self.peak_decay_tick = 0;
        self.quiet_frames = 0;
        self.target_slots = if self.relayed { 7 } else { 2 };
        self.stats.target_delay_ms = (self.target_slots * 20) as u32;
    }

    pub fn push(&mut self, pkt: &IncomingOpusPacket) {
        let len = pkt.len as usize;
        if len == 0 || len > MAX_OPUS_PACKET {
            self.stats.invalid_packets += 1;
            return;
        }
        self.stats.packets_received += 1;

        // Quantize 48 kHz media time to 20 ms slot index (960 ticks/frame).
        let slot_idx = (pkt.rtp_time_48k + TICKS_PER_FRAME_48K / 2) / TICKS_PER_FRAME_48K;

        // Update RFC 3550 jitter estimate.
        let media_ms = (slot_idx * 20) as i64;
        let transit = pkt.rx_at_ms as i64 - media_ms;
        if self.has_prev_transit {
            let d = (transit - self.prev_transit_ms).unsigned_abs().min(600);
            // J = J + (|D| - J) / 16
            let d_q4 = d << 4;
            if d_q4 >= self.jitter_q4 {
                self.jitter_q4 += (d_q4 - self.jitter_q4) >> 4;
            } else {
                self.jitter_q4 -= (self.jitter_q4 - d_q4) >> 4;
            }
            if d > self.peak_jitter_ms {
                self.peak_jitter_ms = d;
                self.peak_decay_tick = 0;
            } else {
                // Slow NetEq-like burst memory decay (~6.25 ms/sec at 50 fps) so 4G LTE
                // cushion holds steady across recurring 200-400 ms RLC bursts.
                self.peak_decay_tick = self.peak_decay_tick.wrapping_add(1);
                if self.peak_decay_tick >= 8 {
                    self.peak_decay_tick = 0;
                    self.peak_jitter_ms = self.peak_jitter_ms.saturating_sub(1);
                }
            }
        }
        self.prev_transit_ms = transit;
        self.has_prev_transit = true;

        self.recompute_target();

        if !self.started {
            self.started = true;
            self.buffering = true;
            self.first_rx_ms = pkt.rx_at_ms;
            self.play_slot = slot_idx;
            self.max_seen_slot = slot_idx;
            self.insert_slot(slot_idx, pkt.as_slice());
            return;
        }

        // Only hard-resync on a true multi-second stream discontinuity (> 1.92 s = 96 slots),
        // NEVER on normal RTP marker bits or 200-650 ms 4G LTE RLC bursts!
        let huge_jump = slot_idx > self.play_slot.saturating_add(96)
            || slot_idx.saturating_add(96) < self.play_slot;

        if huge_jump {
            for s in &mut self.slots {
                s.occupied = false;
            }
            self.play_slot = slot_idx;
            self.max_seen_slot = slot_idx;
            self.buffering = true;
            self.first_rx_ms = pkt.rx_at_ms;
            self.consecutive_plc = 0;
            self.consecutive_late = 0;
            self.stats.playout_resyncs += 1;
            self.insert_slot(slot_idx, pkt.as_slice());
            return;
        }

        // If we were stalled in PLC (buffer empty) and a fresh packet arrives that is newer than
        // the last real frame we actually played, re-anchor play_slot to it cleanly so ZERO frames
        // are discarded as "late".
        let newer_than_played = self
            .last_played_real_slot
            .map(|last| slot_idx > last)
            .unwrap_or(true);
        if slot_idx < self.play_slot && self.consecutive_plc >= 1 && self.buffered_slots() == 0 && newer_than_played {
            self.play_slot = slot_idx;
            self.max_seen_slot = slot_idx;
            self.consecutive_late = 0;
            self.insert_slot(slot_idx, pkt.as_slice());
            return;
        }

        if slot_idx < self.play_slot {
            self.stats.packets_late += 1;
            self.consecutive_late += 1;
            if self.consecutive_late >= 3 && self.buffered_slots() == 0 && newer_than_played {
                self.play_slot = slot_idx;
                self.max_seen_slot = slot_idx;
                self.consecutive_late = 0;
                self.insert_slot(slot_idx, pkt.as_slice());
            }
            return;
        }
        self.consecutive_late = 0;

        if slot_idx > self.max_seen_slot {
            self.max_seen_slot = slot_idx;
        }

        // If the 128-slot ring would wrap over `play_slot`, advance `play_slot` only as last resort (> 2.4 s lag).
        while slot_idx >= self.play_slot + (RING_SLOTS as u64 - 4) {
            let old = &mut self.slots[(self.play_slot as usize) & RING_MASK];
            if old.occupied && old.slot_index == self.play_slot {
                old.occupied = false;
                self.stats.queue_drops += 1;
            }
            self.play_slot += 1;
        }

        let pos = (slot_idx as usize) & RING_MASK;
        if self.slots[pos].occupied && self.slots[pos].slot_index == slot_idx {
            self.stats.duplicate_packets += 1;
            return;
        }
        self.insert_slot(slot_idx, pkt.as_slice());
    }

    fn insert_slot(&mut self, slot_idx: u64, data: &[u8]) {
        let pos = (slot_idx as usize) & RING_MASK;
        let slot = &mut self.slots[pos];
        slot.occupied = true;
        slot.slot_index = slot_idx;
        slot.len = data.len() as u16;
        slot.data[..data.len()].copy_from_slice(data);
    }

    fn recompute_target(&mut self) {
        let jitter_ms = self.jitter_q4 >> 4;
        // NetEq-style cushion: 2 * EWMA jitter + 0.75 * slow-decay burst peak + 40 ms base
        // (USB uses lighter 20 ms base).
        let base_ms = if self.relayed { 40 } else { 20 };
        let desired_ms = jitter_ms * 2 + (self.peak_jitter_ms * 3) / 4 + base_ms;
        let desired_slots = ((desired_ms + 19) / 20).clamp(self.min_target_slots, self.max_target_slots);
        if desired_slots > self.target_slots {
            // React quickly upward when LTE jitter rises.
            self.target_slots = desired_slots;
            self.quiet_frames = 0;
        } else if desired_slots < self.target_slots {
            // Decay downward slowly (1 slot per ~4 s of calm network) so we don't oscillate.
            self.quiet_frames += 1;
            if self.quiet_frames >= 200 {
                self.target_slots -= 1;
                self.quiet_frames = 0;
            }
        } else {
            self.quiet_frames = 0;
        }
        self.stats.jitter_ms = jitter_ms as u32;
        self.stats.target_delay_ms = (self.target_slots * 20) as u32;
    }

    /// Number of occupied slots currently buffered at or ahead of `play_slot`.
    pub fn buffered_slots(&self) -> u64 {
        if !self.started {
            return 0;
        }
        let mut count = 0u64;
        let span = self.max_seen_slot.saturating_sub(self.play_slot).min(RING_SLOTS as u64 - 1);
        for offset in 0..=span {
            let idx = self.play_slot + offset;
            let s = &self.slots[(idx as usize) & RING_MASK];
            if s.occupied && s.slot_index == idx {
                count += 1;
            }
        }
        count
    }

    /// Span from `play_slot` to highest seen slot (in frames).
    pub fn lead_slots(&self) -> u64 {
        if !self.started || self.max_seen_slot < self.play_slot {
            0
        } else {
            self.max_seen_slot - self.play_slot + 1
        }
    }

    /// Pull the next frame for playout.
    /// `now_ms`: monotonic ms; `alsa_delay_ms`: current ALSA hardware queue delay (from `pcm_get_delay`).
    /// Returns `None` during initial pre-buffering (caller may wait/send silence without counting PLC).
    pub fn pop(&mut self, now_ms: u64, alsa_delay_ms: u32) -> Option<PlayoutFrame> {
        if !self.started {
            return None;
        }
        if self.buffering {
            let boot_slots = self.target_slots.min(7);
            let ready = self.lead_slots() >= boot_slots
                || now_ms.saturating_sub(self.first_rx_ms) >= (boot_slots * 20).max(60);
            if !ready {
                return None;
            }
            self.buffering = false;
        }

        let cur = self.play_slot;
        let pos = (cur as usize) & RING_MASK;
        let mut frame = PlayoutFrame {
            kind: DecodeKind::Erasure,
            data: [0u8; MAX_OPUS_PACKET],
            len: 0,
            wsola_mode: WsolaMode::Normal,
            wsola_force: false,
        };

        if self.slots[pos].occupied && self.slots[pos].slot_index == cur {
            let len = self.slots[pos].len as usize;
            frame.data[..len].copy_from_slice(&self.slots[pos].data[..len]);
            frame.len = len;
            frame.kind = DecodeKind::Packet;
            self.slots[pos].occupied = false;
            self.play_slot += 1;
            self.last_played_real_slot = Some(cur);
            self.consecutive_plc = 0;
        } else {
            // Check next slot (`cur + 1`) for Opus in-band LBRR FEC recovery!
            let next_idx = cur + 1;
            let next_pos = (next_idx as usize) & RING_MASK;
            if self.slots[next_pos].occupied && self.slots[next_pos].slot_index == next_idx {
                let len = self.slots[next_pos].len as usize;
                frame.data[..len].copy_from_slice(&self.slots[next_pos].data[..len]);
                frame.len = len;
                frame.kind = DecodeKind::Fec;
                self.play_slot += 1;
                self.stats.fec_frames += 1;
                self.last_played_real_slot = Some(cur);
                self.consecutive_plc = 0;
            } else {
                frame.kind = DecodeKind::Erasure;
                self.stats.plc_frames += 1;
                self.consecutive_plc = self.consecutive_plc.saturating_add(1);
                // NetEq empty-buffer hold:
                // - If future packets are ALREADY waiting in the buffer (`buffered_slots() > 0`),
                //   `cur` is a real lost hole -> advance `play_slot` so we move cleanly into them!
                // - If the buffer is completely empty (`buffered_slots() == 0`), we are waiting on
                //   a delayed 4G LTE burst -> keep `play_slot` parked on `cur` so when the burst
                //   arrives, ZERO delayed voice frames are dropped as "late"!
                if self.buffered_slots() > 0 {
                    self.play_slot += 1;
                }
            }
        }

        // Hysteresis-banded WSOLA driven strictly by jitter occupancy (never self-starving on normal
        // EG25 32-56 ms ALSA DMA delay!).
        if frame.kind == DecodeKind::Packet {
            let remaining = self.lead_slots();
            let high_water = self.target_slots + 3;
            let emergency_water = self.target_slots + 8;
            let low_water = (self.target_slots / 2).max(2);
            if remaining >= emergency_water || (remaining >= self.target_slots && alsa_delay_ms >= 96) {
                frame.wsola_mode = WsolaMode::Accelerate;
                frame.wsola_force = true;
            } else if remaining >= high_water {
                frame.wsola_mode = WsolaMode::Accelerate;
                frame.wsola_force = false;
            } else if remaining <= low_water && alsa_delay_ms <= 52 {
                // Proactively stretch voiced frames by 4-7 ms BEFORE the buffer runs dry!
                frame.wsola_mode = WsolaMode::PreemptiveExpand;
                frame.wsola_force = false;
            }
        }

        Some(frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_pkt(slot: u64, rx_ms: u64) -> IncomingOpusPacket {
        let mut p = IncomingOpusPacket {
            bytes: [0u8; MAX_OPUS_PACKET],
            len: 40,
            rtp_time_48k: slot * TICKS_PER_FRAME_48K,
            rx_at_ms: rx_ms,
            start_of_talkspurt: false,
        };
        p.bytes[0] = (slot & 0xff) as u8;
        p
    }

    #[test]
    fn absorbs_lte_burst_via_wsola_without_drops_or_resyncs() {
        let mut jb = AdaptiveJitterBuffer::new(true);
        // Feed 7 initial frames cleanly (140 ms cellular start target)
        for i in 0..7u64 {
            jb.push(&mk_pkt(i, i * 20));
        }
        // Pull frame 0 -> normal
        let f0 = jb.pop(140, 36).unwrap();
        assert_eq!(f0.kind, DecodeKind::Packet);
        assert_eq!(f0.wsola_mode, WsolaMode::Normal);

        // Simulate LTE 260 ms stall then 15-packet burst arriving together!
        for i in 7..22u64 {
            jb.push(&mk_pkt(i, 400));
        }
        // Pull next frames -> should engage WSOLA Accelerate smoothly, ZERO drops, ZERO resyncs!
        let mut accel_count = 0;
        for step in 0..15 {
            if let Some(f) = jb.pop(400 + step * 20, 40) {
                if f.wsola_mode == WsolaMode::Accelerate {
                    accel_count += 1;
                }
            }
        }
        assert!(accel_count > 0, "expected WSOLA Accelerate to drain burst");
        assert_eq!(jb.stats.queue_drops, 0);
        assert_eq!(jb.stats.playout_resyncs, 0);
        assert_eq!(jb.stats.packets_late, 0);
    }

    #[test]
    fn uses_lbrr_fec_on_single_missing_slot() {
        let mut jb = AdaptiveJitterBuffer::new(false);
        jb.push(&mk_pkt(0, 0));
        // slot 1 missing!
        jb.push(&mk_pkt(2, 40));
        jb.push(&mk_pkt(3, 60));

        let f0 = jb.pop(60, 32).unwrap();
        assert_eq!(f0.kind, DecodeKind::Packet);
        let f1 = jb.pop(80, 32).unwrap();
        assert_eq!(f1.kind, DecodeKind::Fec);
        assert_eq!(jb.stats.fec_frames, 1);
        assert_eq!(jb.stats.plc_frames, 0);
        let f2 = jb.pop(100, 32).unwrap();
        assert_eq!(f2.kind, DecodeKind::Packet);
    }
}
