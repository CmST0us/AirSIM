use crate::audio::opus::OPUS_FRAME_SAMPLES;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioProfile {
    Eg25Qdc507,
    Rm500uEmbedded,
    MockLoopback,
}

impl AudioProfile {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "eg25-qdc507" => Some(Self::Eg25Qdc507),
            "rm500u-embedded" => Some(Self::Rm500uEmbedded),
            "mock" => Some(Self::MockLoopback),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::Eg25Qdc507 => "eg25-qdc507",
            Self::Rm500uEmbedded => "rm500u-embedded",
            Self::MockLoopback => "mock",
        }
    }
}

/// Elevate the current OS thread to Linux `SCHED_FIFO` real-time priority `prio` (e.g. 10).
/// Silently falls back to default scheduling when unprivileged or on non-Linux hosts.
pub fn set_realtime_priority(prio: i32) {
    #[cfg(target_os = "linux")]
    unsafe {
        let mut param: libc::sched_param = std::mem::zeroed();
        param.sched_priority = prio;
        let _ = libc::pthread_setschedparam(libc::pthread_self(), libc::SCHED_FIFO, &param);
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = prio;
    }
}

/// Reset EG25 audio route (equivalent to `airsim-audiod --cleanup --profile eg25-qdc507`).
pub fn cleanup_route(profile: AudioProfile) -> Result<(), &'static str> {
    #[cfg(target_os = "linux")]
    {
        if profile == AudioProfile::Eg25Qdc507 {
            let rc = unsafe { linux_hw::airsim_rs_eg25_route_reset() };
            return if rc == 0 { Ok(()) } else { Err("route_reset_failed") };
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = profile;
        Ok(())
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct PcmStats {
    pub capture_samples: u64,
    pub playback_samples: u64,
    pub capture_xruns: u64,
    pub playback_xruns: u64,
}

#[cfg(target_os = "linux")]
mod linux_hw {
    use super::*;
    use std::ffi::{c_int, c_long, c_uint, c_void};
    use std::fs;
    use std::ptr::NonNull;
    use std::time::{Duration, Instant};

    pub const PCM_OUT: c_uint = 0x0000_0000;
    pub const PCM_IN: c_uint = 0x1000_0000;
    pub const PCM_MMAP: c_uint = 0x0000_0001;
    pub const PCM_NONBLOCK: c_uint = 0x0000_0010;
    pub const PCM_NORESTART: c_uint = 0x0000_0002;

    #[repr(C)]
    pub struct RawPcm {
        _private: [u8; 0],
    }

    unsafe extern "C" {
        pub fn airsim_rs_pcm_open(
            card: c_uint,
            device: c_uint,
            flags: c_uint,
            rate: c_uint,
            period_size: c_uint,
            period_count: c_uint,
            start_threshold: c_uint,
            stop_threshold: c_uint,
            avail_min: c_uint,
        ) -> *mut RawPcm;
        pub fn airsim_rs_pcm_close(p: *mut RawPcm) -> c_int;
        pub fn airsim_rs_pcm_prepare(p: *mut RawPcm) -> c_int;
        pub fn airsim_rs_pcm_start(p: *mut RawPcm) -> c_int;
        pub fn airsim_rs_pcm_poll_fd(p: *mut RawPcm) -> c_int;
        pub fn airsim_rs_pcm_delay(p: *mut RawPcm) -> c_long;
        #[allow(dead_code)]
        pub fn airsim_rs_pcm_buffer_size(p: *mut RawPcm) -> c_uint;
        pub fn airsim_rs_pcm_readi(
            p: *mut RawPcm,
            data: *mut c_void,
            frames: c_uint,
            out_errno: *mut c_int,
        ) -> c_int;
        pub fn airsim_rs_pcm_writei(
            p: *mut RawPcm,
            data: *const c_void,
            frames: c_uint,
            out_errno: *mut c_int,
        ) -> c_int;
        pub fn airsim_rs_eg25_route_start(rate: c_uint) -> c_int;
        pub fn airsim_rs_eg25_route_stop();
        pub fn airsim_rs_eg25_route_reset() -> c_int;
    }

    pub fn read_voice_rate(path: &str) -> Result<u32, &'static str> {
        let text = fs::read_to_string(path).map_err(|_| "voice_params_unreadable")?;
        let mut has_fmt = false;
        let mut has_ch = false;
        let mut rate = 0u32;
        for line in text.lines() {
            let line = line.trim();
            if line == "closed" {
                return Err("voice_closed");
            }
            if let Some(rest) = line.strip_prefix("format:") {
                if rest.trim() == "S16_LE" {
                    has_fmt = true;
                }
            } else if let Some(rest) = line.strip_prefix("channels:") {
                if rest.trim() == "1" {
                    has_ch = true;
                }
            } else if let Some(rest) = line.strip_prefix("rate:") {
                let first = rest.split_whitespace().next().unwrap_or("");
                if first == "16000" {
                    rate = 16000;
                } else if first == "8000" {
                    rate = 8000;
                }
            }
        }
        if has_fmt && has_ch && (rate == 8000 || rate == 16000) {
            Ok(rate)
        } else {
            Err("voice_params_invalid")
        }
    }

    pub struct AlsaHandle {
        raw: NonNull<RawPcm>,
        is_input: bool,
        pub rate: u32,
        pub buffer_frames: u32,
        pub start_threshold: u32,
        xrun_times: [Option<Instant>; 3],
        xrun_idx: usize,
        pub xruns: u64,
        pub total_samples: u64,
    }

    unsafe impl Send for AlsaHandle {}

    impl AlsaHandle {
        pub fn open(
            device: u32,
            is_input: bool,
            use_mmap: bool,
            rate: u32,
            period_size: u32,
            period_count: u32,
            start_threshold: u32,
        ) -> Result<Self, &'static str> {
            let buffer_frames = period_size * period_count;
            let mut flags = if is_input { PCM_IN } else { PCM_OUT } | PCM_NONBLOCK | PCM_NORESTART;
            if use_mmap {
                flags |= PCM_MMAP;
            }
            let ptr = unsafe {
                airsim_rs_pcm_open(
                    0,
                    device,
                    flags,
                    rate,
                    period_size,
                    period_count,
                    start_threshold,
                    buffer_frames,
                    period_size,
                )
            };
            let raw = NonNull::new(ptr).ok_or("pcm_open_failed")?;
            if unsafe { airsim_rs_pcm_prepare(raw.as_ptr()) } != 0 {
                unsafe { airsim_rs_pcm_close(raw.as_ptr()) };
                return Err("pcm_prepare_failed");
            }
            if is_input && unsafe { airsim_rs_pcm_start(raw.as_ptr()) } != 0 {
                unsafe { airsim_rs_pcm_close(raw.as_ptr()) };
                return Err("pcm_start_failed");
            }
            Ok(Self {
                raw,
                is_input,
                rate,
                buffer_frames,
                start_threshold,
                xrun_times: [None; 3],
                xrun_idx: 0,
                xruns: 0,
                total_samples: 0,
            })
        }

        pub fn delay_ms(&self) -> u32 {
            let d = unsafe { airsim_rs_pcm_delay(self.raw.as_ptr()) };
            if d <= 0 || (d as u32) > self.buffer_frames {
                0
            } else {
                ((d as u64) * 1000 / (self.rate as u64)) as u32
            }
        }

        pub fn wait_playback_headroom(&self, stop: &AtomicBool) -> Result<(), &'static str> {
            let target_frames = (self.rate * 32 / 1000).max(self.start_threshold);
            let since = Instant::now();
            while !stop.load(Ordering::Relaxed) {
                let delay = unsafe { airsim_rs_pcm_delay(self.raw.as_ptr()) };
                if delay <= 0 || (delay as u32) > self.buffer_frames || (delay as u32) <= target_frames {
                    return Ok(());
                }
                if since.elapsed() > Duration::from_secs(2) {
                    return Err("pcm_stalled");
                }
                let excess_ms = ((delay as u32 - target_frames) * 1000 / self.rate).clamp(2, 8);
                unsafe {
                    libc::poll(std::ptr::null_mut(), 0, excess_ms as c_int);
                }
            }
            Err("stopped")
        }

        fn wait_poll(&self) -> Result<(), &'static str> {
            let fd = unsafe { airsim_rs_pcm_poll_fd(self.raw.as_ptr()) };
            let mut pfd = libc::pollfd {
                fd,
                events: if self.is_input { libc::POLLIN } else { libc::POLLOUT },
                revents: 0,
            };
            let r = unsafe { libc::poll(&mut pfd, 1, 10) };
            if r < 0 {
                let e = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if e == libc::EINTR {
                    return Ok(());
                }
                return Err("pcm_io");
            }
            if (pfd.revents & libc::POLLNVAL) != 0 {
                return Err("pcm_io");
            }
            Ok(())
        }

        fn recover_xrun(&mut self) -> Result<(), &'static str> {
            self.xruns += 1;
            let now = Instant::now();
            // Allow at most 3 xruns within any 10-second sliding window.
            if let Some(oldest) = self.xrun_times[self.xrun_idx] {
                if now.duration_since(oldest) < Duration::from_secs(10) {
                    return Err("xrun_budget");
                }
            }
            self.xrun_times[self.xrun_idx] = Some(now);
            self.xrun_idx = (self.xrun_idx + 1) % 3;
            if unsafe { airsim_rs_pcm_prepare(self.raw.as_ptr()) } != 0 {
                return Err("pcm_io");
            }
            if self.is_input && unsafe { airsim_rs_pcm_start(self.raw.as_ptr()) } != 0 {
                return Err("pcm_io");
            }
            Ok(())
        }

        /// Reads exactly `out.len()` samples. Returns `Ok(true)` if an XRUN occurred and recovered.
        pub fn read_exact(&mut self, out: &mut [i16], stop: &AtomicBool) -> Result<bool, &'static str> {
            let mut offset = 0usize;
            let mut last = Instant::now();
            while offset < out.len() && !stop.load(Ordering::Relaxed) {
                let mut err = 0i32;
                let n = unsafe {
                    airsim_rs_pcm_readi(
                        self.raw.as_ptr(),
                        out.as_mut_ptr().add(offset) as *mut c_void,
                        (out.len() - offset) as c_uint,
                        &mut err,
                    )
                };
                if n > 0 {
                    offset += n as usize;
                    self.total_samples += n as u64;
                    last = Instant::now();
                    continue;
                }
                if n == 0 || err == libc::EAGAIN || err == libc::EINTR {
                    if last.elapsed() > Duration::from_secs(2) {
                        return Err("pcm_stalled");
                    }
                    self.wait_poll()?;
                    continue;
                }
                if err == libc::EPIPE || err == libc::ESTRPIPE {
                    self.recover_xrun()?;
                    return Ok(true);
                }
                return Err("pcm_io");
            }
            if stop.load(Ordering::Relaxed) {
                Err("stopped")
            } else {
                Ok(false)
            }
        }

        /// Writes variable-length `samples` (supports WSOLA `320 ± P` frames directly!).
        pub fn write_all(&mut self, samples: &[i16], stop: &AtomicBool) -> Result<bool, &'static str> {
            let mut offset = 0usize;
            let mut last = Instant::now();
            while offset < samples.len() && !stop.load(Ordering::Relaxed) {
                let mut err = 0i32;
                let n = unsafe {
                    airsim_rs_pcm_writei(
                        self.raw.as_ptr(),
                        samples.as_ptr().add(offset) as *const c_void,
                        (samples.len() - offset) as c_uint,
                        &mut err,
                    )
                };
                if n > 0 {
                    offset += n as usize;
                    self.total_samples += n as u64;
                    last = Instant::now();
                    continue;
                }
                if n == 0 || err == libc::EAGAIN || err == libc::EINTR {
                    if last.elapsed() > Duration::from_secs(2) {
                        return Err("pcm_stalled");
                    }
                    self.wait_poll()?;
                    continue;
                }
                if err == libc::EPIPE || err == libc::ESTRPIPE {
                    self.recover_xrun()?;
                    return Ok(true);
                }
                return Err("pcm_io");
            }
            if stop.load(Ordering::Relaxed) {
                Err("stopped")
            } else {
                Ok(false)
            }
        }
    }

    impl Drop for AlsaHandle {
        fn drop(&mut self) {
            unsafe { airsim_rs_pcm_close(self.raw.as_ptr()) };
        }
    }

    pub struct Eg25RouteGuard;
    impl Drop for Eg25RouteGuard {
        fn drop(&mut self) {
            unsafe { airsim_rs_eg25_route_stop() };
        }
    }

    pub fn open_hardware(
        profile: AudioProfile,
    ) -> Result<(AlsaHandle, AlsaHandle, Option<Eg25RouteGuard>), &'static str> {
        match profile {
            AudioProfile::Eg25Qdc507 => {
                if unsafe { airsim_rs_eg25_route_start(16000) } != 0 {
                    return Err("pcm_open");
                }
                let guard = Eg25RouteGuard;
                let playback_rate = read_voice_rate("/proc/asound/card0/pcm4p/sub0/hw_params")?;
                let cap = AlsaHandle::open(6, true, true, 16000, 256, 8, 256)?;
                let pb = AlsaHandle::open(5, false, true, playback_rate, 256, 8, 512)?;
                Ok((cap, pb, Some(guard)))
            }
            AudioProfile::Rm500uEmbedded => {
                let playback_rate = read_voice_rate("/proc/asound/card0/pcm5p/sub0/hw_params")?;
                let cap = AlsaHandle::open(9, true, false, 8000, 320, 2, 320)?;
                let pb = AlsaHandle::open(55, false, false, playback_rate, 320, 2, 640)?;
                Ok((cap, pb, None))
            }
            AudioProfile::MockLoopback => Err("mock_use_synthetic"),
        }
    }
}

