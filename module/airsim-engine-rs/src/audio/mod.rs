pub mod alsa;
pub mod jitter;
pub mod opus;
pub mod ring;
pub mod wsola;

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use self::alsa::{open_audio_backends, set_realtime_priority, AudioProfile};
use self::jitter::AdaptiveJitterBuffer;
use self::opus::{OpusDecoder, OpusEncoder, OPUS_FRAME_SAMPLES};
use self::ring::{EncodedAudioPacket, IncomingOpusPacket, SpscRing, MAX_OPUS_PACKET};
use self::wsola::{WsolaMode, WsolaProcessor, MAX_WSOLA_OUT};

/// Shared lock-free media telemetry updated by the real-time audio & WebRTC threads.
#[derive(Default)]
pub struct AudioEngineCounters {
    pub packets_received: AtomicU64,
    pub packets_sent: AtomicU64,
    pub packets_lost: AtomicU64,
    pub packets_late: AtomicU64,
    pub fec_frames: AtomicU64,
    pub plc_frames: AtomicU64,
    pub queue_drops: AtomicU64,
    pub local_input_gaps: AtomicU64,
    pub red_recovered_frames: AtomicU64,
    pub invalid_audio_packets: AtomicU64,
    pub duplicate_audio_packets: AtomicU64,
    pub playout_resyncs: AtomicU64,
    pub local_stalls: AtomicU64,
    pub local_stall_max_ms: AtomicU64,
    pub send_stalls: AtomicU64,
    pub send_stall_max_ms: AtomicU64,
    pub rtp_stalls: AtomicU64,
    pub rtp_stall_max_ms: AtomicU64,
    pub playout_stalls: AtomicU64,
    pub playout_stall_max_ms: AtomicU64,
    pub wsola_accelerated: AtomicU64,
    pub wsola_expanded: AtomicU64,
    pub jitter_target_ms: AtomicU64,
    pub capture_xruns: AtomicU64,
    pub playback_xruns: AtomicU64,
    pub synthetic_decoded_non_zero: AtomicU64,
}

impl AudioEngineCounters {
    pub fn record_stall(count: &AtomicU64, max: &AtomicU64, elapsed_ms: u64, threshold_ms: u64) {
        if elapsed_ms > threshold_ms {
            count.fetch_add(1, Ordering::Relaxed);
            max.fetch_max(elapsed_ms, Ordering::Relaxed);
        }
    }
}

/// Cross-platform wakeup pipe/eventfd so the Capture RT thread immediately wakes the
/// WebRTC `poll()` loop in sub-millisecond latency without busy-spinning.
pub struct WakeupSignal {
    read_fd: i32,
    write_fd: i32,
}

impl WakeupSignal {
    pub fn new() -> std::io::Result<Self> {
        #[cfg(target_os = "linux")]
        unsafe {
            let fd = libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC);
            if fd < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(Self {
                read_fd: fd,
                write_fd: fd,
            })
        }
        #[cfg(not(target_os = "linux"))]
        unsafe {
            let mut fds = [0i32; 2];
            if libc::pipe(fds.as_mut_ptr()) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            for fd in fds {
                let fl = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                let cl = libc::fcntl(fd, libc::F_GETFD);
                libc::fcntl(fd, libc::F_SETFD, cl | libc::FD_CLOEXEC);
            }
            Ok(Self {
                read_fd: fds[0],
                write_fd: fds[1],
            })
        }
    }

    pub fn poll_fd(&self) -> i32 {
        self.read_fd
    }

    pub fn notify(&self) {
        #[cfg(target_os = "linux")]
        unsafe {
            let v: u64 = 1;
            let _ = libc::write(self.write_fd, &v as *const u64 as *const libc::c_void, 8);
        }
        #[cfg(not(target_os = "linux"))]
        unsafe {
            let b: u8 = 1;
            let _ = libc::write(self.write_fd, &b as *const u8 as *const libc::c_void, 1);
        }
    }

    pub fn drain(&self) {
        #[cfg(target_os = "linux")]
        unsafe {
            let mut v: u64 = 0;
            let _ = libc::read(self.read_fd, &mut v as *mut u64 as *mut libc::c_void, 8);
        }
        #[cfg(not(target_os = "linux"))]
        unsafe {
            let mut buf = [0u8; 64];
            while libc::read(self.read_fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) > 0 {}
        }
    }
}

