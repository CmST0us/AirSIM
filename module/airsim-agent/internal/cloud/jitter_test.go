package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"context"
	"testing"
	"time"
)

func packet(seq uint16) []byte { return []byte{byte(seq >> 8), byte(seq)} }

type expect struct {
	flags uint32
	seq   uint16
}

// playing is far enough after any test packet for playout to have started.
var playing = time.Now().Add(time.Hour)

func playOut(t *testing.T, j *jitter, want ...expect) {
	t.Helper()
	for i, w := range want {
		f := j.pop(playing)
		if f.Flags != w.flags || (w.flags != media.FlagErasure && string(f.Payload) != string(packet(w.seq))) {
			t.Fatalf("pop %d: flags %d payload %v want %+v", i, f.Flags, f.Payload, w)
		}
	}
}
func opusFrame(seq uint16) expect { return expect{media.FlagOpus, seq} }
func fecFrame(seq uint16) expect  { return expect{media.FlagFEC, seq} }

var erasure = expect{flags: media.FlagErasure}

func fill(j *jitter, seqs ...uint16) {
	for _, s := range seqs {
		j.push(s, packet(s), time.Now())
	}
}

func TestJitterOrdersAndRecoversLoss(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	fill(j, 1, 3, 2, 4, 6, 9)
	// 5 is lost and 6 carries its FEC; 7 and 8 are lost with only 8 recoverable from 9.
	playOut(t, j, opusFrame(1), opusFrame(2), opusFrame(3), opusFrame(4), fecFrame(6), opusFrame(6), erasure, fecFrame(9), opusFrame(9))
	if c.received.Load() != 6 || c.lost.Load() != 3 || c.fec.Load() != 2 || c.plc.Load() != 1 || c.late.Load() != 0 {
		t.Fatalf("counts %+v", countersInto(BridgeStats{}, c))
	}
}

func TestJitterUnderrunWaitsForLatePacket(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	fill(j, 10)
	playOut(t, j, opusFrame(10), erasure, erasure)
	fill(j, 11)
	playOut(t, j, opusFrame(11))
	// Once 13 shows 12 is lost, a late 12 is discarded.
	fill(j, 13)
	playOut(t, j, fecFrame(13))
	fill(j, 12)
	playOut(t, j, opusFrame(13))
	if c.late.Load() != 1 || c.lost.Load() != 1 || c.plc.Load() != 2 {
		t.Fatalf("counts %+v", countersInto(BridgeStats{}, c))
	}
}

func TestJitterBoundsLatency(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	for s := uint16(1); s <= jitterMax+1; s++ {
		fill(j, s)
	}
	// One frame beyond jitterMax trims the queue to the newest jitterTarget.
	playOut(t, j, opusFrame(10), opusFrame(11), opusFrame(12), opusFrame(13))
	if c.drops.Load() != 9 {
		t.Fatalf("drops %d", c.drops.Load())
	}
	// A burst after a long stall restarts close to the newest packet.
	fill(j, 300)
	if j.next != j.highest-jitterTarget+1 || j.highest&0xffff != 300 {
		t.Fatalf("next %d", j.next)
	}
}

func TestJitterDrainsPersistentDepth(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	seq := uint16(1)
	for ; seq <= jitterDrain+2; seq++ {
		fill(j, seq)
	}
	// One packet arrives per pop, so the depth stays above jitterDrain until one frame is dropped.
	for i := 0; i < jitterDrainTicks; i++ {
		if f := j.pop(playing); f.Flags != media.FlagOpus {
			t.Fatal("unexpected concealment")
		}
		fill(j, seq)
		seq++
	}
	if c.drops.Load() != 1 {
		t.Fatalf("drops %d", c.drops.Load())
	}
}

func TestJitterStartsAfterFirstPacket(t *testing.T) {
	c := &bridgeCounters{}
	j := newJitter(c)
	start := time.Now()
	if f := j.pop(start); f.Flags != media.FlagErasure {
		t.Fatal("playout before any packet")
	}
	j.push(1, packet(1), start)
	if f := j.pop(start.Add(jitterStart - time.Millisecond)); f.Flags != media.FlagErasure {
		t.Fatal("playout before jitterStart")
	}
	if f := j.pop(start.Add(jitterStart)); f.Flags != media.FlagOpus || c.plc.Load() != 0 {
		t.Fatalf("first frame %+v plc %d", f, c.plc.Load())
	}
}

func TestJitterSequenceWrap(t *testing.T) {
	j := newJitter(&bridgeCounters{})
	fill(j, 65534, 65535, 1, 0)
	playOut(t, j, opusFrame(65534), opusFrame(65535), opusFrame(0), opusFrame(1))
	fill(j, 65535)
	if j.counts.late.Load() != 1 {
		t.Fatal("old packet across wrap not late")
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
	late := time.Duration(0)
	if len(c.steps) > 0 {
		late, c.steps = c.steps[0], c.steps[1:]
	}
	if target.After(c.now) {
		c.now = target
	}
	c.now = c.now.Add(late)
	return true
}

func TestPacedCatchesUpThenResynchronizes(t *testing.T) {
	base := time.Unix(1000, 0)
	// The third wakeup is 70 ms late; the fifth is far beyond the lag bound.
	clock := &stepClock{now: base, steps: []time.Duration{0, 0, 70 * time.Millisecond, 0, 0, 0, 0, 300 * time.Millisecond}}
	ctx, cancel := context.WithCancel(context.Background())
	var at []time.Duration
	paced(ctx, clock, base, func() error {
		at = append(at, clock.Now().Sub(base))
		if len(at) == 8 {
			cancel()
		}
		return nil
	})
	ms := time.Millisecond
	want := []time.Duration{0, 20 * ms, 110 * ms, 115 * ms, 120 * ms, 125 * ms, 130 * ms, 460 * ms}
	for i := range want {
		if at[i] != want[i] {
			t.Fatalf("emit %d at %v want %v (all %v)", i, at[i], want[i], at)
		}
	}
}