/// Platform-abstracted capture/playback pair: real TinyALSA on Linux, deterministic
/// 20 ms synthetic tone/recorder backend for host macOS & WebRTC interop tests.
pub enum CaptureBackend {
    #[cfg(target_os = "linux")]
    Hardware(linux_hw::AlsaHandle),
    Synthetic {
        phase: usize,
        next_tick: std::time::Instant,
    },
}

pub enum PlaybackBackend {
    #[cfg(target_os = "linux")]
    Hardware(linux_hw::AlsaHandle),
    Synthetic {
        received_samples: u64,
        non_zero_samples: u64,
        next_tick: std::time::Instant,
    },
}

pub struct RouteGuard {
    #[cfg(target_os = "linux")]
    _inner: Option<linux_hw::Eg25RouteGuard>,
}

pub fn open_audio_backends(
    profile: AudioProfile,
) -> Result<(CaptureBackend, PlaybackBackend, RouteGuard), &'static str> {
    if profile == AudioProfile::MockLoopback {
        let now = std::time::Instant::now();
        return Ok((
            CaptureBackend::Synthetic {
                phase: 0,
                next_tick: now,
            },
            PlaybackBackend::Synthetic {
                received_samples: 0,
                non_zero_samples: 0,
                next_tick: now,
            },
            RouteGuard {
                #[cfg(target_os = "linux")]
                _inner: None,
            },
        ));
    }
    #[cfg(target_os = "linux")]
    {
        let (cap, pb, guard) = linux_hw::open_hardware(profile)?;
        Ok((
            CaptureBackend::Hardware(cap),
            PlaybackBackend::Hardware(pb),
            RouteGuard { _inner: guard },
        ))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = profile;
        Err("hardware_audio_linux_only")
    }
}

