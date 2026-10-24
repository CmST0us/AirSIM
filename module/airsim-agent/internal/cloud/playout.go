package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"context"
	"sync"
	"time"
)

const (
	playoutPeriod = 20 * time.Millisecond
	playoutBuffer = 40 * time.Millisecond
	playoutMaxAge = 100 * time.Millisecond
)

type queuedPCM struct {
	frame   media.Frame
	arrived time.Time
}

// Each direction owns a separate queue. The lock only protects memory, never I/O.
type playoutQueue struct {
	mu     sync.Mutex
	frames [5]queuedPCM
	size   int
	first  time.Time
	ready  chan struct{}
	counts *bridgeCounters
}

func newPlayoutQueue(counts *bridgeCounters) *playoutQueue {
	return &playoutQueue{ready: make(chan struct{}), counts: counts}
}
func (q *playoutQueue) push(f media.Frame, now time.Time) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.first.IsZero() {
		q.first = now
		close(q.ready)
	}
	if q.size == len(q.frames) {
		copy(q.frames[:], q.frames[1:])
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
		copy(q.frames[:], q.frames[1:q.size])
		q.size--
		q.frames[q.size] = queuedPCM{}
		if now.Sub(item.arrived) > playoutMaxAge {
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
	return q.first.Add(playoutBuffer)
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

// futurePlayoutSlot preserves the original grid and skips every elapsed slot.
func futurePlayoutSlot(base, now time.Time) time.Time {
	if now.Before(base) {
		return base
	}
	return base.Add((now.Sub(base)/playoutPeriod + 1) * playoutPeriod)
}

// Small wakeup errors do not move the grid. Missed slots are skipped, and the
// actual output spacing guard prevents adjacent late/early slots from bursting.
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
		if !clock.Wait(ctx, target) {
			return
		}
		now := clock.Now()
		if now.Sub(target) >= playoutPeriod {
			target = futurePlayoutSlot(base, now)
			continue
		}
		if ctx.Err() != nil {
			return
		}
		if lastOutput.IsZero() || now.Sub(lastOutput) >= 10*time.Millisecond {
			frame, ok := q.pop(now)
			if ok || zeros {
				if !ok {
					q.counts.zeros.Add(1)
				}
				lastOutput = clock.Now()
				if write(frame) != nil {
					return
				}
			}
		}
		target = target.Add(playoutPeriod)
		// A write that runs beyond the next target never triggers an immediate retry.
		if now = clock.Now(); now.After(target) {
			target = futurePlayoutSlot(base, now)
		}
	}
}