impl Drop for WakeupSignal {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.read_fd);
            if self.write_fd != self.read_fd {
                libc::close(self.write_fd);
            }
        }
    }
}

/// Manages the two dedicated real-time `SCHED_FIFO` audio worker threads
/// (Capture+OpusEncode and Jitter+OpusDecode+WSOLA+Playback) connected via lock-free SPSC rings.
pub struct RealtimeAudioPipelines {
    stop: Arc<AtomicBool>,
    capture_thread: Option<std::thread::JoinHandle<Result<(), &'static str>>>,
    playback_thread: Option<std::thread::JoinHandle<Result<(), &'static str>>>,
    _route_guard: alsa::RouteGuard,
}

impl RealtimeAudioPipelines {
    pub fn start(
        profile: AudioProfile,
        relayed: bool,
        tx_ring: Arc<SpscRing<EncodedAudioPacket, 32>>,
        rx_ring: Arc<SpscRing<IncomingOpusPacket, 64>>,
        tx_wakeup: Arc<WakeupSignal>,
        counters: Arc<AudioEngineCounters>,
        stop: Arc<AtomicBool>,
    ) -> Result<Self, &'static str> {
        let (mut cap_backend, mut pb_backend, route_guard) = open_audio_backends(profile)?;
        let cap_stop = stop.clone();
        let cap_counters = counters.clone();

