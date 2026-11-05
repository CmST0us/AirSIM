package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"context"
	"sync"
	"time"
)

const (
	playoutPeriod = 20 * time.Millisecond
	// Two 20 ms RED copies plus one frame of scheduling/reorder headroom.
	jitterStart = 60 * time.Millisecond
	jitterSlots = 64
)

type jitterSlot struct {
	index     int64
	payload   []byte
	redundant bool
}

// jitter is a bounded media-time playout buffer. RTP timestamps identify audio
// samples, independent of datagram sequence or arrival. Each deadline consumes
// exactly one slot, including concealment; an outage cannot move old speech
// into the future. Late CPU wakeups skip expired audio instead of burst replay.
type jitter struct {
	mu                  sync.Mutex
	slots               [jitterSlots]jitterSlot
	started             bool
	origin              uint32
	playAt              time.Time
	last                int64
	newest              int64
	misaligned, missing int
	counts              *bridgeCounters
}

func newJitter(counts *bridgeCounters) *jitter { return &jitter{counts: counts, last: -1, newest: -1} }

func (j *jitter) push(packet rtc.AudioPacket, now time.Time) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !packet.Redundant {
		j.counts.received.Add(1)
	}
	if !j.started {
		if packet.Redundant {
			return
		}
		j.started = true
		j.origin = packet.Timestamp
		j.playAt = now.Add(jitterStart)
	}
	// Signed modular subtraction handles the 32-bit RTP wrap. A session lasts
	// at most 30 minutes, well below the half-range ambiguity at 48 kHz.
	delta := int64(int32(packet.Timestamp - j.origin))
	if delta%rtc.OpusFrameTicks != 0 {
		j.counts.invalid.Add(1)
		return
	}
	index := delta / rtc.OpusFrameTicks
	due := int64(-1)
	if !now.Before(j.playAt) {
		due = int64(now.Sub(j.playAt) / playoutPeriod)
	}
	// A permanent path-delay change (or sender clock drift) must not leave the
	// stream concealing forever. Require three increasing primary packets and
	// sustained underrun, so reordered/duplicate packets and successfully RED-
	// recovered audio cannot reset the clock. A sustained excess lead is bounded
	// too. Resynchronization is exceptional and counted, never silent drift.
	if !packet.Redundant && index > j.newest && index >= 0 && index < max(j.last+1, due)+jitterSlots {
		j.newest = index
		late := index <= j.last || index < due
		if (late && j.missing >= 3) || (due >= 0 && index-due > 8) {
			j.misaligned++
		} else {
			j.misaligned = 0
		}
		if j.misaligned >= 3 {
			j.slots = [jitterSlots]jitterSlot{}
			j.origin, j.playAt, j.last, j.newest = packet.Timestamp, now.Add(jitterStart), -1, 0
			j.misaligned, j.missing = 0, 0
			j.counts.resync.Add(1)
			index, due = 0, -1
		}
	}
	if index <= j.last || index < due {
		if !packet.Redundant {
			j.counts.late.Add(1)
		}
		return
	}
	if index < 0 || index >= max(j.last+1, due)+jitterSlots {
		j.counts.invalid.Add(1)
		return
	}
	slot := &j.slots[index%jitterSlots]
	if slot.payload != nil && slot.index == index && (!slot.redundant || packet.Redundant) {
		if !packet.Redundant {
			j.counts.duplicates.Add(1)
		}
		return
	}
	*slot = jitterSlot{index: index, payload: append([]byte(nil), packet.Payload...), redundant: packet.Redundant}
}

func (j *jitter) peek(index int64) *jitterSlot {
	slot := &j.slots[index%jitterSlots]
	if slot.payload == nil || slot.index != index {
		return nil
	}
	return slot
}

func (j *jitter) pop(now time.Time) media.Frame {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.started || now.Before(j.playAt) {
		return media.Frame{Flags: media.FlagErasure}
	}
	index := int64(now.Sub(j.playAt) / playoutPeriod)
	if index <= j.last {
		return media.Frame{Flags: media.FlagErasure}
	}
	// Work is bounded by memory, even after a very long scheduler suspension.
	for i := range j.slots {
		slot := &j.slots[i]
		if slot.payload != nil && slot.index < index {
			*slot = jitterSlot{}
			j.counts.drops.Add(1)
		}
	}
	j.last = index
	if slot := j.peek(index); slot != nil {
		j.missing = 0
		frame := media.Frame{Flags: media.FlagOpus, Payload: slot.payload}
		if slot.redundant {
			j.counts.red.Add(1)
		}
		*slot = jitterSlot{}
		return frame
	}
	j.missing++
	j.counts.lost.Add(1)
	if next := j.peek(index + 1); next != nil {
		// FEC is a decode attempt, not proof that the packet contains redundancy.
		j.counts.fec.Add(1)
		return media.Frame{Flags: media.FlagFEC, Payload: next.payload}
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

// paced emits at most once for the current slot. Missed deadlines are skipped;
// emitting several old 20 ms frames 5 ms apart overflows the native queue and
// turns a CPU pause into another burst of loss and delayed speech.
func paced(ctx context.Context, clock playoutClock, base time.Time, emit func() error) {
	target := base
	for ctx.Err() == nil {
		if !clock.Wait(ctx, target) {
			return
		}
		now := clock.Now()
		if now.Sub(target) >= playoutPeriod {
			target = futurePlayoutSlot(base, now).Add(-playoutPeriod)
		}
		if emit() != nil {
			return
		}
		target = target.Add(playoutPeriod)
	}
}
