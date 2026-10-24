package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

type virtualPlayoutClock struct {
	now    time.Time
	waits  []time.Time
	onWait func(time.Time)
}

func (c *virtualPlayoutClock) Now() time.Time { return c.now }
func (c *virtualPlayoutClock) Wait(ctx context.Context, target time.Time) bool {
	if ctx.Err() != nil {
		return false
	}
	c.waits = append(c.waits, target)
	c.now = target
	if c.onWait != nil {
		c.onWait(target)
	}
	return ctx.Err() == nil
}
func pcm(v byte) media.Frame {
	var f media.Frame
	for i := 40; i < len(f); i++ {
		f[i] = v
	}
	return f
}
func TestPlayoutQueueBurstAgeAndSharedCounters(t *testing.T) {
	now := time.Now()
	counts := &bridgeCounters{}
	down, up := newPlayoutQueue(counts), newPlayoutQueue(counts)
	for i := 1; i <= 9; i++ {
		down.push(pcm(byte(i)), now)
	}
	for i := 1; i <= 7; i++ {
		up.push(pcm(byte(i)), now)
	}
	if down.size != 5 || up.size != 5 || counts.drops.Load() != 6 {
		t.Fatal("queue bound or aggregate drops")
	}
	// Exactly 100ms is valid; older than 100ms is discarded before selection.
	f, ok := down.pop(now.Add(100 * time.Millisecond))
	if !ok || f != pcm(5) {
		t.Fatal("oldest retained frame or payload changed")
	}
	down.push(pcm(10), now.Add(101*time.Millisecond))
	f, ok = down.pop(now.Add(101 * time.Millisecond))
	if !ok || f != pcm(10) || counts.drops.Load() != 10 {
		t.Fatal("expired selection", counts.drops.Load())
	}
	if _, ok = up.pop(now.Add(101 * time.Millisecond)); ok || counts.drops.Load() != 15 {
		t.Fatal("aggregate expired drops")
	}
	if down.size != 0 || up.size != 0 || down.start() != now.Add(40*time.Millisecond) {
		t.Fatal("queue/initial target")
	}
}
func TestPlayoutInitialBufferBurstCadenceAndEmptyDirections(t *testing.T) {
	for _, zeros := range []bool{true, false} {
		t.Run(map[bool]string{true: "down", false: "up"}[zeros], func(t *testing.T) {
			base := time.Now()
			clock := &virtualPlayoutClock{now: base}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			counts := &bridgeCounters{}
			q := newPlayoutQueue(counts)
			for i := 1; i <= 3; i++ {
				q.push(pcm(byte(i)), base)
			}
			var starts []time.Duration
			var payloads []media.Frame
			clock.onWait = func(target time.Time) {
				if target.Sub(base) >= 140*time.Millisecond {
					cancel()
				}
			}
			playPCM(ctx, q, clock, zeros, func(f media.Frame) error {
				starts = append(starts, clock.now.Sub(base))
				payloads = append(payloads, f)
				return nil
			})
			want := []time.Duration{40 * time.Millisecond, 60 * time.Millisecond, 80 * time.Millisecond}
			if zeros {
				want = append(want, 100*time.Millisecond, 120*time.Millisecond)
			}
			if !reflect.DeepEqual(starts, want) {
				t.Fatal("cadence", starts)
			}
			for i := 0; i < 3; i++ {
				if payloads[i] != pcm(byte(i+1)) {
					t.Fatal("PCM changed")
				}
			}
			if zeros {
				if counts.zeros.Load() != 2 || payloads[3] != (media.Frame{}) || payloads[4] != (media.Frame{}) {
					t.Fatal("downlink zeros")
				}
			} else if counts.zeros.Load() != 0 {
				t.Fatal("fabricated uplink")
			}
			if counts.drops.Load() != 0 {
				t.Fatal("unexpected drops")
			}
		})
	}
}
func TestPlayoutSlowWriteAndDeschedulingDoNotCatchUp(t *testing.T) {
	for _, delayed := range []bool{false, true} {
		t.Run(map[bool]string{false: "slow_write", true: "scheduler"}[delayed], func(t *testing.T) {
			base := time.Now()
			clock := &virtualPlayoutClock{now: base}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			q := newPlayoutQueue(&bridgeCounters{})
			q.push(pcm(1), base)
			var starts []time.Duration
			if delayed {
				clock.onWait = func(time.Time) {
					if len(clock.waits) == 1 {
						clock.now = clock.now.Add(65 * time.Millisecond)
					}
				}
			}
			playPCM(ctx, q, clock, true, func(media.Frame) error {
				starts = append(starts, clock.now.Sub(base))
				if !delayed && len(starts) == 1 {
					clock.now = clock.now.Add(65 * time.Millisecond)
				}
				if len(starts) == 3 {
					cancel()
				}
				return nil
			})
			want := []time.Duration{40 * time.Millisecond, 120 * time.Millisecond, 140 * time.Millisecond}
			if delayed {
				want = []time.Duration{120 * time.Millisecond, 140 * time.Millisecond, 160 * time.Millisecond}
			}
			if !reflect.DeepEqual(starts, want) {
				t.Fatal("catch-up or wrong rearm", starts)
			}
		})
	}
}
func TestPlayoutCancellationAndWriteFailureJoin(t *testing.T) {
	for _, mode := range []string{"before_first", "buffer_wait", "write_failure"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			q := newPlayoutQueue(&bridgeCounters{})
			if mode != "before_first" {
				q.push(pcm(1), time.Now())
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				playPCM(ctx, q, realPlayoutClock{}, true, func(media.Frame) error { return errors.New("fixture") })
			}()
			if mode != "write_failure" {
				cancel()
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("playout goroutine did not exit")
			}
		})
	}
}

