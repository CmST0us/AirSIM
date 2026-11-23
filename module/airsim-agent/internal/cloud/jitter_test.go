package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"context"
	"testing"
	"time"
)

var jitterEpoch = time.Unix(1000, 0)

func audioPacket(i int) rtc.AudioPacket {
	return rtc.AudioPacket{Sequence: uint16(i), Timestamp: uint32(i) * rtc.OpusFrameTicks, Payload: []byte{0x78, byte(i)}}
}
func pushAt(j *jitter, i int, at time.Time) { j.push(audioPacket(i), at) }
func expectPacket(t *testing.T, j *jitter, slot int, flag uint32, payload int) {
	t.Helper()
	f := j.pop(jitterEpoch.Add(jitterStart + time.Duration(slot)*playoutPeriod))
	if f.Flags != flag || (flag != media.FlagErasure && (len(f.Payload) != 2 || f.Payload[1] != byte(payload))) {
		t.Fatalf("slot %d: %+v want flag %d packet %d", slot, f, flag, payload)
	}
}
func TestJitterOrdersAndRecoversLoss(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	for _, i := range []int{0, 2, 1, 3, 5, 8} {
		pushAt(j, i, jitterEpoch)
	}
	flags := []uint32{0, 0, 0, 0, media.FlagFEC, 0, media.FlagErasure, media.FlagFEC, 0}
	ids := []int{0, 1, 2, 3, 5, 5, 0, 8, 8}
	for i, flag := range flags {
		expectPacket(t, j, i, flag, ids[i])
	}
	if c.received.Load() != 6 || c.lost.Load() != 3 || c.fec.Load() != 2 || c.plc.Load() != 1 {
		t.Fatal(countersInto(BridgeStats{}, c))
	}
}
func TestJitterUnderrunAdvancesAndNeverReplaysLateSpeech(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	pushAt(j, 0, jitterEpoch)
	expectPacket(t, j, 0, 0, 0)
	expectPacket(t, j, 1, media.FlagErasure, 0)
	expectPacket(t, j, 2, media.FlagErasure, 0)
	pushAt(j, 1, jitterEpoch.Add(jitterStart+2*playoutPeriod))
	pushAt(j, 3, jitterEpoch.Add(jitterStart+2*playoutPeriod))
	expectPacket(t, j, 3, 0, 3)
	if c.late.Load() != 1 || c.plc.Load() != 2 {
		t.Fatal(countersInto(BridgeStats{}, c))
	}
}
func TestJitterExactREDRecoveryAndPrimaryDeduplication(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	pushAt(j, 0, jitterEpoch)
	pushAt(j, 3, jitterEpoch.Add(3*playoutPeriod))
	for _, i := range []int{1, 2} {
		f := audioPacket(i)
		f.Redundant = true
		j.push(f, jitterEpoch.Add(3*playoutPeriod))
	}
	pushAt(j, 2, jitterEpoch.Add(3*playoutPeriod))
	for i := 0; i < 4; i++ {
		expectPacket(t, j, i, 0, i)
	}
	if c.red.Load() != 1 || c.plc.Load() != 0 || c.fec.Load() != 0 {
		t.Fatal(countersInto(BridgeStats{}, c))
	}
}
func TestJitterTimestampWrapAndSequenceIndependence(t *testing.T) {
	j := newJitter(&bridgeCounters{})
	for i := 0; i < 5; i++ {
		f := audioPacket(i)
		f.Sequence = 42
		f.Timestamp = 0xfffffc00 + uint32(i)*rtc.OpusFrameTicks
		j.push(f, jitterEpoch)
	}
	for i := 0; i < 5; i++ {
		expectPacket(t, j, i, 0, i)
	}
}
func TestJitterStartsAtBoundedDeadlineAndRejectsWrongTimeline(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	pushAt(j, 0, jitterEpoch)
	if j.pop(jitterEpoch.Add(jitterStart-time.Millisecond)).Flags != media.FlagErasure {
		t.Fatal("started early")
	}
	bad := audioPacket(1)
	bad.Timestamp++
	j.push(bad, jitterEpoch)
	pushAt(j, 10000, jitterEpoch)
	expectPacket(t, j, 0, 0, 0)
	if c.invalid.Load() != 2 {
		t.Fatal(countersInto(BridgeStats{}, c))
	}
}
func TestJitterSchedulerPauseDiscardsExpiredAudio(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	for i := 0; i < 12; i++ {
		pushAt(j, i, jitterEpoch)
	}
	expectPacket(t, j, 0, 0, 0)
	expectPacket(t, j, 10, 0, 10)
	expectPacket(t, j, 11, 0, 11)
	if c.drops.Load() != 9 {
		t.Fatal(countersInto(BridgeStats{}, c))
	}
}

