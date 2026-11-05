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
