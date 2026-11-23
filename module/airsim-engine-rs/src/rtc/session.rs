//! Dedicated `SCHED_FIFO` WebRTC + TURN real-time I/O session driving `str0m 0.26`.
//!
//! Architecture:
//! - Runs on its own OS thread with `SCHED_FIFO` priority 10 (no Tokio scheduler jitter, no GC).
//! - Multiplexes UDP direct socket OR TURN UDP/TCP socket + `WakeupSignal` (eventfd/pipe)
//!   inside a single `libc::poll()` loop driven by `str0m`'s exact `Output::Timeout` deadline.
//! - Native RFC 2198 RED depth=2 (`set_red_distances(&[1, 2])`) on Opus 48000/2.
//! - Zero reordering delay inside `str0m` (`set_reordering_size_audio(0)`): incoming Opus frames
//!   (including RED-recovered frames) flow straight into lock-free `rx_ring` -> `AdaptiveJitterBuffer`
//!   + Pitch-Synchronous WSOLA + ALSA `pcm5p`.
//! - Outgoing Opus frames from ALSA `pcm6c` -> `OpusEncoder` -> lock-free `tx_ring` wake `poll()`
//!   immediately via `eventfd` and go out over SRTP in sub-millisecond latency.

use crate::audio::alsa::{set_realtime_priority, AudioProfile};
use crate::audio::ring::{EncodedAudioPacket, IncomingOpusPacket, SpscRing, MAX_OPUS_PACKET};
use crate::audio::{AudioEngineCounters, RealtimeAudioPipelines, WakeupSignal};
use crate::rtc::turn::{parse_turn_url, TurnClient, TurnTransport};
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};
use str0m::change::SdpOffer;
use str0m::format::Codec;
use str0m::media::{MediaTime, Mid, Pt};
use str0m::net::{Protocol, Receive};
use str0m::{Candidate, Event, IceConnectionState, Input, Output, Rtc, RtcConfig};

const OPUS_FMTP: &str = "minptime=10;useinbandfec=1;stereo=0;sprop-stereo=0;maxplaybackrate=16000;sprop-maxcapturerate=16000;maxaveragebitrate=64000";
const RTP_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
const ICE_SETUP_TIMEOUT: Duration = Duration::from_secs(18);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
}

#[derive(Debug, Clone)]
pub struct MediaSessionConfig {
    pub session_id: String,
    pub offer_sdp: String,
    pub ice_servers: Vec<IceServer>,
    pub local_ip: Option<Ipv4Addr>,
    pub gather_timeout: Duration,
    pub audio_profile: AudioProfile,
    pub max_duration: Duration,
}

#[derive(Debug, Clone, Serialize)]
pub struct MediaSessionStatus {
    pub session_id: String,
    pub state: String,
    pub reason: String,
    pub candidate: String,
    pub packets_received: u64,
    pub packets_sent: u64,
    pub packets_lost: u64,
    pub packets_late: u64,
    pub fec_frames: u64,
    pub plc_frames: u64,
    pub queue_drops: u64,
    pub local_input_gaps: u64,
    pub red_recovered_frames: u64,
    pub invalid_audio_packets: u64,
    pub duplicate_audio_packets: u64,
    pub playout_resyncs: u64,
    pub local_stalls: u64,
    pub local_stall_max_ms: i64,
    pub send_stalls: u64,
    pub send_stall_max_ms: i64,
    pub rtp_stalls: u64,
    pub rtp_stall_max_ms: i64,
    pub playout_stalls: u64,
    pub playout_stall_max_ms: i64,
    pub gc_cycles: u64,
    pub heap_live_kb: u64,
    pub wsola_accelerated: u64,
    pub wsola_expanded: u64,
    pub jitter_target_ms: u64,
    pub capture_xruns: u64,
    pub playback_xruns: u64,
}