        let cap_builder = std::thread::Builder::new()
            .name("airsim-cap".into())
            .stack_size(512 * 1024);
        let capture_thread = cap_builder
            .spawn(move || -> Result<(), &'static str> {
                set_realtime_priority(10);
                let mut encoder = OpusEncoder::new()?;
                let mut pcm = [0i16; OPUS_FRAME_SAMPLES];
                let mut prev_8k = 0i16;
                let mut seq = 0u64;
                let mut last_frame = Instant::now();
                let mut first = true;

                while !cap_stop.load(Ordering::Relaxed) {
                    seq += 1;
                    let xrun = cap_backend.read_frame_16k(&mut pcm, &mut prev_8k, &cap_stop)?;
                    cap_counters
                        .capture_xruns
                        .store(cap_backend.xruns(), Ordering::Relaxed);
                    let now = Instant::now();
                    if !first {
                        let dt = now.duration_since(last_frame).as_millis() as u64;
                        AudioEngineCounters::record_stall(
                            &cap_counters.local_stalls,
                            &cap_counters.local_stall_max_ms,
                            dt,
                            60,
                        );
                    }
                    last_frame = now;

                    if xrun {
                        cap_counters.local_input_gaps.fetch_add(1, Ordering::Relaxed);
                        continue;
                    }

                    let mut pkt = EncodedAudioPacket {
                        bytes: [0u8; MAX_OPUS_PACKET],
                        len: 0,
                        seq,
                        start_of_talkspurt: first,
                    };
                    let n = encoder.encode(&pcm, &mut pkt.bytes)?;
                    pkt.len = n as u16;
                    first = false;

                    if tx_ring.push(pkt).is_err() {
                        // Drop oldest and push fresh so latency never builds up.
                        let _ = tx_ring.pop();
                        let _ = tx_ring.push(pkt);
                        cap_counters.queue_drops.fetch_add(1, Ordering::Relaxed);
                    }
                    tx_wakeup.notify();
                }
                Ok(())
            })
            .map_err(|_| "thread_start")?;

        let pb_stop = stop.clone();
        let pb_counters = counters.clone();
        let pb_builder = std::thread::Builder::new()
            .name("airsim-pb".into())
            .stack_size(512 * 1024);
        let playback_thread = pb_builder
            .spawn(move || -> Result<(), &'static str> {
                set_realtime_priority(10);
                let mut decoder = OpusDecoder::new()?;
                let mut jb = AdaptiveJitterBuffer::new(relayed);
                let mut wsola = WsolaProcessor::new();
                let mut decoded = [0i16; OPUS_FRAME_SAMPLES];
                let mut wsola_out = [0i16; MAX_WSOLA_OUT];
                let mut prev_16k = 0i16;
                let origin = Instant::now();
                let mut last_play = Instant::now();
                let mut played_any = false;

                while !pb_stop.load(Ordering::Relaxed) {
                    // Drain all arrived Opus packets from WebRTC I/O thread into adaptive jitter buffer.
                    while let Some(in_pkt) = rx_ring.pop() {
                        jb.push(&in_pkt);
                    }

                    pb_backend.wait_headroom(&pb_stop)?;

                    // Drain again right after headroom wait in case a packet just arrived!
                    while let Some(in_pkt) = rx_ring.pop() {
                        jb.push(&in_pkt);
                    }

                    let now_ms = origin.elapsed().as_millis() as u64;
                    let alsa_delay = pb_backend.delay_ms();

                    let (out_len, mode_used) = if let Some(frame) = jb.pop(now_ms, alsa_delay) {
                        let pkt_slice = if frame.len > 0 {
                            Some(&frame.data[..frame.len])
                        } else {
                            None
                        };
                        let _ = decoder.decode(pkt_slice, frame.kind, &mut decoded)?;
                        let n = wsola.process(&decoded, frame.wsola_mode, frame.wsola_force, &mut wsola_out);
                        (n, frame.wsola_mode)
                    } else {
                        // Still pre-buffering initial jitter cushion: write silent 20 ms frame cleanly.
                        wsola_out[..OPUS_FRAME_SAMPLES].fill(0);
                        // Avoid spinning before first audio packet arrives in synthetic mode.
                        if profile == AudioProfile::MockLoopback {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                        (OPUS_FRAME_SAMPLES, WsolaMode::Normal)
                    };
                    let _ = mode_used;

                    let xrun = pb_backend.write_samples_16k(
                        &wsola_out[..out_len],
                        profile,
                        &mut prev_16k,
                        &pb_stop,
                    )?;
                    if xrun {
                        prev_16k = 0;
                    }

                    let now = Instant::now();
                    if played_any {
                        let dt = now.duration_since(last_play).as_millis() as u64;
                        AudioEngineCounters::record_stall(
                            &pb_counters.playout_stalls,
                            &pb_counters.playout_stall_max_ms,
                            dt,
                            60,
                        );
                    }
                    last_play = now;
                    played_any = true;

                    // Export lock-free stats snapshot.
                    pb_counters.packets_received.store(jb.stats.packets_received, Ordering::Relaxed);
                    pb_counters.packets_late.store(jb.stats.packets_late, Ordering::Relaxed);
                    pb_counters.duplicate_audio_packets.store(jb.stats.duplicate_packets, Ordering::Relaxed);
                    pb_counters.invalid_audio_packets.store(jb.stats.invalid_packets, Ordering::Relaxed);
                    pb_counters.fec_frames.store(jb.stats.fec_frames, Ordering::Relaxed);
                    pb_counters.plc_frames.store(jb.stats.plc_frames, Ordering::Relaxed);
                    pb_counters.playout_resyncs.store(jb.stats.playout_resyncs, Ordering::Relaxed);
                    pb_counters.wsola_accelerated.store(wsola.stats.accelerated_frames, Ordering::Relaxed);
                    pb_counters.wsola_expanded.store(wsola.stats.expanded_frames, Ordering::Relaxed);
                    pb_counters.jitter_target_ms.store(jb.stats.target_delay_ms as u64, Ordering::Relaxed);
                    pb_counters.playback_xruns.store(pb_backend.xruns(), Ordering::Relaxed);
                    if profile == AudioProfile::MockLoopback {
                        pb_counters
                            .synthetic_decoded_non_zero
                            .store(pb_backend.synthetic_non_zero_samples(), Ordering::Relaxed);
                    }
                }
                Ok(())
            })
            .map_err(|_| "thread_start")?;

        Ok(Self {
            stop,
            capture_thread: Some(capture_thread),
            playback_thread: Some(playback_thread),
            _route_guard: route_guard,
        })
    }

    pub fn stop_and_join(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.capture_thread.take() {
            let _ = h.join();
        }
        if let Some(h) = self.playback_thread.take() {
            let _ = h.join();
        }
    }
}

impl Drop for RealtimeAudioPipelines {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}
