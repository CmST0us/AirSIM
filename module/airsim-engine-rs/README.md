# AirSIM Unified Real-Time Rust Module Engine (`module/airsim-engine-rs`)

Single static, zero-GC real-time module engine replacing the legacy Go `airsim-agent` + C `airsim-audiod` dual-process architecture on **EG25 QDC507** (`armv7-unknown-linux-musleabihf`, Cortex-A7 hard-float VFPv4/NEON) and **RM500U** (`aarch64-unknown-linux-musl`).

## Architecture Highlights

1. **Zero-GC Real-Time Media Data Plane (`SCHED_FIFO` priority 10)**:
   - **WebRTC + TURN I/O Thread** ([src/rtc/session.rs](src/rtc/session.rs), [src/rtc/turn.rs](src/rtc/turn.rs)):
     - Sans-I/O `str0m` with native **RFC 2198 RED depth=2** (`set_red_distances(&[1, 2])`) and `Opus 48000/2` (`maxaveragebitrate=64000;maxplaybackrate=16000;useinbandfec=1;stereo=0`).
     - Pure-Rust RFC 5766/8656 TURN client supporting **UDP and TCP** (`CreatePermission`, `ChannelBind`, 4-byte `ChannelData` fast path, automatic lifetime refresh) for cellular modules behind carrier NAT, plus host UDP direct mode for USB local calls.
     - Single `poll()` loop multiplexing UDP/TCP socket + `eventfd` wakeup from capture thread.
   - **Capture + Opus Encode Thread** ([src/audio/mod.rs](src/audio/mod.rs), [src/audio/opus.rs](src/audio/opus.rs)):
     - Direct TinyALSA mmap (`pcm6c` on EG25, `pcm9c` on RM500U) -> vendored fixed-point `libopus 1.5.2` (`64 kbps` VBR wideband, `OPUS_APPLICATION_AUDIO`, `OPUS_SIGNAL_VOICE`, complexity 4, `INBAND_FEC=1`, `PACKET_LOSS_PERC=5`, `DTX=0`) -> pre-allocated lock-free SPSC ring (`SpscRing`) + `eventfd` kick.
   - **Adaptive Jitter + Opus Decode + Pitch-Synchronous WSOLA + Playback Thread** ([src/audio/jitter.rs](src/audio/jitter.rs), [src/audio/wsola.rs](src/audio/wsola.rs), [src/audio/alsa.rs](src/audio/alsa.rs)):
     - 64-slot media-time adaptive playout buffer (USB floor 40 ms, Cellular TURN floor 60 ms / start 80 ms / ceiling 220 ms) with LBRR in-band FEC -> Opus PLC and zero late-packet starvation.
     - **16 kHz Pitch-Synchronous WSOLA** (4 ms raised-cosine crossfade, `[32..140]` sample pitch lag search) coupled to BOTH jitter occupancy and ALSA `pcm_get_delay()` feedback — smoothly absorbs hardware crystal skew and LTE jitter bursts without dropping frames or hard-resyncing.
     - **EG25 QDSP6 Tx Conditioner** (`-3.01 dB` linear headroom + C¹ quadratic soft-knee limiter, ceiling `-4.8 dBFS`) preventing clipping inside Qualcomm QDSP6 `acdb_id=4`.
2. **Single-Threaded Tokio Control Plane**:
   - Full drop-in compatibility with existing ECS control/media (`airsim.control.v2`), SkySIM iOS v2, USB local HTTPS (`192.168.225.1:8577`), Unix local socket (`/run/airsim-v2/control.sock`), WebUSB installer, `run-agent.sh`, and `/usrdata/airsim-v2` persistent files (`identity.json`, `cloud.json`, `commands.json`, `eg25-sms-seen`, `usb-grants.json`, `usb-tls.pem`, `usb-commands.json`).
   - Ships with a 769-byte `airsim-audiod` compatibility shim ([scripts/airsim-audiod-shim.sh](scripts/airsim-audiod-shim.sh)) for installer manifest parity and `--cleanup --profile eg25-qdc507`.

## Build & Verify

```sh
# Host unit + integration tests (Opus64, WSOLA, 11 network impairment profiles, str0m RED=2 loopback, SMS PDU)
cargo test

# EG25 QDC507 static ARMv7 Cortex-A7 musl release binary (~4.8 MB vs 12.1 MB Go+C)
sh scripts/build-eg25.sh

# RM500U static ARM64 musl release binary
sh scripts/build-rm500.sh
```