impl MediaSessionStatus {
    pub fn from_counters(
        session_id: &str,
        state: &str,
        reason: &str,
        candidate: &str,
        c: &AudioEngineCounters,
    ) -> Self {
        Self {
            session_id: session_id.to_string(),
            state: state.to_string(),
            reason: reason.to_string(),
            candidate: candidate.to_string(),
            packets_received: c.packets_received.load(Ordering::Relaxed),
            packets_sent: c.packets_sent.load(Ordering::Relaxed),
            packets_lost: c.packets_lost.load(Ordering::Relaxed),
            packets_late: c.packets_late.load(Ordering::Relaxed),
            fec_frames: c.fec_frames.load(Ordering::Relaxed),
            plc_frames: c.plc_frames.load(Ordering::Relaxed),
            queue_drops: c.queue_drops.load(Ordering::Relaxed),
            local_input_gaps: c.local_input_gaps.load(Ordering::Relaxed),
            red_recovered_frames: c.red_recovered_frames.load(Ordering::Relaxed),
            invalid_audio_packets: c.invalid_audio_packets.load(Ordering::Relaxed),
            duplicate_audio_packets: c.duplicate_audio_packets.load(Ordering::Relaxed),
            playout_resyncs: c.playout_resyncs.load(Ordering::Relaxed),
            local_stalls: c.local_stalls.load(Ordering::Relaxed),
            local_stall_max_ms: c.local_stall_max_ms.load(Ordering::Relaxed) as i64,
            send_stalls: c.send_stalls.load(Ordering::Relaxed),
            send_stall_max_ms: c.send_stall_max_ms.load(Ordering::Relaxed) as i64,
            rtp_stalls: c.rtp_stalls.load(Ordering::Relaxed),
            rtp_stall_max_ms: c.rtp_stall_max_ms.load(Ordering::Relaxed) as i64,
            playout_stalls: c.playout_stalls.load(Ordering::Relaxed),
            playout_stall_max_ms: c.playout_stall_max_ms.load(Ordering::Relaxed) as i64,
            gc_cycles: 0, // Zero GC in Rust!
            heap_live_kb: read_rss_kb(),
            wsola_accelerated: c.wsola_accelerated.load(Ordering::Relaxed),
            wsola_expanded: c.wsola_expanded.load(Ordering::Relaxed),
            jitter_target_ms: c.jitter_target_ms.load(Ordering::Relaxed),
            capture_xruns: c.capture_xruns.load(Ordering::Relaxed),
            playback_xruns: c.playback_xruns.load(Ordering::Relaxed),
        }
    }
}

fn read_rss_kb() -> u64 {
    #[cfg(target_os = "linux")]
    {
        if let Ok(s) = std::fs::read_to_string("/proc/self/statm") {
            let pages = s.split_whitespace().nth(1).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            return pages * 4;
        }
    }
    0
}

enum Transport {
    DirectUdp {
        sock: UdpSocket,
        local_addr: SocketAddr,
    },
    TurnRelay {
        client: TurnClient,
    },
}

impl Transport {
    fn raw_fd(&self) -> i32 {
        match self {
            Self::DirectUdp { sock, .. } => sock.as_raw_fd(),
            Self::TurnRelay { client } => client.raw_fd(),
        }
    }

    /// Address matching the local candidate added to `str0m` (`Receive::destination`).
    fn candidate_addr(&self) -> SocketAddr {
        match self {
            Self::DirectUdp { local_addr, .. } => *local_addr,
            Self::TurnRelay { client } => client.relayed_addr(),
        }
    }