impl CaptureBackend {
    pub fn sample_rate(&self) -> u32 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.rate,
            Self::Synthetic { .. } => 16000,
        }
    }

    pub fn xruns(&self) -> u64 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.xruns,
            Self::Synthetic { .. } => 0,
        }
    }

    /// Reads one 20 ms frame (320 samples @ 16 kHz, or 160 samples @ 8 kHz upsampled to 320).
    /// Returns `Ok(xrun_recovered)`.
    pub fn read_frame_16k(
        &mut self,
        out: &mut [i16; OPUS_FRAME_SAMPLES],
        prev_8k: &mut i16,
        stop: &Arc<AtomicBool>,
    ) -> Result<bool, &'static str> {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => {
                if h.rate == 16000 {
                    h.read_exact(out, stop)
                } else {
                    let mut raw8 = [0i16; 160];
                    let xrun = h.read_exact(&mut raw8, stop)?;
                    if xrun {
                        *prev_8k = 0;
                    } else {
                        crate::audio::wsola::expand_8k_to_16k(&raw8, prev_8k, out);
                    }
                    Ok(xrun)
                }
            }
            Self::Synthetic { phase, next_tick } => {
                let _ = prev_8k;
                let now = std::time::Instant::now();
                if *next_tick > now {
                    let sleep = (*next_tick - now).min(std::time::Duration::from_millis(20));
                    std::thread::sleep(sleep);
                }
                *next_tick += std::time::Duration::from_millis(20);
                if stop.load(Ordering::Relaxed) {
                    return Err("stopped");
                }
                for s in out.iter_mut() {
                    let t = (*phase as f64) / 16000.0;
                    *s = (10000.0 * (2.0 * std::f64::consts::PI * 440.0 * t).sin()) as i16;
                    *phase = phase.wrapping_add(1);
                }
                Ok(false)
            }
        }
    }
}

