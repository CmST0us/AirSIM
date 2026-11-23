use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Cache-line padded atomic index to avoid false sharing between RT producer/consumer threads.
#[repr(align(64))]
struct AlignedAtomic(AtomicUsize);

/// Fixed-capacity, zero-allocation lock-free Single-Producer Single-Consumer ring buffer.
/// Capacity `N` MUST be a power of two.
pub struct SpscRing<T, const N: usize> {
    head: AlignedAtomic,
    tail: AlignedAtomic,
    buf: Box<[UnsafeCell<MaybeUninit<T>>; N]>,
}

unsafe impl<T: Send, const N: usize> Send for SpscRing<T, N> {}
unsafe impl<T: Send, const N: usize> Sync for SpscRing<T, N> {}

impl<T, const N: usize> SpscRing<T, N> {
    pub fn new() -> Self {
        assert!(N.is_power_of_two() && N >= 2, "SpscRing capacity must be power of two >= 2");
        let mut v = Vec::with_capacity(N);
        for _ in 0..N {
            v.push(UnsafeCell::new(MaybeUninit::uninit()));
        }
        let boxed: Box<[UnsafeCell<MaybeUninit<T>>; N]> = v
            .into_boxed_slice()
            .try_into()
            .ok()
            .expect("exact length");
        Self {
            head: AlignedAtomic(AtomicUsize::new(0)),
            tail: AlignedAtomic(AtomicUsize::new(0)),
            buf: boxed,
        }
    }

    #[inline]
    pub fn push(&self, value: T) -> Result<(), T> {
        let tail = self.tail.0.load(Ordering::Relaxed);
        let head = self.head.0.load(Ordering::Acquire);
        if tail.wrapping_sub(head) >= N {
            return Err(value);
        }
        let idx = tail & (N - 1);
        unsafe {
            (*self.buf[idx].get()).write(value);
        }
        self.tail.0.store(tail.wrapping_add(1), Ordering::Release);
        Ok(())
    }

    #[inline]
    pub fn pop(&self) -> Option<T> {
        let head = self.head.0.load(Ordering::Relaxed);
        let tail = self.tail.0.load(Ordering::Acquire);
        if head == tail {
            return None;
        }
        let idx = head & (N - 1);
        let value = unsafe { (*self.buf[idx].get()).assume_init_read() };
        self.head.0.store(head.wrapping_add(1), Ordering::Release);
        Some(value)
    }

    #[inline]
    pub fn len(&self) -> usize {
        let tail = self.tail.0.load(Ordering::Acquire);
        let head = self.head.0.load(Ordering::Acquire);
        tail.wrapping_sub(head)
    }
}

impl<T, const N: usize> Drop for SpscRing<T, N> {
    fn drop(&mut self) {
        while self.pop().is_some() {}
    }
}

pub const MAX_OPUS_PACKET: usize = 512;

/// Capture thread -> WebRTC thread pre-allocated packet slot (zero heap alloc).
#[derive(Clone, Copy)]
pub struct EncodedAudioPacket {
    pub bytes: [u8; MAX_OPUS_PACKET],
    pub len: u16,
    pub seq: u64,
    pub start_of_talkspurt: bool,
}

impl EncodedAudioPacket {
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}

/// WebRTC thread -> Playback thread pre-allocated packet slot (zero heap alloc).
#[derive(Clone, Copy)]
pub struct IncomingOpusPacket {
    pub bytes: [u8; MAX_OPUS_PACKET],
    pub len: u16,
    pub rtp_time_48k: u64,
    pub rx_at_ms: u64,
    pub start_of_talkspurt: bool,
}

impl IncomingOpusPacket {
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}