    fn candidate_kind_label(&self) -> &'static str {
        match self {
            Self::DirectUdp { .. } => "host",
            Self::TurnRelay { client } => {
                if client.is_tcp() {
                    "relay-tcp"
                } else {
                    "relay"
                }
            }
        }
    }

    fn send(&mut self, dest: SocketAddr, payload: &[u8]) {
        match self {
            Self::DirectUdp { sock, .. } => {
                let _ = sock.send_to(payload, dest);
            }
            Self::TurnRelay { client } => {
                let _ = client.send_to_peer(dest, payload);
            }
        }
    }

    fn recv_all(&mut self, out: &mut Vec<(SocketAddr, Vec<u8>)>) -> std::io::Result<()> {
        match self {
            Self::DirectUdp { sock, .. } => {
                let mut buf = [0u8; 2048];
                loop {
                    match sock.recv_from(&mut buf) {
                        Ok((n, src)) => out.push((src, buf[..n].to_vec())),
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
                        Err(e)
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::Interrupted
                                    | std::io::ErrorKind::ConnectionRefused
                                    | std::io::ErrorKind::ConnectionReset
                            ) =>
                        {
                            continue;
                        }
                        Err(e) => return Err(e),
                    }
                }
            }
            Self::TurnRelay { client } => client.recv_packets(out),
        }
    }

    fn handle_timeout(&mut self, now: Instant) {
        if let Self::TurnRelay { client } = self {
            client.handle_timeout(now);
        }
    }
}

/// Enrich `str0m`'s generated SDP answer:
/// 1. When both RED (`red/48000`) and Opus (`opus/48000`) are negotiated, put RED first on the
///    `m=audio` payload list so iOS libwebrtc transmits RFC 2198 RED depth=2 packets!
/// 2. Set `a=fmtp:<opus_pt>` to wideband mono 64 kbps with in-band FEC (`OPUS_FMTP`) + `a=ptime:20`.
pub fn enhance_answer_sdp(sdp: &str) -> String {
    let mut opus_pt: Option<String> = None;
    let mut red_pt: Option<String> = None;
    for line in sdp.split("\r\n") {
        if let Some(rest) = line.strip_prefix("a=rtpmap:") {
            let mut parts = rest.split_whitespace();
            if let (Some(pt), Some(codec)) = (parts.next(), parts.next()) {
                let lc = codec.to_ascii_lowercase();
                if lc.starts_with("opus/48000") && opus_pt.is_none() {
                    opus_pt = Some(pt.to_string());
                } else if lc.starts_with("red/48000") && red_pt.is_none() {
                    red_pt = Some(pt.to_string());
                }
            }
        }
    }
    let Some(pt) = opus_pt else {
        return sdp.to_string();
    };
    let fmtp_prefix = format!("a=fmtp:{pt} ");
    let mut has_fmtp = false;
    let mut has_ptime = false;
    let mut out = Vec::new();
    for line in sdp.split("\r\n") {
        if line.starts_with("m=audio ") {
            if let Some(ref rpt) = red_pt {
                let mut tokens: Vec<&str> = line.split_whitespace().collect();
                if tokens.len() >= 4 {
                    let prefix = tokens[..3].to_vec();
                    let mut pts: Vec<&str> = tokens.drain(3..).collect();
                    if let Some(pos) = pts.iter().position(|&p| p == rpt.as_str()) {
                        let r = pts.remove(pos);
                        pts.insert(0, r);
                    }
                    let mut rebuilt = prefix;
                    rebuilt.extend(pts);
                    out.push(rebuilt.join(" "));
                    continue;
                }
            }
            out.push(line.to_string());
        } else if line.starts_with(&fmtp_prefix) {
            out.push(format!("a=fmtp:{pt} {OPUS_FMTP}"));
            has_fmtp = true;
        } else if line.starts_with("a=ptime:") {
            out.push("a=ptime:20".to_string());
            has_ptime = true;
        } else {
            out.push(line.to_string());
        }
    }
    if !has_fmtp || !has_ptime {
        let rtpmap_prefix = format!("a=rtpmap:{pt} ");
        let mut patched = Vec::with_capacity(out.len() + 2);
        for line in out {
            let is_match = line.starts_with(&rtpmap_prefix);
            patched.push(line);
            if is_match {
                if !has_fmtp {
                    patched.push(format!("a=fmtp:{pt} {OPUS_FMTP}"));
                }
                if !has_ptime {
                    patched.push("a=ptime:20".to_string());
                }
            }
        }
        return patched.join("\r\n");
    }
    out.join("\r\n")
}

