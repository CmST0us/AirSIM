//! Comprehensive end-to-end integration tests for the unified Rust AirSIM Engine:
//! 1. 11 cellular/USB network impairment profiles across full Opus64 -> Jitter -> WSOLA pipeline
//! 2. Complete str0m <-> str0m bidirectional WebRTC + RED=2 + Opus64 + WSOLA loopback session
//! 3. Multi-part UDH SMS-DELIVER reassembly + UCS-2 + short-number SMS-SUBMIT + ledger dedup
//! 4. End-to-end Ed25519 DeviceCA provisioning, 1980 cold-boot load, 90-day renewal, pairing proof

use airsim_agent::audio::alsa::AudioProfile;
use airsim_agent::audio::jitter::{AdaptiveJitterBuffer, TICKS_PER_FRAME_48K};
use airsim_agent::audio::opus::{OpusDecoder, OpusEncoder, OPUS_FRAME_SAMPLES};
use airsim_agent::audio::ring::{IncomingOpusPacket, MAX_OPUS_PACKET};
use airsim_agent::audio::wsola::{condition_uplink_pcm, WsolaProcessor, MAX_WSOLA_OUT};
use airsim_agent::identity::{load_or_create, uuid_v4};
use airsim_agent::rtc::{MediaSessionConfig, MediaSessionHandle};
use airsim_agent::sms_pdu::{decode_cmgl, encode_submit_ucs2, SmsLedger};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use str0m::change::SdpAnswer;
use str0m::format::Codec;
use str0m::media::{Direction, MediaKind, MediaTime};
use str0m::net::{Protocol, Receive};
use str0m::{Candidate, Event, Input, Output, RtcConfig};

struct ImpairmentProfile {
    name: &'static str,
    relayed: bool,
    loss_pct: u32,
    burst_loss: bool,
    jitter_ms: u64,
    stall_at_frame: Option<(u64, u64)>, // (frame, stall_ms)
    clock_drift_ppm: i64,               // +200 => sender faster by 200ppm
}

fn synth_voice_frame(frame_idx: u64) -> [i16; OPUS_FRAME_SAMPLES] {
    let mut pcm = [0i16; OPUS_FRAME_SAMPLES];
    for (i, s) in pcm.iter_mut().enumerate() {
        let t = (frame_idx as f64 * 320.0 + i as f64) / 16000.0;
        // Voiced vowel-like harmonic complex (F0 = 180 Hz + 2nd/3rd harmonics)
        let v = 9000.0 * (2.0 * std::f64::consts::PI * 180.0 * t).sin()
            + 4500.0 * (2.0 * std::f64::consts::PI * 360.0 * t).sin()
            + 2000.0 * (2.0 * std::f64::consts::PI * 540.0 * t).sin();
        *s = v.clamp(-30000.0, 30000.0) as i16;
    }
    pcm
}

