package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"context"
	"encoding/binary"
	"sync"
	"time"
)

const (
	playoutPeriod = 20 * time.Millisecond
	playoutBuffer = 40 * time.Millisecond
	playoutMaxAge = 100 * time.Millisecond
	// Frames from the App cross the module's cellular downlink; a deeper buffer
	// absorbs its jitter instead of concealing late frames.
	jitterBuffer   = 100 * time.Millisecond
	jitterMaxAge   = 240 * time.Millisecond
	jitterCapacity = 12
)

type queuedPCM struct {
	frame   media.Frame
	arrived time.Time
}

// Each direction owns a separate queue. The lock only protects memory, never I/O.
type playoutQueue struct {
	mu     sync.Mutex
	frames []queuedPCM
	size   int
	first  time.Time
	buffer time.Duration
	maxAge time.Duration
	ready  chan struct{}
	counts *bridgeCounters
}

func newPlayoutQueue(counts *bridgeCounters) *playoutQueue {
	return &playoutQueue{frames: make([]queuedPCM, 5), buffer: playoutBuffer, maxAge: playoutMaxAge, ready: make(chan struct{}), counts: counts}
}
func newJitterQueue(counts *bridgeCounters) *playoutQueue {
	return &playoutQueue{frames: make([]queuedPCM, jitterCapacity), buffer: jitterBuffer, maxAge: jitterMaxAge, ready: make(chan struct{}), counts: counts}
}
func (q *playoutQueue) push(f media.Frame, now time.Time) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.first.IsZero() {
		q.first = now
		close(q.ready)
	}
	if q.size == len(q.frames) {
		copy(q.frames, q.frames[1:])
		q.size--
		q.counts.drops.Add(1)
	}
	q.frames[q.size] = queuedPCM{f, now}
	q.size++
}
func (q *playoutQueue) pop(now time.Time) (media.Frame, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.size > 0 {
		item := q.frames[0]
		copy(q.frames, q.frames[1:q.size])
		q.size--
		q.frames[q.size] = queuedPCM{}
		if now.Sub(item.arrived) > q.maxAge {
			q.counts.drops.Add(1)
			continue
		}
		return item.frame, true
	}
	return media.Frame{}, false
}
func (q *playoutQueue) start() time.Time {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.first.Add(q.buffer)
}

type playoutClock interface {
	Now() time.Time
	Wait(context.Context, time.Time) bool
}
type realPlayoutClock struct{}

func (realPlayoutClock) Now() time.Time { return time.Now() }
func (realPlayoutClock) Wait(ctx context.Context, target time.Time) bool {
	timer := time.NewTimer(time.Until(target))
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return ctx.Err() == nil
	}
}

// catchUpSpacing separates frames written back to back while draining a backlog.
const catchUpSpacing = 5 * time.Millisecond

// futurePlayoutSlot preserves the original grid and skips every elapsed slot.
func futurePlayoutSlot(base, now time.Time) time.Time {
	if now.Before(base) {
		return base
	}
	return base.Add((now.Sub(base)/playoutPeriod + 1) * playoutPeriod)
}

// Small wakeup errors do not move the grid. A late wakeup or slow write drains
// the missed slots one frame at a time, 5 ms apart, so a busy CPU delays audio
// instead of discarding it; beyond the queue age bound the grid resynchronizes.
func playPCM(ctx context.Context, q *playoutQueue, clock playoutClock, zeros bool, write func(media.Frame) error) {
	select {
	case <-ctx.Done():
		return
	case <-q.ready:
	}
	base := q.start()
	target := base
	var lastOutput time.Time
	for ctx.Err() == nil {
		wake := target
		if !lastOutput.IsZero() && wake.Before(lastOutput.Add(catchUpSpacing)) {
			wake = lastOutput.Add(catchUpSpacing)
		}
		if !clock.Wait(ctx, wake) {
			return
		}
		now := clock.Now()
		if now.Sub(target) > q.maxAge {
			target = futurePlayoutSlot(base, now)
			continue
		}
		if ctx.Err() != nil {
			return
		}
		frame, ok := q.pop(now)
		if ok || zeros {
			if !ok {
				q.counts.zeros.Add(1)
				frame.Erase()
			}
			lastOutput = clock.Now()
			if write(frame) != nil {
				return
			}
		}
		target = target.Add(playoutPeriod)
	}
}

// sequenceMapping preserves source losses across queue drops without counting
// slots already concealed by this bridge twice.
type sequenceMapping struct {
	lastSource uint64
	output     uint64
	plcCredit  uint64
}

func (m *sequenceMapping) next(f media.Frame) uint64 {
	source := binary.LittleEndian.Uint64(f[24:32])
	if source == 0 {
		m.output++
		m.plcCredit++
		return m.output
	}
	var gap uint64
	if m.lastSource != 0 && source > m.lastSource {
		gap = source - m.lastSource - 1
	}
	if gap > m.plcCredit {
		m.output += gap - m.plcCredit
	}
	m.output++
	m.lastSource = source
	m.plcCredit = 0
	return m.output
}