func TestPlayoutFixedGridDoesNotAccumulateWakeOrWriteLatency(t *testing.T) {
	for _, zeros := range []bool{true, false} {
		t.Run(map[bool]string{true: "down", false: "up"}[zeros], func(t *testing.T) {
			base := time.Now()
			clock := &virtualPlayoutClock{now: base}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			q := newPlayoutQueue(&bridgeCounters{})
			q.push(pcm(1), base)
			clock.onWait = func(target time.Time) {
				clock.now = target.Add(time.Millisecond)
				if len(clock.waits) > 1 {
					q.push(pcm(1), clock.now)
				}
			}
			var starts []time.Time
			playPCM(ctx, q, clock, zeros, func(media.Frame) error {
				starts = append(starts, clock.now)
				clock.now = clock.now.Add(5 * time.Millisecond)
				if len(starts) == 501 {
					cancel()
				}
				return nil
			})
			if len(starts) != 501 || starts[500].Sub(starts[0]) != 10*time.Second {
				t.Fatal("average rate drift")
			}
			for i, start := range starts {
				if start.Sub(base) != 41*time.Millisecond+time.Duration(i)*20*time.Millisecond {
					t.Fatal("wake latency accumulated", i)
				}
				if clock.waits[i].Sub(base) != 40*time.Millisecond+time.Duration(i)*20*time.Millisecond {
					t.Fatal("grid moved", i)
				}
			}
			if q.counts.drops.Load() != 0 || q.counts.zeros.Load() != 0 {
				t.Fatal("steady flow dropped or fabricated PCM")
			}
		})
	}
}

func TestPlayoutMinimumActualSpacingSkipsSlotWithoutMovingGrid(t *testing.T) {
	for _, late := range []time.Duration{10 * time.Millisecond, 11 * time.Millisecond, 19 * time.Millisecond, 20 * time.Millisecond, 65 * time.Millisecond} {
		t.Run(late.String(), func(t *testing.T) {
			base := time.Now()
			clock := &virtualPlayoutClock{now: base}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			q := newPlayoutQueue(&bridgeCounters{})
			q.push(pcm(1), base)
			clock.onWait = func(time.Time) {
				if len(clock.waits) == 1 {
					clock.now = clock.now.Add(late)
				}
			}
			var starts []time.Duration
			playPCM(ctx, q, clock, true, func(media.Frame) error {
				starts = append(starts, clock.now.Sub(base))
				if len(starts) == 3 {
					cancel()
				}
				return nil
			})
			want := []time.Duration{40*time.Millisecond + late, 80 * time.Millisecond, 100 * time.Millisecond}
			if late == 10*time.Millisecond {
				want = []time.Duration{50 * time.Millisecond, 60 * time.Millisecond, 80 * time.Millisecond}
			}
			if late == 20*time.Millisecond {
				want = []time.Duration{80 * time.Millisecond, 100 * time.Millisecond, 120 * time.Millisecond}
			}
			if late == 65*time.Millisecond {
				want = []time.Duration{120 * time.Millisecond, 140 * time.Millisecond, 160 * time.Millisecond}
			}
			if !reflect.DeepEqual(starts, want) {
				t.Fatal("unexpected skipped slots", starts, want)
			}
			for i := 1; i < len(starts); i++ {
				if starts[i]-starts[i-1] < 10*time.Millisecond {
					t.Fatal("output burst")
				}
			}
			for _, target := range clock.waits {
				if (target.Sub(base)-40*time.Millisecond)%(20*time.Millisecond) != 0 {
					t.Fatal("grid moved")
				}
			}
		})
	}
}