type stepClock struct {
	now   time.Time
	steps []time.Duration
}

func (c *stepClock) Now() time.Time { return c.now }
func (c *stepClock) Wait(ctx context.Context, target time.Time) bool {
	if ctx.Err() != nil {
		return false
	}
	if target.After(c.now) {
		c.now = target
	}
	if len(c.steps) > 0 {
		c.now = c.now.Add(c.steps[0])
		c.steps = c.steps[1:]
	}
	return true
}
func TestPacedNeverBurstsAfterSchedulerPause(t *testing.T) {
	base := jitterEpoch
	clock := &stepClock{now: base, steps: []time.Duration{0, 0, 70 * time.Millisecond, 0, 300 * time.Millisecond}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var at []time.Duration
	paced(ctx, clock, base, func() error {
		at = append(at, clock.Now().Sub(base))
		if len(at) == 6 {
			cancel()
		}
		return nil
	})
	want := []time.Duration{0, 20 * time.Millisecond, 110 * time.Millisecond, 120 * time.Millisecond, 440 * time.Millisecond, 460 * time.Millisecond}
	for i, w := range want {
		if at[i] != w {
			t.Fatalf("got %v want %v", at, want)
		}
	}
}

func TestJitterFarAheadPacketCannotOverwriteCurrentSlot(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	pushAt(j, 0, jitterEpoch)
	pushAt(j, jitterSlots, jitterEpoch.Add(jitterStart))
	expectPacket(t, j, 0, media.FlagOpus, 0)
	if c.invalid.Load() != 1 {
		t.Fatal("out-of-window packet accepted")
	}
}

func TestJitterPhaseAliasingZeroDestruction(t *testing.T) {
	// Sweep all 40 phases [0..19.5ms] with realistic EG25 single-core wakeup
	// jitter [0.5..5.0ms] on a 0%-loss link: every single frame must play cleanly.
	for phaseTenths := 0; phaseTenths < 200; phaseTenths += 5 {
		c := &bridgeCounters{}
		j := newJitter(c)
		phase := time.Duration(phaseTenths) * 100 * time.Microsecond
		originArr := jitterEpoch.Add(30*time.Millisecond + phase)
		const frames = 200
		base := jitterEpoch
		target := base
		cursor := 0
		played := 0
		var seed uint32 = 20261123 + uint32(phaseTenths)
		end := originArr.Add(frames*playoutPeriod + 200*time.Millisecond)
		for target.Before(end) {
			seed = seed*1664525 + 1013904223
			jit := time.Duration(500+(seed%4500)) * time.Microsecond
			wake := target.Add(jit)
			for cursor < frames {
				arr := originArr.Add(time.Duration(cursor) * playoutPeriod)
				if arr.After(wake) {
					break
				}
				j.push(audioPacket(cursor), arr)
				cursor++
			}
			f := j.pop(wake)
			if f.Flags == media.FlagOpus {
				played++
			}
			target = target.Add(playoutPeriod)
		}
		if played != frames || c.drops.Load() != 0 {
			t.Fatalf("phase %v: played %d/%d drops=%d", phase, played, frames, c.drops.Load())
		}
	}
}

func TestJitterTimestampDiscontinuityResyncs(t *testing.T) {
	cases := []struct {
		name string
		ts   func(i int) uint32
	}{
		{"forward_jump_1.5s", func(i int) uint32 {
			if i < 20 {
				return uint32(i) * rtc.OpusFrameTicks
			}
			return uint32(i+75) * rtc.OpusFrameTicks
		}},
		{"non_960_shift_480", func(i int) uint32 {
			if i < 20 {
				return uint32(i) * rtc.OpusFrameTicks
			}
			return uint32(i)*rtc.OpusFrameTicks + 480
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &bridgeCounters{}
			j := newJitter(c)
			const frames = 100
			cursor := 0
			played := 0
			now := jitterEpoch.Add(90 * time.Millisecond)
			end := jitterEpoch.Add(30*time.Millisecond + frames*playoutPeriod + 200*time.Millisecond)
			for now.Before(end) {
				for cursor < frames {
					arr := jitterEpoch.Add(30*time.Millisecond + time.Duration(cursor)*playoutPeriod)
					if arr.After(now) {
						break
					}
					j.push(rtc.AudioPacket{Sequence: uint16(cursor), Timestamp: tc.ts(cursor), Payload: []byte{0x78, byte(cursor)}}, arr)
					cursor++
				}
				if j.pop(now).Flags == media.FlagOpus {
					played++
				}
				now = now.Add(playoutPeriod)
			}
			if played < frames-5 || c.resync.Load() != 1 {
				t.Fatalf("%s: played=%d resync=%d invalid=%d", tc.name, played, c.resync.Load(), c.invalid.Load())
			}
		})
	}
}

func TestJitterSkipsFECForCELTPackets(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	// Config 28 (0xE0 >> 3 = 28 >= 16) is CELT-only and never carries LBRR FEC.
	j.push(rtc.AudioPacket{Sequence: 0, Timestamp: 0, Payload: []byte{0xE0, 0}}, jitterEpoch)
	j.push(rtc.AudioPacket{Sequence: 2, Timestamp: 2 * rtc.OpusFrameTicks, Payload: []byte{0xE0, 2}}, jitterEpoch)
	expectPacket(t, j, 0, media.FlagOpus, 0)
	f := j.pop(jitterEpoch.Add(jitterStart + playoutPeriod))
	if f.Flags != media.FlagErasure || c.fec.Load() != 0 || c.plc.Load() != 1 {
		t.Fatalf("CELT packet falsely triggered FEC: flags=%d fec=%d plc=%d", f.Flags, c.fec.Load(), c.plc.Load())
	}
}

func TestJitterLateWakeup10To19msZeroDropsAndZeroFakePLC(t *testing.T) {
	// Reproduce single-core Cortex-A7 GC wakeup jitter (10.5..19.0 ms late on
	// alternating ticks, followed by on-time grid ticks <10 ms later). Previously
	// (elapsed + 10ms)/20ms rounded up to j.last+2, dropping valid speech frames
	// (queue_drops=64 in 71s) and emitting fake PLC on the following tick.
	c := &bridgeCounters{}
	j := newRelayJitter(c)
	const frames = 500
	originArr := jitterEpoch.Add(15 * time.Millisecond)
	target := jitterEpoch
	cursor := 0
	played := 0
	end := originArr.Add(frames*playoutPeriod + 250*time.Millisecond)
	tick := 0
	for target.Before(end) {
		var jit time.Duration
		if tick > 5 && tick%3 == 1 {
			jit = time.Duration(11+(tick%8)) * time.Millisecond // 11..18 ms late!
		} else {
			jit = time.Millisecond
		}
		wake := target.Add(jit)
		for cursor < frames {
			arr := originArr.Add(time.Duration(cursor) * playoutPeriod)
			if arr.After(wake) {
				break
			}
			j.push(audioPacket(cursor), arr)
			cursor++
		}
		f := j.pop(wake)
		if f.Flags == media.FlagOpus {
			played++
		}
		if played == frames {
			break
		}
		target = target.Add(playoutPeriod)
		tick++
	}
	if played != frames || c.drops.Load() != 0 || c.plc.Load() != 0 || c.late.Load() != 0 {
		t.Fatalf("played=%d/%d drops=%d plc=%d late=%d", played, frames, c.drops.Load(), c.plc.Load(), c.late.Load())
	}
}

func TestJitterRelaySettlesOnceAndAbsorbsRecurringLTEBursts(t *testing.T) {
	// Simulate recurring 155 ms 4G LTE scheduling stalls (7 packets bunched and
	// released together every 5 seconds, matching real rtp_stall_max_ms=191ms).
	// Previously, settling onto burst #1 immediately triggered a rebound excess-lead
	// resync when normal 20 ms packets resumed (ping-ponging 2 wipes per burst = 12
	// resyncs). Now it settles at most once on burst #1 and plays bursts #2..#6
	// with zero further resyncs and zero loss.
	c := &bridgeCounters{}
	j := newRelayJitter(c)
	const frames = 1500
	type item struct {
		at  time.Time
		idx int
	}
	var arrivals []item
	for i := 0; i < frames; i++ {
		at := jitterEpoch.Add(time.Duration(i)*playoutPeriod + 20*time.Millisecond)
		if i >= 50 && i%250 >= 50 && i%250 <= 56 {
			burstEnd := (i/250)*250 + 56
			at = jitterEpoch.Add(time.Duration(burstEnd)*playoutPeriod + 55*time.Millisecond)
		}
		arrivals = append(arrivals, item{at, i})
	}
	cursor := 0
	played := 0
	for now := jitterEpoch.Add(20 * time.Millisecond); now.Before(jitterEpoch.Add(frames*playoutPeriod + 300*time.Millisecond)); now = now.Add(playoutPeriod) {
		for cursor < len(arrivals) && !arrivals[cursor].at.After(now) {
			j.push(audioPacket(arrivals[cursor].idx), arrivals[cursor].at)
			cursor++
		}
		if j.pop(now).Flags == media.FlagOpus {
			played++
		}
	}
	if c.resync.Load() > 1 || played < frames-10 {
		t.Fatalf("recurring LTE bursts ping-ponged buffer wipes: resyncs=%d played=%d/%d", c.resync.Load(), played, frames)
	}
}
