package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"context"
	"sync"
	"time"
)

const (
	playoutPeriod = 20 * time.Millisecond
	// jitterStart delays the first playout so early cellular jitter is absorbed.
	jitterStart = 80 * time.Millisecond
	// jitterTarget frames remain after a latency trim; beyond jitterMax queued
	// frames the oldest are dropped at once, and a depth above jitterDrain held
	// for jitterDrainTicks drops one frame.
	jitterTarget     = 4
	jitterDrain      = 6
	jitterMax        = 12
	jitterDrainTicks = 50
	jitterSlots      = 64
	// pacedMaxLag is how far playout may fall behind its grid before it skips
	// ahead; the jitter buffer then trims what accumulated.
	pacedMaxLag = 240 * time.Millisecond
	// catchUpSpacing separates frames written back to back while draining a backlog.
	catchUpSpacing = 5 * time.Millisecond
)

type jitterSlot struct {
	seq     uint64
	payload []byte
}

// jitter orders RTP packets by sequence number and hands the helper one frame
// per 20 ms: the next packet, the following packet for FEC when the next one
// is lost, or an erasure for concealment. Playout starts jitterStart after the
// first packet. The lock only protects memory.
type jitter struct {
	mu            sync.Mutex
	slots         [jitterSlots]jitterSlot
	next, highest uint64
	started       bool
	first         time.Time
	deep          int
	counts        *bridgeCounters
}

func newJitter(counts *bridgeCounters) *jitter { return &jitter{counts: counts} }

// extend unwraps a 16-bit RTP sequence number next to the highest one seen.
// The first packet starts one wrap in so earlier packets stay representable.
func (j *jitter) extend(seq uint16) uint64 {
	if !j.started {
		return 1<<16 | uint64(seq)
	}
	x := j.highest&^0xffff | uint64(seq)
	switch {
	case x+0x8000 < j.highest:
		x += 0x10000
	case x > j.highest+0x8000 && x >= 0x10000:
		x -= 0x10000
	}
	return x
}
func (j *jitter) push(seq uint16, payload []byte, now time.Time) {
	j.mu.Lock()
	defer j.mu.Unlock()
	x := j.extend(seq)
	j.counts.received.Add(1)
	if !j.started {
		j.started = true
		j.next, j.highest, j.first = x, x, now
	}
	if x < j.next {
		j.counts.late.Add(1)
		return
	}
	if x > j.highest {
		j.highest = x
	}
	if x-j.next >= jitterSlots {
		j.skipTo(x - jitterTarget + 1)
	}
	j.slots[x%jitterSlots] = jitterSlot{x, payload}
	if j.highest-j.next+1 > jitterMax {
		j.skipTo(j.highest - jitterTarget + 1)
	}
}

// skipTo drops queued frames before next.
func (j *jitter) skipTo(next uint64) {
	for s := j.next; s < next; s++ {
		if slot := &j.slots[s%jitterSlots]; slot.payload != nil && slot.seq == s {
			*slot = jitterSlot{}
			j.counts.drops.Add(1)
		}
	}
	j.next = next
	j.deep = 0
}
func (j *jitter) take(seq uint64) []byte {
	slot := &j.slots[seq%jitterSlots]
	if slot.payload == nil || slot.seq != seq {
		return nil
	}
	p := slot.payload
	*slot = jitterSlot{}
	return p
}
func (j *jitter) peek(seq uint64) []byte {
	if slot := j.slots[seq%jitterSlots]; slot.payload != nil && slot.seq == seq {
		return slot.payload
	}
	return nil
}

// pop returns the frame for the playout slot at now. Before playout starts it
// returns uncounted erasures. Underruns conceal without advancing, so a late
// packet still plays; a lost packet advances.
func (j *jitter) pop(now time.Time) media.Frame {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.started || now.Before(j.first.Add(jitterStart)) {
		return media.Frame{Flags: media.FlagErasure}
	}
	if depth := int(j.highest - j.next + 1); j.highest >= j.next && depth > jitterDrain {
		if j.deep++; j.deep >= jitterDrainTicks {
			j.skipTo(j.next + 1)
		}
	} else {
		j.deep = 0
	}
	if p := j.take(j.next); p != nil {
		j.next++
		return media.Frame{Flags: media.FlagOpus, Payload: p}
	}
	if j.highest > j.next {
		j.next++
		j.counts.lost.Add(1)
		if p := j.peek(j.next); p != nil {
			j.counts.fec.Add(1)
			return media.Frame{Flags: media.FlagFEC, Payload: p}
		}
	}
	j.counts.plc.Add(1)
	return media.Frame{Flags: media.FlagErasure}
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

// paced calls emit on a fixed 20 ms grid from base. Small wakeup errors do not
// move the grid; a late wakeup or slow write emits the missed slots 5 ms apart,
// and beyond pacedMaxLag the grid resynchronizes.
func paced(ctx context.Context, clock playoutClock, base time.Time, emit func() error) {
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
		if now.Sub(target) > pacedMaxLag {
			target = futurePlayoutSlot(base, now)
			continue
		}
		lastOutput = now
		if emit() != nil {
			return
		}
		target = target.Add(playoutPeriod)
	}
}