pub struct MediaSessionHandle {
    pub session_id: String,
    pub answer_sdp: String,
    pub candidate_label: String,
    pub counters: Arc<AudioEngineCounters>,
    stop: Arc<AtomicBool>,
    wakeup: Arc<WakeupSignal>,
    state_rx: Option<mpsc::Receiver<(&'static str, &'static str)>>,
    thread: Option<std::thread::JoinHandle<&'static str>>,
}

impl MediaSessionHandle {
    /// Gather transport (USB direct UDP or TURN UDP->TCP fallback), negotiate SDP answer with
    /// `str0m` (Opus + RED depth 2), and spawn the dedicated `SCHED_FIFO` WebRTC + Audio threads.
    pub fn start(
        cfg: MediaSessionConfig,
        on_streaming: Box<dyn FnOnce() + Send>,
        on_closed: Box<dyn FnOnce(&'static str) + Send>,
    ) -> Result<Self, &'static str> {
        let relayed = cfg.local_ip.is_none();
        let mut transport = if let Some(ip) = cfg.local_ip {
            let sock = UdpSocket::bind(SocketAddr::new(IpAddr::V4(ip), 0))
                .map_err(|_| "rtc_bind_failed")?;
            sock.set_nonblocking(true).map_err(|_| "rtc_bind_failed")?;
            let local_addr = sock.local_addr().map_err(|_| "rtc_bind_failed")?;
            Transport::DirectUdp { sock, local_addr }
        } else {
            // Collect TURN endpoints: try UDP first, then TCP fallback (for restrictive cellular NATs).
            let mut udp_eps = Vec::new();
            let mut tcp_eps = Vec::new();
            for s in &cfg.ice_servers {
                for u in &s.urls {
                    if let Some(ep) = parse_turn_url(u, &s.username, &s.credential) {
                        match ep.transport {
                            TurnTransport::Udp => udp_eps.push(ep),
                            TurnTransport::Tcp => tcp_eps.push(ep),
                        }
                    }
                }
            }
            let deadline = Instant::now() + cfg.gather_timeout;
            let mut allocated = None;
            for ep in udp_eps.into_iter().chain(tcp_eps.into_iter()) {
                let rem = deadline.saturating_duration_since(Instant::now());
                if rem < Duration::from_millis(300) {
                    break;
                }
                let attempt_timeout = rem.min(Duration::from_secs(4));
                if let Ok(client) = TurnClient::allocate(&ep, attempt_timeout) {
                    allocated = Some(client);
                    break;
                }
            }
            let client = allocated.ok_or("rtc_gather_timeout")?;
            Transport::TurnRelay { client }
        };

        let now = Instant::now();
        let mut rtc = Box::new(
            RtcConfig::new()
                .clear_codecs()
                .enable_opus(true, true)
                .set_red_distances(&[1, 2])
                .set_reordering_size_audio(0)
                .set_stats_interval(Some(Duration::from_secs(2)))
                .build(now),
        );

        match &transport {
            Transport::DirectUdp { local_addr, .. } => {
                let cand = Candidate::host(*local_addr, Protocol::Udp)
                    .map_err(|_| "rtc_candidate_failed")?;
                rtc.add_local_candidate(cand);
            }
            Transport::TurnRelay { client } => {
                let cand = Candidate::relayed(
                    client.relayed_addr(),
                    client.local_addr(),
                    Protocol::Udp,
                )
                .map_err(|_| "rtc_candidate_failed")?;
                rtc.add_local_candidate(cand);
            }
        }

        let offer = SdpOffer::from_sdp_string(&cfg.offer_sdp).map_err(|_| "rtc_offer_rejected")?;
        let answer = rtc
            .sdp_api()
            .accept_offer(offer)
            .map_err(|_| "rtc_offer_rejected")?;
        let answer_sdp = enhance_answer_sdp(&answer.to_sdp_string());

        let candidate_label = transport.candidate_kind_label().to_string();
        let counters = Arc::new(AudioEngineCounters::default());
        let stop = Arc::new(AtomicBool::new(false));
        let wakeup = Arc::new(WakeupSignal::new().map_err(|_| "wakeup_failed")?);
        let (state_tx, state_rx) = mpsc::channel();

        let thread_stop = stop.clone();
        let thread_wakeup = wakeup.clone();
        let thread_counters = counters.clone();
        let profile = cfg.audio_profile;
        let max_duration = cfg.max_duration;

        let thread = std::thread::Builder::new()
            .name("airsim-rtc".into())
            .stack_size(1024 * 1024)
            .spawn(move || -> &'static str {
                set_realtime_priority(10);
                let reason = run_rtc_loop(
                    rtc,
                    &mut transport,
                    profile,
                    relayed,
                    max_duration,
                    thread_stop,
                    thread_wakeup,
                    thread_counters,
                    on_streaming,
                    state_tx,
                );
                on_closed(reason);
                reason
            })
            .map_err(|_| "thread_start")?;

