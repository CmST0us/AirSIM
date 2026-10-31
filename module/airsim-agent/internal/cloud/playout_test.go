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
	if target.After(c.now) {
		c.now = target
	}
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
				if counts.zeros.Load() != 2 || payloads[3][36] != 1 || payloads[4][36] != 1 || payloads[3][40] != 0 || payloads[4][40] != 0 {
					t.Fatal("downlink erasure")
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
func TestPlayoutSlowWriteAndDeschedulingCatchUp(t *testing.T) {
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
			want := []time.Duration{40 * time.Millisecond, 105 * time.Millisecond, 110 * time.Millisecond}
			if delayed {
				want = []time.Duration{105 * time.Millisecond, 110 * time.Millisecond, 115 * time.Millisecond}
			}
			if !reflect.DeepEqual(starts, want) {
				t.Fatal("missed slots not drained", starts)
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

func TestPlayoutLateWakeDrainsWithMinimumSpacingAndResyncsBeyondAge(t *testing.T) {
	cases := map[time.Duration][]time.Duration{
		10 * time.Millisecond:  {110 * time.Millisecond, 120 * time.Millisecond, 140 * time.Millisecond},
		20 * time.Millisecond:  {120 * time.Millisecond, 125 * time.Millisecond, 140 * time.Millisecond},
		65 * time.Millisecond:  {165 * time.Millisecond, 170 * time.Millisecond, 175 * time.Millisecond},
		300 * time.Millisecond: {420 * time.Millisecond, 440 * time.Millisecond, 460 * time.Millisecond},
	}
	for late, want := range cases {
		t.Run(late.String(), func(t *testing.T) {
			base := time.Now()
			clock := &virtualPlayoutClock{now: base}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			counts := &bridgeCounters{}
			q := newJitterQueue(counts)
			for i := 1; i <= 3; i++ {
				q.push(pcm(byte(i)), base)
			}
			resync := late > jitterMaxAge
			clock.onWait = func(time.Time) {
				if len(clock.waits) == 1 {
					clock.now = clock.now.Add(late)
				}
			}
			var starts []time.Duration
			playPCM(ctx, q, clock, true, func(f media.Frame) error {
				starts = append(starts, clock.now.Sub(base))
				if !resync && f != pcm(byte(len(starts))) {
					t.Fatal("queued PCM skipped")
				}
				if len(starts) == 3 {
					cancel()
				}
				return nil
			})
			if !reflect.DeepEqual(starts, want) {
				t.Fatal("unexpected cadence", starts, want)
			}
			for i := 1; i < len(starts); i++ {
				if starts[i]-starts[i-1] < catchUpSpacing {
					t.Fatal("output burst")
				}
			}
			if resync {
				if counts.drops.Load() != 3 || counts.zeros.Load() != 3 {
					t.Fatal("stale backlog played after resync")
				}
			} else if counts.drops.Load() != 0 || counts.zeros.Load() != 0 {
				t.Fatal("late wake discarded or concealed queued PCM")
			}
		})
	}
}

func TestSequenceMappingDropAndPLCCredit(t *testing.T) {
	for _, tc := range []struct {
		name         string
		source, want []uint64
	}{
		{"first", []uint64{30, 31}, []uint64{1, 2}},
		{"drop", []uint64{1, 5, 6}, []uint64{1, 5, 6}},
		{"covered", []uint64{1, 0, 0, 4}, []uint64{1, 2, 3, 4}},
		{"partial", []uint64{1, 0, 5}, []uint64{1, 2, 5}},
		{"excess_credit", []uint64{1, 0, 0, 2, 5}, []uint64{1, 2, 3, 4, 7}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var m sequenceMapping
			for i, seq := range tc.source {
				f := media.NewFrame(uid(), 1, seq)
				if seq == 0 {
					f.Erase()
				}
				if got := m.next(f); got != tc.want[i] {
					t.Fatalf("slot %d: got %d want %d", i, got, tc.want[i])
				}
			}
		})
	}
}
func TestSequenceMappingRetainsBurstQueueDrop(t *testing.T) {
	now := time.Now()
	q := newPlayoutQueue(&bridgeCounters{})
	var m sequenceMapping
	id := uid()
	if m.next(media.NewFrame(id, 1, 1)) != 1 {
		t.Fatal("initial sequence")
	}
	for seq := uint64(2); seq <= 8; seq++ {
		q.push(media.NewFrame(id, 1, seq), now)
	}
	f, ok := q.pop(now)
	if !ok || m.next(f) != 4 {
		t.Fatal("overflow gap erased")
	}
	var concealed media.Frame
	concealed.Erase()
	if m.next(concealed) != 5 {
		t.Fatal("PLC slot")
	}
	f = media.NewFrame(id, 1, 8)
	if m.next(f) != 8 {
		t.Fatal("double-counted PLC credit")
	}
}
func TestJitterQueueHoldsCellularBurst(t *testing.T) {
	now := time.Now()
	counts := &bridgeCounters{}
	q := newJitterQueue(counts)
	for i := 1; i <= 12; i++ {
		q.push(pcm(byte(i)), now)
	}
	if q.size != 12 || counts.drops.Load() != 0 || q.start() != now.Add(100*time.Millisecond) {
		t.Fatal("jitter buffer bound or initial target")
	}
	// A frame delayed 240ms is still played; older frames are discarded.
	if f, ok := q.pop(now.Add(240 * time.Millisecond)); !ok || f != pcm(1) {
		t.Fatal("delayed frame discarded")
	}
	if _, ok := q.pop(now.Add(241 * time.Millisecond)); ok || counts.drops.Load() != 11 {
		t.Fatal("expired frames retained", counts.drops.Load())
	}
}