#[test]
fn eleven_network_impairment_profiles_zero_drops_and_clean_wsola() {
    let profiles = [
        ImpairmentProfile { name: "usb_clean", relayed: false, loss_pct: 0, burst_loss: false, jitter_ms: 2, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_clean", relayed: true, loss_pct: 0, burst_loss: false, jitter_ms: 12, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_loss_3pct", relayed: true, loss_pct: 3, burst_loss: false, jitter_ms: 18, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_loss_5pct", relayed: true, loss_pct: 5, burst_loss: false, jitter_ms: 25, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_loss_10pct", relayed: true, loss_pct: 10, burst_loss: false, jitter_ms: 30, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_burst_loss_2pkt", relayed: true, loss_pct: 4, burst_loss: true, jitter_ms: 25, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_jitter_50ms", relayed: true, loss_pct: 1, burst_loss: false, jitter_ms: 50, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_jitter_90ms", relayed: true, loss_pct: 1, burst_loss: false, jitter_ms: 90, stall_at_frame: None, clock_drift_ppm: 0 },
        ImpairmentProfile { name: "lte_stall_120ms", relayed: true, loss_pct: 0, burst_loss: false, jitter_ms: 15, stall_at_frame: Some((60, 120)), clock_drift_ppm: 0 },
        ImpairmentProfile { name: "clock_drift_plus_500ppm", relayed: true, loss_pct: 0, burst_loss: false, jitter_ms: 8, stall_at_frame: None, clock_drift_ppm: 500 },
        ImpairmentProfile { name: "clock_drift_minus_500ppm", relayed: true, loss_pct: 0, burst_loss: false, jitter_ms: 8, stall_at_frame: None, clock_drift_ppm: -500 },
    ];

    for p in &profiles {
        let mut enc = OpusEncoder::new().unwrap();
        let mut dec = OpusDecoder::new().unwrap();
        let mut jb = AdaptiveJitterBuffer::new(p.relayed);
        let mut wsola = WsolaProcessor::new();

        // Simulate 4 seconds (200 frames @ 20ms) with deterministic LCG PRNG
        let mut rng = 0x1234_5678_9abc_def0u64;
        let mut next_u32 = || -> u32 {
            rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (rng >> 32) as u32
        };

        // Pre-generate arriving packets with scheduled arrival time
        let mut arrivals: Vec<(u64, IncomingOpusPacket)> = Vec::new();
        let mut drop_next = false;
        for f in 0..200u64 {
            let mut pcm = synth_voice_frame(f);
            let mut pkt_bytes = [0u8; MAX_OPUS_PACKET];
            let len = enc.encode(&pcm, &mut pkt_bytes).unwrap();
            let _ = &mut pcm;

            if drop_next {
                drop_next = false;
                continue;
            }
            if p.loss_pct > 0 && (next_u32() % 100) < p.loss_pct {
                if p.burst_loss {
                    drop_next = true;
                }
                continue;
            }

            let base_ms = ((f * 20) as i64 * (1_000_000 - p.clock_drift_ppm) / 1_000_000).max(0) as u64;
            let jit = if p.jitter_ms > 0 { (next_u32() as u64) % p.jitter_ms } else { 0 };
            let mut rx_ms = base_ms + jit;
            if let Some((sf, sdur)) = p.stall_at_frame {
                if f >= sf && f < sf + (sdur / 20) {
                    rx_ms = sf * 20 + sdur + (f - sf);
                }
            }
            let mut in_pkt = IncomingOpusPacket {
                bytes: [0u8; MAX_OPUS_PACKET],
                len: len as u16,
                rtp_time_48k: f * TICKS_PER_FRAME_48K,
                rx_at_ms: rx_ms,
                start_of_talkspurt: f == 0,
            };
            in_pkt.bytes[..len].copy_from_slice(&pkt_bytes[..len]);
            arrivals.push((rx_ms, in_pkt));
        }
        arrivals.sort_by_key(|(t, _)| *t);

        let mut arr_idx = 0usize;
        let mut total_out_samples = 0usize;
        let mut decoded = [0i16; OPUS_FRAME_SAMPLES];
        let mut wsola_out = [0i16; MAX_WSOLA_OUT];
        let mut play_time_ms = 0u64;

        while play_time_ms < 3940 {
            while arr_idx < arrivals.len() && arrivals[arr_idx].0 <= play_time_ms {
                jb.push(&arrivals[arr_idx].1);
                arr_idx += 1;
            }
            if let Some(frame) = jb.pop(play_time_ms, 32) {
                let slice = if frame.len > 0 { Some(&frame.data[..frame.len]) } else { None };
                dec.decode(slice, frame.kind, &mut decoded).unwrap();
                let n = wsola.process(&decoded, frame.wsola_mode, frame.wsola_force, &mut wsola_out);
                condition_uplink_pcm(&mut wsola_out[..n]);
                total_out_samples += n;
                // Output duration advances hardware playback clock!
                play_time_ms += (n as u64 * 1000) / 16000;
            } else {
                play_time_ms += 20;
            }
        }

        assert_eq!(jb.stats.queue_drops, 0, "profile {}: unexpected queue drops", p.name);
        assert_eq!(jb.stats.playout_resyncs, 0, "profile {}: unexpected resyncs", p.name);
        assert!(total_out_samples > 40000, "profile {}: too few output samples", p.name);
        if p.loss_pct == 0 && p.stall_at_frame.is_none() && p.jitter_ms <= 20 && p.clock_drift_ppm == 0 {
            assert_eq!(jb.stats.plc_frames, 0, "profile {}: expected zero PLC on clean path", p.name);
        }
    }
}

#[test]
fn bidirectional_str0m_webrtc_red_opus_wsola_loopback() {
    // Offerer (simulating iOS SkySIM) with Opus + RED depth 2
    let client_sock = UdpSocket::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap();
    client_sock.set_nonblocking(true).unwrap();
    let client_addr = client_sock.local_addr().unwrap();

    let now = Instant::now();
    let mut client_rtc = RtcConfig::new()
        .clear_codecs()
        .enable_opus(true, true)
        .set_red_distances(&[1, 2])
        .build(now);
    client_rtc.add_local_candidate(Candidate::host(client_addr, Protocol::Udp).unwrap());
    let mut change = client_rtc.sdp_api();
    let mid = change.add_media(MediaKind::Audio, Direction::SendRecv, None, None, None);
    let (offer, pending) = change.apply().unwrap();

    // Answerer: our REAL MediaSessionHandle with MockLoopback RT threads!
    let cfg = MediaSessionConfig {
        session_id: uuid_v4().unwrap(),
        offer_sdp: offer.to_sdp_string(),
        ice_servers: Vec::new(),
        local_ip: Some(Ipv4Addr::LOCALHOST),
        gather_timeout: Duration::from_secs(3),
        audio_profile: AudioProfile::MockLoopback,
        max_duration: Duration::from_secs(15),
    };
    let mut handle = MediaSessionHandle::start(cfg, Box::new(|| {}), Box::new(|_| {})).unwrap();
    assert!(handle.answer_sdp.contains("maxaveragebitrate=64000"));
    assert!(handle.answer_sdp.contains("a=ptime:20"));
    assert!(handle.answer_sdp.contains("red/48000"));

    let answer = SdpAnswer::from_sdp_string(&handle.answer_sdp).unwrap();
    client_rtc.sdp_api().accept_answer(pending, answer).unwrap();

    // Run offerer for 1.5s sending real Opus 64k encoded frames and verifying bidirectional RX
    let mut enc = OpusEncoder::new().unwrap();
    let mut client_connected = false;
    let mut client_rx_frames = 0u64;
    let mut opus_pt = None;
    let start = Instant::now();
    let mut next_send = Instant::now();
    let mut tx_frame_idx = 0u64;
    let mut buf = [0u8; 2048];

    while start.elapsed() < Duration::from_millis(1600) {
        let timeout = loop {
            match client_rtc.poll_output().unwrap() {
                Output::Timeout(t) => break t,
                Output::Transmit(tx) => {
                    let _ = client_sock.send_to(&tx.contents, tx.destination);
                }
                Output::Event(ev) => match ev {
                    Event::Connected => {
                        client_connected = true;
                        if let Some(w) = client_rtc.writer(mid) {
                            for p in w.payload_params() {
                                if p.spec().codec == Codec::Opus {
                                    opus_pt = Some(p.pt());
                                }
                            }
                        }
                    }
                    Event::MediaData(m) => {
                        if !m.data.is_empty() {
                            client_rx_frames += 1;
                        }
                    }
                    _ => {}
                },
            }
        };

        if client_connected && Instant::now() >= next_send {
            if let Some(pt) = opus_pt {
                let pcm = synth_voice_frame(tx_frame_idx);
                let mut pkt = [0u8; MAX_OPUS_PACKET];
                let len = enc.encode(&pcm, &mut pkt).unwrap();
                let t = Instant::now();
                let mt = MediaTime::new(tx_frame_idx * 960, str0m::media::Frequency::FORTY_EIGHT_KHZ);
                if let Some(w) = client_rtc.writer(mid) {
                    let _ = w.write(pt, t, mt, pkt[..len].to_vec());
                }
                tx_frame_idx += 1;
                next_send += Duration::from_millis(20);
                continue;
            }
        }

        let mut fed = false;
        while let Ok((n, src)) = client_sock.recv_from(&mut buf) {
            if let Ok(r) = Receive::new(Protocol::Udp, src, client_addr, &buf[..n]) {
                let _ = client_rtc.handle_input(Input::Receive(Instant::now(), r));
                fed = true;
                break;
            }
        }
        if !fed {
            let now2 = Instant::now();
            if now2 >= timeout {
                let _ = client_rtc.handle_input(Input::Timeout(now2));
            } else {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    }

    let mod_rx = handle.counters.packets_received.load(Ordering::Relaxed);
    let mod_tx = handle.counters.packets_sent.load(Ordering::Relaxed);
    let non_zero = handle.counters.synthetic_decoded_non_zero.load(Ordering::Relaxed);
    handle.join();

    assert!(client_connected, "WebRTC DTLS/ICE failed to connect");
    assert!(client_rx_frames >= 30, "expected >=30 downlink Opus frames at client, got {client_rx_frames}");
    assert!(mod_rx >= 30, "expected >=30 uplink Opus frames at module, got {mod_rx}");
    assert!(mod_tx >= 30, "expected >=30 sent frames from module, got {mod_tx}");
    assert!(non_zero > 5000, "expected non-zero decoded speech samples on module, got {non_zero}");
}

#[test]
fn sms_multipart_ucs2_and_ledger_reconcile() {
    // 2-part concatenated UCS-2 SMS-DELIVER from 10086: "你好" + "世界"
    // Part 1: UDH = 05 00 03 42 02 01, text "你好" = 4F60 597D -> UDL = 10 (0x0A)
    // Part 2: UDH = 05 00 03 42 02 02, text "世界" = 4E16 754C -> UDL = 10 (0x0A)
    let p1 = "004405810180F60008621132020000230A0500034202014F60597D";
    let p2 = "004405810180F60008621132020000230A0500034202024E16754C";
    let lines = vec![
        "+CMGL: 4,0,\"\",27".to_string(),
        p1.to_string(),
        "+CMGL: 5,0,\"\",27".to_string(),
        p2.to_string(),
    ];
    let msgs = decode_cmgl(&lines).unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].sender, "10086");
    assert_eq!(msgs[0].text, "你好世界");
    assert_eq!(msgs[0].indices, vec![4, 5]);

    // Verify ledger first-poll seeding + second-poll new arrival detection
    let dir = std::env::temp_dir().join(format!("airsim-sms-ledger-{}", uuid_v4().unwrap()));
    let lp = dir.join("eg25-sms-seen");
    let mut l1 = SmsLedger::open(Some(lp.clone()));
    assert!(l1.reconcile(&[msgs[0].key.clone()]).is_empty());
    let mut l2 = SmsLedger::open(Some(lp));
    let fresh = l2.reconcile(&[msgs[0].key.clone(), "brand-new-key:".to_string()]);
    assert_eq!(fresh, vec!["brand-new-key:".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);

    // Verify short-number UCS-2 submit
    let (tpdu_len, pdu_hex) = encode_submit_ucs2("10086", "测试123").unwrap();
    assert_eq!(pdu_hex.len(), 2 + tpdu_len * 2);
    assert!(pdu_hex.starts_with("0001000581"));

    // Verify identity persistence directory check
    let id_dir = std::env::temp_dir().join(format!("airsim-id-int-{}", uuid_v4().unwrap()));
    let id = load_or_create(&id_dir).unwrap();
    assert!(!id.module_id.is_empty());
    let _ = std::fs::remove_dir_all(&id_dir);
}

#[test]
fn turn_udp_and_tcp_relay_and_relayed_webrtc_call_e2e() {
    use hmac::{Hmac, Mac};
    use md5::{Digest as _, Md5};
    use sha1::Sha1;
    use std::collections::HashMap;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    type HmacSha1 = Hmac<Sha1>;
    const COOKIE: u32 = 0x2112_A442;
    const REALM: &str = "airsim-test";
    const NONCE: &str = "0123456789abcdef";
    const USER: &str = "1893456000:test-session:module";
    const PASS: &str = "s3cr3t-turn-pass";

    fn auth_key() -> [u8; 16] {
        let mut h = Md5::new();
        h.update(format!("{USER}:{REALM}:{PASS}").as_bytes());
        h.finalize().into()
    }

    fn verify_mi(raw: &[u8]) -> bool {
        if raw.len() < 20 {
            return false;
        }
        let msg_len = u16::from_be_bytes([raw[2], raw[3]]) as usize;
        if 20 + msg_len > raw.len() {
            return false;
        }
        let mut off = 20usize;
        let end = 20 + msg_len;
        while off + 4 <= end {
            let t = u16::from_be_bytes([raw[off], raw[off + 1]]);
            let l = u16::from_be_bytes([raw[off + 2], raw[off + 3]]) as usize;
            if t == 0x0008 && l == 20 && off + 4 + 20 <= end {
                let mut hdr = raw[..off].to_vec();
                let len_up_to_mi = (off - 20 + 24) as u16;
                hdr[2..4].copy_from_slice(&len_up_to_mi.to_be_bytes());
                let mut mac = HmacSha1::new_from_slice(&auth_key()).unwrap();
                mac.update(&hdr);
                return mac.finalize().into_bytes().as_slice() == &raw[off + 4..off + 24];
            }
            let pad = (4 - (l % 4)) % 4;
            off = (off + 4 + l + pad).min(end);
        }
        false
    }

    fn stun_attr(out: &mut Vec<u8>, t: u16, v: &[u8]) {
        out.extend_from_slice(&t.to_be_bytes());
        out.extend_from_slice(&(v.len() as u16).to_be_bytes());
        out.extend_from_slice(v);
        for _ in 0..((4 - (v.len() % 4)) % 4) {
            out.push(0);
        }
    }

    fn xor_addr_bytes(a: SocketAddr) -> [u8; 8] {
        let SocketAddr::V4(v4) = a else { unreachable!() };
        let mut b = [0u8; 8];
        b[1] = 1;
        b[2..4].copy_from_slice(&(v4.port() ^ ((COOKIE >> 16) as u16)).to_be_bytes());
        b[4..8].copy_from_slice(&(u32::from_be_bytes(v4.ip().octets()) ^ COOKIE).to_be_bytes());
        b
    }

    fn parse_xor(v: &[u8]) -> Option<SocketAddr> {
        if v.len() < 8 || v[1] != 1 {
            return None;
        }
        let port = u16::from_be_bytes([v[2], v[3]]) ^ ((COOKIE >> 16) as u16);
        let ip = Ipv4Addr::from(u32::from_be_bytes([v[4], v[5], v[6], v[7]]) ^ COOKIE);
        Some(SocketAddr::new(IpAddr::V4(ip), port))
    }

    fn build_stun(mtype: u16, tx: &[u8], attrs: &[(u16, &[u8])]) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(&mtype.to_be_bytes());
        b.extend_from_slice(&0u16.to_be_bytes());
        b.extend_from_slice(&COOKIE.to_be_bytes());
        b.extend_from_slice(&tx[..12]);
        for (t, v) in attrs {
            stun_attr(&mut b, *t, v);
        }
        let l = (b.len() - 20) as u16;
        b[2..4].copy_from_slice(&l.to_be_bytes());
        b
    }

    fn extract_attrs(raw: &[u8]) -> Vec<(u16, &[u8])> {
        let mut res = Vec::new();
        let len = u16::from_be_bytes([raw[2], raw[3]]) as usize;
        let end = (20 + len).min(raw.len());
        let mut off = 20;
        while off + 4 <= end {
            let t = u16::from_be_bytes([raw[off], raw[off + 1]]);
            let l = u16::from_be_bytes([raw[off + 2], raw[off + 3]]) as usize;
            if off + 4 + l > end {
                break;
            }
            res.push((t, &raw[off + 4..off + 4 + l]));
            let pad = (4 - (l % 4)) % 4;
            off = (off + 4 + l + pad).min(end);
        }
        res
    }

    // --- 1. Start minimal RFC 5766 UDP TURN server ---
    let stop = Arc::new(AtomicBool::new(false));
    let udp_srv_sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    let udp_turn_addr = udp_srv_sock.local_addr().unwrap();
    udp_srv_sock.set_nonblocking(true).unwrap();

    let stop_udp = stop.clone();
    let udp_thread = std::thread::spawn(move || {
        struct Alloc {
            client: SocketAddr,
            relay: UdpSocket,
            perms: Vec<IpAddr>,
            chan_to_peer: HashMap<u16, SocketAddr>,
            peer_to_chan: HashMap<SocketAddr, u16>,
        }
        let mut allocs: HashMap<SocketAddr, Alloc> = HashMap::new();
        let mut buf = [0u8; 2048];
        let mut rbuf = [0u8; 2048];
        while !stop_udp.load(Ordering::Relaxed) {
            while let Ok((n, src)) = udp_srv_sock.recv_from(&mut buf) {
                let pkt = &buf[..n];
                if pkt.len() >= 4 && (0x4000..=0x7FFF).contains(&u16::from_be_bytes([pkt[0], pkt[1]])) {
                    let ch = u16::from_be_bytes([pkt[0], pkt[1]]);
                    let clen = u16::from_be_bytes([pkt[2], pkt[3]]) as usize;
                    if let Some(al) = allocs.get(&src) {
                        if let Some(&peer) = al.chan_to_peer.get(&ch) {
                            let _ = al.relay.send_to(&pkt[4..4 + clen.min(pkt.len() - 4)], peer);
                        }
                    }
                    continue;
                }
                if pkt.len() < 20 {
                    continue;
                }
                let mtype = u16::from_be_bytes([pkt[0], pkt[1]]);
                let tx = &pkt[8..20];
                let attrs = extract_attrs(pkt);
                match mtype {
                    0x0003 => {
                        if !verify_mi(pkt) {
                            let err = [0, 0, 4, 1]; // 401
                            let resp = build_stun(0x0113, tx, &[(0x0009, &err), (0x0014, REALM.as_bytes()), (0x0015, NONCE.as_bytes())]);
                            let _ = udp_srv_sock.send_to(&resp, src);
                        } else {
                            let relay = UdpSocket::bind("127.0.0.1:0").unwrap();
                            relay.set_nonblocking(true).unwrap();
                            let raddr = relay.local_addr().unwrap();
                            let xr = xor_addr_bytes(raddr);
                            let life = 600u32.to_be_bytes();
                            let resp = build_stun(0x0103, tx, &[(0x0016, &xr), (0x000D, &life)]);
                            allocs.insert(src, Alloc { client: src, relay, perms: Vec::new(), chan_to_peer: HashMap::new(), peer_to_chan: HashMap::new() });
                            let _ = udp_srv_sock.send_to(&resp, src);
                        }
                    }
                    0x0008 if verify_mi(pkt) => {
                        if let Some(al) = allocs.get_mut(&src) {
                            for (t, v) in &attrs {
                                if *t == 0x0012 {
                                    if let Some(p) = parse_xor(v) {
                                        if !al.perms.contains(&p.ip()) {
                                            al.perms.push(p.ip());
                                        }
                                    }
                                }
                            }
                            let resp = build_stun(0x0108, tx, &[]);
                            let _ = udp_srv_sock.send_to(&resp, src);
                        }
                    }
                    0x0009 if verify_mi(pkt) => {
                        if let Some(al) = allocs.get_mut(&src) {
                            let mut ch = None;
                            let mut peer = None;
                            for (t, v) in &attrs {
                                if *t == 0x000C && v.len() >= 2 {
                                    ch = Some(u16::from_be_bytes([v[0], v[1]]));
                                } else if *t == 0x0012 {
                                    peer = parse_xor(v);
                                }
                            }
                            if let (Some(c), Some(p)) = (ch, peer) {
                                if !al.perms.contains(&p.ip()) {
                                    al.perms.push(p.ip());
                                }
                                al.chan_to_peer.insert(c, p);
                                al.peer_to_chan.insert(p, c);
                                let resp = build_stun(0x0109, tx, &[]);
                                let _ = udp_srv_sock.send_to(&resp, src);
                            }
                        }
                    }
                    0x0016 => {
                        if let Some(al) = allocs.get(&src) {
                            let mut peer = None;
                            let mut data = None;
                            for (t, v) in &attrs {
                                if *t == 0x0012 {
                                    peer = parse_xor(v);
                                } else if *t == 0x0013 {
                                    data = Some(*v);
                                }
                            }
                            if let (Some(p), Some(d)) = (peer, data) {
                                if al.perms.contains(&p.ip()) {
                                    let _ = al.relay.send_to(d, p);
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
            for al in allocs.values() {
                while let Ok((rn, peer)) = al.relay.recv_from(&mut rbuf) {
                    if !al.perms.contains(&peer.ip()) {
                        continue;
                    }
                    if let Some(&ch) = al.peer_to_chan.get(&peer) {
                        let mut frame = Vec::with_capacity(4 + rn);
                        frame.extend_from_slice(&ch.to_be_bytes());
                        frame.extend_from_slice(&(rn as u16).to_be_bytes());
                        frame.extend_from_slice(&rbuf[..rn]);
                        let _ = udp_srv_sock.send_to(&frame, al.client);
                    } else {
                        let xp = xor_addr_bytes(peer);
                        let ind = build_stun(0x0017, &[0x42; 12], &[(0x0012, &xp), (0x0013, &rbuf[..rn])]);
                        let _ = udp_srv_sock.send_to(&ind, al.client);
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    });

    // --- 2. Start minimal RFC 5766 TCP TURN server ---
    let tcp_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let tcp_turn_addr = tcp_listener.local_addr().unwrap();
    tcp_listener.set_nonblocking(true).unwrap();

    let stop_tcp = stop.clone();
    let tcp_thread = std::thread::spawn(move || {
        while !stop_tcp.load(Ordering::Relaxed) {
            if let Ok((mut stream, _)) = tcp_listener.accept() {
                let _ = stream.set_nonblocking(true);
                let _ = stream.set_nodelay(true);
                let mut rx = Vec::new();
                let mut tmp = [0u8; 2048];
                let mut rbuf = [0u8; 2048];
                let mut relay: Option<UdpSocket> = None;
                let mut perms: Vec<IpAddr> = Vec::new();
                let mut chan_to_peer: HashMap<u16, SocketAddr> = HashMap::new();
                let mut peer_to_chan: HashMap<SocketAddr, u16> = HashMap::new();
                while !stop_tcp.load(Ordering::Relaxed) {
                    match stream.read(&mut tmp) {
                        Ok(0) => break,
                        Ok(n) => rx.extend_from_slice(&tmp[..n]),
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                        Err(_) => break,
                    }
                    while rx.len() >= 4 {
                        let f2 = u16::from_be_bytes([rx[0], rx[1]]);
                        let frame_len = if (0x4000..=0x7FFF).contains(&f2) {
                            let l = u16::from_be_bytes([rx[2], rx[3]]) as usize;
                            4 + l + ((4 - (l % 4)) % 4)
                        } else if rx.len() >= 20 {
                            20 + u16::from_be_bytes([rx[2], rx[3]]) as usize
                        } else {
                            break;
                        };
                        if rx.len() < frame_len {
                            break;
                        }
                        let pkt: Vec<u8> = rx.drain(..frame_len).collect();
                        if (0x4000..=0x7FFF).contains(&f2) {
                            let clen = u16::from_be_bytes([pkt[2], pkt[3]]) as usize;
                            if let (Some(r), Some(&peer)) = (&relay, chan_to_peer.get(&f2)) {
                                let _ = r.send_to(&pkt[4..4 + clen], peer);
                            }
                            continue;
                        }
                        let mtype = u16::from_be_bytes([pkt[0], pkt[1]]);
                        let tx = &pkt[8..20];
                        let attrs = extract_attrs(&pkt);
                        match mtype {
                            0x0003 => {
                                if !verify_mi(&pkt) {
                                    let err = [0, 0, 4, 1];
                                    let resp = build_stun(0x0113, tx, &[(0x0009, &err), (0x0014, REALM.as_bytes()), (0x0015, NONCE.as_bytes())]);
                                    let _ = stream.write_all(&resp);
                                } else {
                                    let r = UdpSocket::bind("127.0.0.1:0").unwrap();
                                    r.set_nonblocking(true).unwrap();
                                    let xr = xor_addr_bytes(r.local_addr().unwrap());
                                    let life = 600u32.to_be_bytes();
                                    let resp = build_stun(0x0103, tx, &[(0x0016, &xr), (0x000D, &life)]);
                                    relay = Some(r);
                                    let _ = stream.write_all(&resp);
                                }
                            }
                            0x0008 if verify_mi(&pkt) => {
                                for (t, v) in &attrs {
                                    if *t == 0x0012 {
                                        if let Some(p) = parse_xor(v) {
                                            if !perms.contains(&p.ip()) {
                                                perms.push(p.ip());
                                            }
                                        }
                                    }
                                }
                                let _ = stream.write_all(&build_stun(0x0108, tx, &[]));
                            }
                            0x0009 if verify_mi(&pkt) => {
                                let mut ch = None;
                                let mut peer = None;
                                for (t, v) in &attrs {
                                    if *t == 0x000C && v.len() >= 2 {
                                        ch = Some(u16::from_be_bytes([v[0], v[1]]));
                                    } else if *t == 0x0012 {
                                        peer = parse_xor(v);
                                    }
                                }
                                if let (Some(c), Some(p)) = (ch, peer) {
                                    if !perms.contains(&p.ip()) {
                                        perms.push(p.ip());
                                    }
                                    chan_to_peer.insert(c, p);
                                    peer_to_chan.insert(p, c);
                                    let _ = stream.write_all(&build_stun(0x0109, tx, &[]));
                                }
                            }
                            0x0016 => {
                                let mut peer = None;
                                let mut data = None;
                                for (t, v) in &attrs {
                                    if *t == 0x0012 {
                                        peer = parse_xor(v);
                                    } else if *t == 0x0013 {
                                        data = Some(*v);
                                    }
                                }
                                if let (Some(r), Some(p), Some(d)) = (&relay, peer, data) {
                                    if perms.contains(&p.ip()) {
                                        let _ = r.send_to(d, p);
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    if let Some(ref r) = relay {
                        while let Ok((rn, peer)) = r.recv_from(&mut rbuf) {
                            if !perms.contains(&peer.ip()) {
                                continue;
                            }
                            if let Some(&ch) = peer_to_chan.get(&peer) {
                                let mut frame = Vec::with_capacity(4 + rn + 3);
                                frame.extend_from_slice(&ch.to_be_bytes());
                                frame.extend_from_slice(&(rn as u16).to_be_bytes());
                                frame.extend_from_slice(&rbuf[..rn]);
                                for _ in 0..((4 - (rn % 4)) % 4) {
                                    frame.push(0);
                                }
                                let _ = stream.write_all(&frame);
                            } else {
                                let xp = xor_addr_bytes(peer);
                                let ind = build_stun(0x0017, &[0x43; 12], &[(0x0012, &xp), (0x0013, &rbuf[..rn])]);
                                let _ = stream.write_all(&ind);
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
            } else {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    });

    // --- 3. Echo peer verifying both UDP & TCP TURN (SendInd -> ChannelBind -> ChannelData) ---
    let echo_sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    let echo_addr = echo_sock.local_addr().unwrap();
    echo_sock.set_nonblocking(true).unwrap();
    let stop_echo = stop.clone();
    let echo_thread = std::thread::spawn(move || {
        let mut b = [0u8; 2048];
        while !stop_echo.load(Ordering::Relaxed) {
            if let Ok((n, src)) = echo_sock.recv_from(&mut b) {
                let _ = echo_sock.send_to(&b[..n], src);
            } else {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    });

    for (proto, addr) in [("udp", udp_turn_addr), ("tcp", tcp_turn_addr)] {
        let url = format!("turn:{}?transport={proto}", addr);
        let ep = airsim_agent::rtc::turn::parse_turn_url(&url, USER, PASS).unwrap();
        let mut client =
            airsim_agent::rtc::turn::TurnClient::allocate(&ep, Duration::from_secs(3)).unwrap();
        let mut rx_buf = Vec::new();
        let mut received = 0usize;
        for seq in 0..25u8 {
            // Mix non-4-byte-aligned payload lengths to exercise TCP RFC 5766 §11.5 ChannelData padding!
            let payload = vec![0xAA, proto.as_bytes()[0], seq, 0x55, seq.wrapping_mul(13)];
            client.send_to_peer(echo_addr, &payload).unwrap();
            let deadline = Instant::now() + Duration::from_millis(500);
            while Instant::now() < deadline {
                rx_buf.clear();
                client.recv_packets(&mut rx_buf).unwrap();
                if let Some((src, data)) = rx_buf.pop() {
                    assert_eq!(src, echo_addr);
                    assert_eq!(data, payload);
                    received += 1;
                    break;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
        }
        assert_eq!(received, 25, "TURN {proto} echo failed: {received}/25");
    }

    // --- 4. Full End-to-End Relayed WebRTC Call through TURN UDP (local_ip: None!) ---
    let client_sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    client_sock.set_nonblocking(true).unwrap();
    let client_addr = client_sock.local_addr().unwrap();

    let mut client_rtc = RtcConfig::new()
        .clear_codecs()
        .enable_opus(true, true)
        .set_red_distances(&[1, 2])
        .build(Instant::now());
    client_rtc.add_local_candidate(Candidate::host(client_addr, Protocol::Udp).unwrap());
    let mut change = client_rtc.sdp_api();
    let mid = change.add_media(MediaKind::Audio, Direction::SendRecv, None, None, None);
    let (offer, pending) = change.apply().unwrap();

    let cfg = MediaSessionConfig {
        session_id: uuid_v4().unwrap(),
        offer_sdp: offer.to_sdp_string(),
        ice_servers: vec![airsim_agent::rtc::IceServer {
            urls: vec![format!("turn:{udp_turn_addr}?transport=udp")],
            username: USER.to_string(),
            credential: PASS.to_string(),
        }],
        local_ip: None, // Force pure TURN relay mode!
        gather_timeout: Duration::from_secs(4),
        audio_profile: AudioProfile::MockLoopback,
        max_duration: Duration::from_secs(15),
    };
    let mut handle = MediaSessionHandle::start(cfg, Box::new(|| {}), Box::new(|_| {})).unwrap();
    assert_eq!(handle.candidate_label, "relay");
    assert!(handle.answer_sdp.contains("typ relay"));

    let answer = SdpAnswer::from_sdp_string(&handle.answer_sdp).unwrap();
    client_rtc.sdp_api().accept_answer(pending, answer).unwrap();

    let mut enc = OpusEncoder::new().unwrap();
    let mut client_connected = false;
    let mut client_rx = 0u64;
    let mut opus_pt = None;
    let start = Instant::now();
    let mut next_send = Instant::now();
    let mut tx_idx = 0u64;
    let mut buf = [0u8; 2048];

    while start.elapsed() < Duration::from_millis(1600) {
        let timeout = loop {
            match client_rtc.poll_output().unwrap() {
                Output::Timeout(t) => break t,
                Output::Transmit(tx) => {
                    let _ = client_sock.send_to(&tx.contents, tx.destination);
                }
                Output::Event(ev) => match ev {
                    Event::Connected => {
                        client_connected = true;
                        if let Some(w) = client_rtc.writer(mid) {
                            for p in w.payload_params() {
                                if p.spec().codec == Codec::Opus {
                                    opus_pt = Some(p.pt());
                                }
                            }
                        }
                    }
                    Event::MediaData(m) if !m.data.is_empty() => client_rx += 1,
                    _ => {}
                },
            }
        };
        if client_connected && Instant::now() >= next_send {
            if let Some(pt) = opus_pt {
                let pcm = synth_voice_frame(tx_idx);
                let mut pkt = [0u8; MAX_OPUS_PACKET];
                let len = enc.encode(&pcm, &mut pkt).unwrap();
                let mt = MediaTime::new(tx_idx * 960, str0m::media::Frequency::FORTY_EIGHT_KHZ);
                if let Some(w) = client_rtc.writer(mid) {
                    let _ = w.write(pt, Instant::now(), mt, pkt[..len].to_vec());
                }
                tx_idx += 1;
                next_send += Duration::from_millis(20);
                continue;
            }
        }
        let mut fed = false;
        while let Ok((n, src)) = client_sock.recv_from(&mut buf) {
            if let Ok(r) = Receive::new(Protocol::Udp, src, client_addr, &buf[..n]) {
                let _ = client_rtc.handle_input(Input::Receive(Instant::now(), r));
                fed = true;
                break;
            }
        }
        if !fed {
            let now2 = Instant::now();
            if now2 >= timeout {
                let _ = client_rtc.handle_input(Input::Timeout(now2));
            } else {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    }

    let mod_rx = handle.counters.packets_received.load(Ordering::Relaxed);
    let mod_tx = handle.counters.packets_sent.load(Ordering::Relaxed);
    let drops = handle.counters.queue_drops.load(Ordering::Relaxed);
    let non_zero = handle.counters.synthetic_decoded_non_zero.load(Ordering::Relaxed);
    handle.join();

    stop.store(true, Ordering::Relaxed);
    let _ = udp_thread.join();
    let _ = tcp_thread.join();
    let _ = echo_thread.join();

    assert!(client_connected, "Relayed WebRTC call failed to connect through TURN");
    assert!(client_rx >= 30, "expected >=30 relayed downlink frames, got {client_rx}");
    assert!(mod_rx >= 30, "expected >=30 relayed uplink frames, got {mod_rx}");
    assert!(mod_tx >= 30, "expected >=30 relayed sent frames, got {mod_tx}");
    assert_eq!(drops, 0);
    assert!(non_zero > 5000, "expected non-zero decoded speech via TURN, got {non_zero}");
}

#[test]
fn provisioner_ed25519_ca_prepare_activate_reload_renew_and_pairing_proof() {
    use airsim_agent::http_lite::HttpRequest;
    use airsim_agent::provision::{Bundle, Prepare, Provisioner, CLOUD_PROFILE};
    use base64::Engine as _;
    use ed25519_dalek::{Signature, Signer, SigningKey, Verifier};
    use rcgen::{BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair, SanType};
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use time::format_description::well_known::Rfc3339;
    use time::OffsetDateTime;

    let dir = std::env::temp_dir().join(format!("airsim-prov-e2e-{}", uuid_v4().unwrap()));
    let id = load_or_create(&dir).unwrap();
    let cloud_path = dir.join("cloud.json");
    let prov = Provisioner::open(id.clone(), cloud_path.clone(), CLOUD_PROFILE.to_string());

    // Build real Ed25519 DeviceCA using rcgen + matching ed25519_dalek SigningKey for commit receipts
    let mut ca_seed = [0u8; 32];
    ca_seed[0] = 7;
    ca_seed[31] = 99;
    let ca_sk = SigningKey::from_bytes(&ca_seed);
    // PKCS#8 v1 wrapper for raw 32-byte Ed25519 seed (RFC 8410)
    let mut ca_pkcs8 = vec![
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    ];
    ca_pkcs8.extend_from_slice(&ca_seed);
    let ca_kp = KeyPair::try_from(ca_pkcs8.as_slice()).unwrap();

    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca_cert = ca_params.self_signed(&ca_kp).unwrap();
    let ca_issuer = Issuer::from_params(&ca_params, &ca_kp);

    let req_id = uuid_v4().unwrap();
    let srv_id = uuid_v4().unwrap();
    let nonce = "1".repeat(64);
    let exp = (OffsetDateTime::now_utc() + time::Duration::minutes(5))
        .format(&Rfc3339)
        .unwrap();

    let prep_req = Prepare {
        request_id: req_id.clone(),
        server_id: srv_id.clone(),
        api_origin: "https://airsim.example.test".to_string(),
        device_origin: "https://device.airsim.example.test".to_string(),
        media_origin: "https://media.airsim.example.test".to_string(),
        device_ca_pem: ca_cert.pem(),
        server_ca_pem: ca_cert.pem(),
        nonce: nonce.clone(),
        expires_at: exp,
    };

    let (prepared, code) = prov.prepare(prep_req.clone());
    assert_eq!(code, 200);
    let prepared = prepared.unwrap();
    assert_eq!(prepared.module_id, id.module_id);

    // Sign leaf certificate for the module's Ed25519 public key with exact SAN URI + ClientAuth EKU
    let sign_leaf = |days: i64| -> (String, String) {
        let mod_kp = KeyPair::try_from(id.pkcs8_der().as_slice()).unwrap();
        let mut lp = CertificateParams::default();
        lp.is_ca = IsCa::ExplicitNoCa;
        lp.subject_alt_names = vec![SanType::URI(
            format!("urn:airsim:{srv_id}:module:{}", id.module_id).try_into().unwrap(),
        )];
        lp.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
        lp.not_before = OffsetDateTime::now_utc() - time::Duration::minutes(5);
        lp.not_after = OffsetDateTime::now_utc() + time::Duration::days(days);
        let leaf = lp.signed_by(&mod_kp, &ca_issuer).unwrap();
        let leaf_der = leaf.der().as_ref();
        let mut h = Sha256::new();
        h.update(leaf_der);
        let cert_sha = hex::encode(h.finalize());
        let commit_msg = format!(
            "airsim-v2-r4-commit\n{req_id}\n{srv_id}\n{}\n{cert_sha}\n{nonce}\n",
            id.module_id
        );
        let rcpt = ca_sk.sign(commit_msg.as_bytes());
        let rcpt_b64 = base64::engine::general_purpose::STANDARD.encode(rcpt.to_bytes());
        (leaf.pem(), rcpt_b64)
    };

    let (leaf_pem, rcpt_b64) = sign_leaf(30);
    let bundle = Bundle {
        request_id: req_id.clone(),
        server_id: srv_id.clone(),
        module_id: id.module_id.clone(),
        certificate_pem: leaf_pem,
        receipt_base64: rcpt_b64,
    };
    assert_eq!(prov.activate(bundle), 200);
    assert!(prov.view().configured);

    // Cold-boot reload from disk + mTLS ClientConfig build
    let prov2 = Provisioner::open(id.clone(), cloud_path, CLOUD_PROFILE.to_string());
    let saved = prov2.current_config().unwrap();
    assert!(prov2.validate_for_connect(&saved).is_ok());
    let tls_cfg = prov2.build_tls_client_config(&saved, true);
    assert!(tls_cfg.is_ok(), "mTLS ClientConfig build failed: {:?}", tls_cfg.err());

    // 90-day renewal path
    let (r_id, r_nonce, r_csr) = prov2.renewal_request().unwrap();
    assert_eq!(r_id, req_id);
    assert_eq!(r_nonce, nonce);
    assert!(r_csr.contains("BEGIN CERTIFICATE REQUEST"));
    let (new_leaf_pem, new_rcpt_b64) = sign_leaf(90);
    let renewed_exp = prov2
        .renew(Bundle {
            request_id: req_id.clone(),
            server_id: srv_id.clone(),
            module_id: id.module_id.clone(),
            certificate_pem: new_leaf_pem,
            receipt_base64: new_rcpt_b64,
        })
        .unwrap();
    assert!(renewed_exp > OffsetDateTime::now_utc() + time::Duration::days(80));

    // Pairing proof endpoint (`/v2/local/pairing/authorize`)
    let pair_req_id = uuid_v4().unwrap();
    let pair_nonce = "2".repeat(64);
    let poll_hash = "3".repeat(64);
    let pair_exp = (OffsetDateTime::now_utc() + time::Duration::seconds(180))
        .format(&Rfc3339)
        .unwrap();
    let body = serde_json::to_vec(&serde_json::json!({
        "request_id": pair_req_id,
        "server_id": srv_id,
        "module_id": id.module_id,
        "nonce": pair_nonce,
        "expires_at": pair_exp,
        "poll_token_hash": poll_hash,
    }))
    .unwrap();
    let mut headers = HashMap::new();
    headers.insert("content-type".to_string(), "application/json".to_string());
    let req = HttpRequest {
        method: "POST".to_string(),
        target: "/v2/local/pairing/authorize".to_string(),
        path: "/v2/local/pairing/authorize".to_string(),
        query: String::new(),
        headers,
        body,
    };
    let resp = prov2.handle_local_route(&req).unwrap();
    assert_eq!(resp.status, 200);
    let v: serde_json::Value = serde_json::from_slice(&resp.body).unwrap();
    let proof_b64 = v["proof_base64"].as_str().unwrap();
    let sig_bytes = base64::engine::general_purpose::STANDARD.decode(proof_b64).unwrap();
    let sig = Signature::from_slice(&sig_bytes).unwrap();
    let expected_msg = format!(
        "airsim-v2-pairing\n{pair_req_id}\n{srv_id}\n{}\n{pair_nonce}\n{pair_exp}\n{poll_hash}\n",
        id.module_id
    );
    id.verifying_key().verify(expected_msg.as_bytes(), &sig).unwrap();

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn replays_harsh_eg25_qci9_lte_bursts_with_zero_resyncs_zero_late_and_minimal_plc() {
    // Reproduces the exact measured EG25 4G LTE QCI=9 call pattern:
    // - 1000 frames (20 s) with recurring 160-320 ms RLC bursts every ~1.2 s + a 640 ms spike
    // - Oscillating EG25 pcm5p ALSA delay (32..60 ms)
    // - Periodic RTP marker bits (`start_of_talkspurt = true` every 150 frames)
    let mut enc = OpusEncoder::new().unwrap();
    let mut dec = OpusDecoder::new().unwrap();
    let mut jb = AdaptiveJitterBuffer::new(true);
    let mut wsola = WsolaProcessor::new();

    let mut arrivals: Vec<(u64, IncomingOpusPacket)> = Vec::new();
    let mut burst_hold_until = 0u64;
    for f in 0..1000u64 {
        let pcm = synth_voice_frame(f);
        let mut pkt_bytes = [0u8; MAX_OPUS_PACKET];
        let len = enc.encode(&pcm, &mut pkt_bytes).unwrap();
        let nom = f * 20;
        if f == 450 {
            burst_hold_until = nom + 640; // 640 ms extreme RLC stall!
        } else if f > 20 && f % 60 == 0 && nom >= burst_hold_until {
            let dur = 180 + ((f / 60) % 4) * 40; // 180..300 ms recurring bursts
            burst_hold_until = nom + dur;
        }
        let rx_ms = nom.max(burst_hold_until);
        let mut in_pkt = IncomingOpusPacket {
            bytes: [0u8; MAX_OPUS_PACKET],
            len: len as u16,
            rtp_time_48k: f * TICKS_PER_FRAME_48K,
            rx_at_ms: rx_ms,
            start_of_talkspurt: f == 0 || f % 150 == 0,
        };
        in_pkt.bytes[..len].copy_from_slice(&pkt_bytes[..len]);
        arrivals.push((rx_ms, in_pkt));
    }
    arrivals.sort_by_key(|(t, _)| *t);

    let mut arr_idx = 0usize;
    let mut decoded = [0i16; OPUS_FRAME_SAMPLES];
    let mut wsola_out = [0i16; MAX_WSOLA_OUT];
    let mut play_time_ms = 0u64;
    let mut step = 0u32;

    while play_time_ms < 20_500 {
        while arr_idx < arrivals.len() && arrivals[arr_idx].0 <= play_time_ms {
            jb.push(&arrivals[arr_idx].1);
            arr_idx += 1;
        }
        // Simulate real EG25 ALSA pcm5p delay oscillating between 32 ms and 60 ms!
        let alsa_delay = 32 + ((step * 7) % 29);
        step += 1;
        if let Some(frame) = jb.pop(play_time_ms, alsa_delay) {
            let slice = if frame.len > 0 { Some(&frame.data[..frame.len]) } else { None };
            dec.decode(slice, frame.kind, &mut decoded).unwrap();
            let n = wsola.process(&decoded, frame.wsola_mode, frame.wsola_force, &mut wsola_out);
            condition_uplink_pcm(&mut wsola_out[..n]);
            play_time_ms += (n as u64 * 1000) / 16000;
        } else {
            play_time_ms += 20;
        }
    }

    assert_eq!(jb.stats.playout_resyncs, 0, "must never resync/silence-cut on LTE bursts or markers");
    assert_eq!(jb.stats.packets_late, 0, "NetEq empty-buffer hold must drop 0 delayed voice frames");
    assert_eq!(jb.stats.queue_drops, 0);
    // Only the single 640 ms spike (exceeding 440 ms cushion) may trigger brief PLC (~10-18 frames),
    // whereas ALL recurring 180-300 ms bursts must play with ZERO PLC!
    assert!(
        jb.stats.plc_frames <= 25,
        "expected <=25 PLC frames even with 640ms spike + 15 bursts, got {}",
        jb.stats.plc_frames
    );
}