        Ok(Self {
            session_id: cfg.session_id,
            answer_sdp,
            candidate_label,
            counters,
            stop,
            wakeup,
            state_rx: Some(state_rx),
            thread: Some(thread),
        })
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.wakeup.notify();
    }

    pub fn join(&mut self) -> &'static str {
        self.stop();
        if let Some(h) = self.thread.take() {
            h.join().unwrap_or("rtc_failed")
        } else {
            "stopped"
        }
    }

    pub fn take_state_rx(&mut self) -> Option<mpsc::Receiver<(&'static str, &'static str)>> {
        self.state_rx.take()
    }
}

impl Drop for MediaSessionHandle {
    fn drop(&mut self) {
        self.stop();
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn run_rtc_loop(
    mut rtc: Box<Rtc>,
    transport: &mut Transport,
    profile: AudioProfile,
    relayed: bool,
    max_duration: Duration,
    stop: Arc<AtomicBool>,
    wakeup: Arc<WakeupSignal>,
    counters: Arc<AudioEngineCounters>,
    on_streaming: Box<dyn FnOnce() + Send>,
    state_tx: mpsc::Sender<(&'static str, &'static str)>,
) -> &'static str {
    let origin = Instant::now();
    let deadline = origin + max_duration;
    let setup_deadline = origin + ICE_SETUP_TIMEOUT;

    let tx_ring = Arc::new(SpscRing::<EncodedAudioPacket, 32>::new());
    let rx_ring = Arc::new(SpscRing::<IncomingOpusPacket, 64>::new());

    let mut pipelines: Option<RealtimeAudioPipelines> = None;
    let mut on_streaming = Some(on_streaming);
    let mut audio_mid: Option<Mid> = None;
    let mut opus_pt: Option<Pt> = None;
    let mut connected = false;
    let mut last_rtp_rx: Option<Instant> = None;
    let mut last_rx_arrival: Option<Instant> = None;
    let mut tx_rtp_time_48k: u64 = 0;
    let mut incoming_pkts: Vec<(SocketAddr, Vec<u8>)> = Vec::with_capacity(16);
    let mut reason: &'static str = "stopped";

    let sock_fd = transport.raw_fd();
    let wake_fd = wakeup.poll_fd();
    let cand_addr = transport.candidate_addr();

    let handle_event = |ev: Event,
                            rtc_ref: &mut Rtc,
                            connected: &mut bool,
                            on_streaming: &mut Option<Box<dyn FnOnce() + Send>>,
                            pipelines: &mut Option<RealtimeAudioPipelines>,
                            audio_mid: &mut Option<Mid>,
                            opus_pt: &mut Option<Pt>,
                            last_rtp_rx: &mut Option<Instant>,
                            last_rx_arrival: &mut Option<Instant>,
                            reason: &mut &'static str| {
        match ev {
            Event::Connected => {
                *connected = true;
                if let Some(cb) = on_streaming.take() {
                    cb();
                }
                let _ = state_tx.send(("streaming", ""));
                if pipelines.is_none() {
                    match RealtimeAudioPipelines::start(
                        profile,
                        relayed,
                        tx_ring.clone(),
                        rx_ring.clone(),
                        wakeup.clone(),
                        counters.clone(),
                        stop.clone(),
                    ) {
                        Ok(p) => *pipelines = Some(p),
                        Err(err) => {
                            *reason = err;
                            stop.store(true, Ordering::Release);
                        }
                    }
                }
            }
            Event::IceConnectionStateChange(st) => {
                if matches!(st, IceConnectionState::Disconnected) {
                    *reason = "rtc_failed";
                    stop.store(true, Ordering::Release);
                }
            }
            Event::MediaAdded(m) => {
                if m.kind == str0m::media::MediaKind::Audio {
                    *audio_mid = Some(m.mid);
                    if let Some(w) = rtc_ref.writer(m.mid) {
                        for p in w.payload_params() {
                            if p.spec().codec == Codec::Opus {
                                *opus_pt = Some(p.pt());
                                break;
                            }
                        }
                    }
                }
            }
            Event::MediaData(data) => {
                let now = Instant::now();
                if let Some(prev) = *last_rx_arrival {
                    let dt = now.duration_since(prev).as_millis() as u64;
                    AudioEngineCounters::record_stall(
                        &counters.rtp_stalls,
                        &counters.rtp_stall_max_ms,
                        dt,
                        100,
                    );
                }
                *last_rx_arrival = Some(now);
                *last_rtp_rx = Some(now);

                if !data.data.is_empty() && data.data.len() <= MAX_OPUS_PACKET {
                    let mut pkt = IncomingOpusPacket {
                        bytes: [0u8; MAX_OPUS_PACKET],
                        len: data.data.len() as u16,
                        rtp_time_48k: data.time.numer(),
                        rx_at_ms: origin.elapsed().as_millis() as u64,
                        start_of_talkspurt: data.audio_start_of_talk_spurt,
                    };
                    pkt.bytes[..data.data.len()].copy_from_slice(&data.data);
                    if rx_ring.push(pkt).is_err() {
                        let _ = rx_ring.pop();
                        let _ = rx_ring.push(pkt);
                        counters.queue_drops.fetch_add(1, Ordering::Relaxed);
                    }
                } else {
                    counters.invalid_audio_packets.fetch_add(1, Ordering::Relaxed);
                }
            }
            Event::MediaIngressStats(st) => {
                if let Some(loss) = st.loss {
                    counters
                        .packets_lost
                        .store((loss.max(0.0) * 100.0) as u64, Ordering::Relaxed);
                }
            }
            _ => {}
        }
    };