impl PlaybackBackend {
    pub fn sample_rate(&self) -> u32 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.rate,
            Self::Synthetic { .. } => 16000,
        }
    }

    pub fn xruns(&self) -> u64 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.xruns,
            Self::Synthetic { .. } => 0,
        }
    }

    pub fn delay_ms(&self) -> u32 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.delay_ms(),
            Self::Synthetic { .. } => 32,
        }
    }

    pub fn wait_headroom(&self, stop: &Arc<AtomicBool>) -> Result<(), &'static str> {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => h.wait_playback_headroom(stop),
            Self::Synthetic { next_tick, .. } => {
                let now = std::time::Instant::now();
                if *next_tick > now && !stop.load(Ordering::Relaxed) {
                    std::thread::sleep((*next_tick - now).min(std::time::Duration::from_millis(20)));
                }
                if stop.load(Ordering::Relaxed) {
                    Err("stopped")
                } else {
                    Ok(())
                }
            }
        }
    }

    pub fn write_samples_16k(
        &mut self,
        samples_16k: &[i16],
        profile: AudioProfile,
        prev_16k: &mut i16,
        stop: &Arc<AtomicBool>,
    ) -> Result<bool, &'static str> {
        let mut work = [0i16; crate::audio::wsola::MAX_WSOLA_OUT];
        let n = samples_16k.len().min(work.len());
        work[..n].copy_from_slice(&samples_16k[..n]);

        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(h) => {
                let write_len = if h.rate == 8000 {
                    let mut down = [0i16; crate::audio::wsola::MAX_WSOLA_OUT / 2];
                    let dn = crate::audio::wsola::reduce_16k_to_8k(&work[..n], prev_16k, &mut down);
                    if profile == AudioProfile::Eg25Qdc507 {
                        crate::audio::wsola::condition_uplink_pcm(&mut down[..dn]);
                    }
                    return h.write_all(&down[..dn], stop);
                } else {
                    if profile == AudioProfile::Eg25Qdc507 {
                        crate::audio::wsola::condition_uplink_pcm(&mut work[..n]);
                    }
                    n
                };
                h.write_all(&work[..write_len], stop)
            }
            Self::Synthetic {
                received_samples,
                non_zero_samples,
                next_tick,
            } => {
                let _ = (profile, prev_16k, stop);
                *received_samples += n as u64;
                *non_zero_samples += work[..n].iter().filter(|&&v| v != 0).count() as u64;
                let frame_us = (n as u64 * 1_000_000) / 16000;
                *next_tick += std::time::Duration::from_micros(frame_us);
                Ok(false)
            }
        }
    }

    pub fn synthetic_non_zero_samples(&self) -> u64 {
        match self {
            #[cfg(target_os = "linux")]
            Self::Hardware(_) => 0,
            Self::Synthetic { non_zero_samples, .. } => *non_zero_samples,
        }
    }
}