    while !stop.load(Ordering::Relaxed) {
        // 1. Drain str0m `poll_output` strictly until `Output::Timeout` (single-mutation invariant).
        let timeout = loop {
            match rtc.poll_output() {
                Ok(Output::Timeout(t)) => break t,
                Ok(Output::Transmit(tx)) => {
                    transport.send(tx.destination, &tx.contents);
                }
                Ok(Output::Event(ev)) => {
                    handle_event(
                        ev,
                        &mut rtc,
                        &mut connected,
                        &mut on_streaming,
                        &mut pipelines,
                        &mut audio_mid,
                        &mut opus_pt,
                        &mut last_rtp_rx,
                        &mut last_rx_arrival,
                        &mut reason,
                    );
                }
                Err(_) => {
                    reason = "rtc_failed";
                    stop.store(true, Ordering::Release);
                    break Instant::now();
                }
            }
        };

        if stop.load(Ordering::Relaxed) {
            break;
        }

        let now = Instant::now();
        if now >= deadline {
            reason = "media_expired";
            break;
        }
        if !connected && now >= setup_deadline {
            reason = "rtc_timeout";
            break;
        }
        if let Some(last_rx) = last_rtp_rx {
            if now.duration_since(last_rx) >= RTP_IDLE_TIMEOUT {
                reason = "rtp_timeout";
                break;
            }
        }

        // 2. Check if there is an outgoing encoded Opus frame waiting in `tx_ring` (1 mutation -> re-drain!).
        if connected {
            if let (Some(mid), Some(pt)) = (audio_mid, opus_pt) {
                if let Some(out_pkt) = tx_ring.pop() {
                    let t0 = Instant::now();
                    let media_time = MediaTime::new(tx_rtp_time_48k, str0m::media::Frequency::FORTY_EIGHT_KHZ);
                    tx_rtp_time_48k = tx_rtp_time_48k.wrapping_add(960);
                    if let Some(writer) = rtc.writer(mid) {
                        let res = writer
                            .start_of_talkspurt(out_pkt.start_of_talkspurt)
                            .write(pt, t0, media_time, out_pkt.as_slice().to_vec());
                        if res.is_ok() {
                            counters.packets_sent.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    let send_ms = t0.elapsed().as_millis() as u64;
                    AudioEngineCounters::record_stall(
                        &counters.send_stalls,
                        &counters.send_stall_max_ms,
                        send_ms,
                        20,
                    );
                    continue;
                }
            }
        }

        // 3. Sleep in `poll()` until socket readable, capture wakeup signaled, or str0m timeout.
        let wait_until = timeout.min(now + Duration::from_millis(50));
        let wait_ms = wait_until
            .saturating_duration_since(now)
            .as_millis()
            .clamp(1, 50) as i32;

        let mut pfds = [
            libc::pollfd {
                fd: sock_fd,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake_fd,
                events: libc::POLLIN,
                revents: 0,
            },
        ];

        let r = unsafe { libc::poll(pfds.as_mut_ptr(), 2, wait_ms) };
        if r < 0 {
            let e = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if e == libc::EINTR {
                continue;
            }
            reason = "rtc_io";
            break;
        }

        if (pfds[1].revents & libc::POLLIN) != 0 {
            wakeup.drain();
        }

        if (pfds[0].revents & (libc::POLLIN | libc::POLLERR | libc::POLLHUP)) != 0 {
            incoming_pkts.clear();
            if transport.recv_all(&mut incoming_pkts).is_err() {
                reason = "rtc_io";
                break;
            }
            for (src, payload) in incoming_pkts.drain(..) {
                let rx_now = Instant::now();
                if let Ok(receive) = Receive::new(Protocol::Udp, src, cand_addr, &payload) {
                    if rtc.handle_input(Input::Receive(rx_now, receive)).is_err() {
                        reason = "rtc_failed";
                        stop.store(true, Ordering::Release);
                        break;
                    }
                    // Strictly honor single-mutation invariant: drain poll_output after each packet!
                    loop {
                        match rtc.poll_output() {
                            Ok(Output::Timeout(_)) => break,
                            Ok(Output::Transmit(tx)) => transport.send(tx.destination, &tx.contents),
                            Ok(Output::Event(ev)) => {
                                handle_event(
                                    ev,
                                    &mut rtc,
                                    &mut connected,
                                    &mut on_streaming,
                                    &mut pipelines,
                                    &mut audio_mid,
                                    &mut opus_pt,
                                    &mut last_rtp_rx,
                                    &mut last_rx_arrival,
                                    &mut reason,
                                );
                            }
                            Err(_) => {
                                reason = "rtc_failed";
                                stop.store(true, Ordering::Release);
                                break;
                            }
                        }
                    }
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                }
            }
        }

        let after = Instant::now();
        transport.handle_timeout(after);
        if after >= timeout {
            let _ = rtc.handle_input(Input::Timeout(after));
        }
    }

    stop.store(true, Ordering::Release);
    if let Some(mut p) = pipelines {
        p.stop_and_join();
    }
    rtc.disconnect();
    reason
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enhances_answer_sdp_with_opus_64k_wideband_fmtp_and_ptime() {
        let raw = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 63 111\r\na=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n";
        let out = enhance_answer_sdp(raw);
        assert!(out.contains(&format!("a=fmtp:111 {OPUS_FMTP}")));
        assert!(out.contains("a=ptime:20"));
        assert!(out.contains("a=rtpmap:63 red/48000/2"));
    }
}
