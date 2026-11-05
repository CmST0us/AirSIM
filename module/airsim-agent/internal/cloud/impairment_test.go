package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"encoding/binary"
	"encoding/json"
	"math/rand"
	"sort"
	"testing"
	"time"
)

type impairment struct {
	name                            string
	frames                          int
	loss                            float64
	jitter                          time.Duration
	burst, outage, pause, delayStep bool
	clockPPM                        int
}
type arrival struct {
	at    time.Time
	index int
}
type impairmentResult struct {
	Profile     string `json:"profile"`
	RED         bool   `json:"red"`
	NetworkLost int    `json:"network_packets_lost"`
	Played      int    `json:"exact_frames_played"`
	Concealed   uint64 `json:"concealment_attempts"`
	Recovered   uint64 `json:"exact_red_recoveries"`
	Resyncs     uint64 `json:"resyncs"`
	P95MS       int64  `json:"source_to_bridge_playout_p95_ms"`
	MaxMS       int64  `json:"source_to_bridge_playout_max_ms"`
}

// Virtual time separates network loss, jitter, clock skew and scheduler pauses.
// Payloads are synthetic frame IDs, never captured audio. This measures packet
// continuity and bridge deadlines, not codec sound quality or mouth-to-ear delay.
func simulateImpairment(t *testing.T, p impairment, red bool) impairmentResult {
	t.Helper()
	rng := rand.New(rand.NewSource(20261105))
	c := &bridgeCounters{}
	j := newJitter(c)
	result := impairmentResult{Profile: p.name, RED: red}
	origin := jitterEpoch
	generated := func(i int) time.Time {
		return origin.Add(time.Duration(i)*playoutPeriod + time.Duration(int64(i)*int64(playoutPeriod)*int64(p.clockPPM)/1000000))
	}
	arrivals := make([]arrival, 0, p.frames)
	for i := 0; i < p.frames; i++ {
		lost := rng.Float64() < p.loss || p.burst && i%50 >= 20 && i%50 <= 21 || p.outage && i >= 100 && i < 110
		if i == 0 || i >= p.frames-2 {
			lost = false
		}
		if lost {
			result.NetworkLost++
			continue
		}
		delay := 30 * time.Millisecond
		if p.jitter > 0 && i > 0 {
			delay += time.Duration(rng.Int63n(int64(p.jitter)))
		}
		if p.delayStep && i >= 100 {
			delay += 120 * time.Millisecond
		}
		at := generated(i).Add(delay)
		arrivals = append(arrivals, arrival{at, i})
		if i%41 == 11 {
			arrivals = append(arrivals, arrival{at.Add(time.Millisecond), i})
		}
	}
	sort.SliceStable(arrivals, func(a, b int) bool { return arrivals[a].at.Before(arrivals[b].at) })
	packet := func(i int, copy bool) rtc.AudioPacket {
		payload := make([]byte, 5)
		payload[0] = 0x78
		binary.BigEndian.PutUint32(payload[1:], uint32(i))
		return rtc.AudioPacket{Sequence: uint16(i), Timestamp: 0xffff0000 + uint32(i)*rtc.OpusFrameTicks, Payload: payload, Redundant: copy}
	}
	cursor, last := 0, -1
	var latency []int64
	end := generated(p.frames - 1).Add(250 * time.Millisecond)
	for now := origin.Add(90 * time.Millisecond); now.Before(end); now = now.Add(playoutPeriod) {
		for cursor < len(arrivals) && !arrivals[cursor].at.After(now) {
			event := arrivals[cursor]
			cursor++
			j.push(packet(event.index, false), event.at)
			if red {
				for k := 2; k >= 1; k-- {
					if event.index >= k {
						j.push(packet(event.index-k, true), event.at)
					}
				}
			}
		}
		if p.pause && !now.Before(origin.Add(2700*time.Millisecond)) && now.Before(origin.Add(2820*time.Millisecond)) {
			continue
		}
		f := j.pop(now)
		if f.Flags != media.FlagOpus {
			continue
		}
		id := int(binary.BigEndian.Uint32(f.Payload[1:]))
		if id <= last {
			t.Fatalf("%s replayed old speech: %d after %d", p.name, id, last)
		}
		last = id
		result.Played++
		age := now.Sub(generated(id)).Milliseconds()
		if age < 0 || age > 300 {
			t.Fatalf("%s unbounded/negative latency %d", p.name, age)
		}
		latency = append(latency, age)
		if id == p.frames-1 {
			break
		}
	}
	result.Concealed = c.lost.Load()
	result.Recovered = c.red.Load()
	result.Resyncs = c.resync.Load()
	sort.Slice(latency, func(i, k int) bool { return latency[i] < latency[k] })
	if len(latency) == 0 {
		t.Fatal("no playout", p.name)
	}
	result.P95MS = latency[len(latency)*95/100]
	result.MaxMS = latency[len(latency)-1]
	if last < p.frames-3 {
		t.Fatalf("%s failed to return to live audio: last=%d", p.name, last)
	}
	return result
}
func TestCloudAudioImpairments(t *testing.T) {
	profiles := []impairment{
		{name: "clean", frames: 3000},
		{name: "random_3pct_jitter_15ms", frames: 3000, loss: .03, jitter: 15 * time.Millisecond},
		{name: "random_10pct_jitter_15ms", frames: 3000, loss: .10, jitter: 15 * time.Millisecond},
		{name: "two_packet_bursts", frames: 3000, burst: true, jitter: 15 * time.Millisecond},
		{name: "reordering_55ms", frames: 3000, jitter: 55 * time.Millisecond},
		{name: "jitter_120ms", frames: 3000, jitter: 120 * time.Millisecond},
		{name: "outage_200ms", frames: 3000, outage: true},
		{name: "scheduler_pause_120ms", frames: 3000, pause: true},
		{name: "permanent_delay_step_120ms", frames: 3000, delayStep: true},
		{name: "clock_slow_150ppm_30min", frames: 90000, clockPPM: 150},
		{name: "clock_fast_150ppm_30min", frames: 90000, clockPPM: -150},
	}
	for _, p := range profiles {
		t.Run(p.name, func(t *testing.T) {
			baseline := simulateImpairment(t, p, false)
			protected := simulateImpairment(t, p, true)
			for _, r := range []impairmentResult{baseline, protected} {
				b, _ := json.Marshal(r)
				t.Log(string(b))
			}
			if p.name == "clean" && protected.Played != p.frames {
				t.Fatal("clean stream lost frames")
			}
			if p.burst && protected.Played != p.frames {
				t.Fatal("two-packet burst not recovered exactly")
			}
			if p.loss > 0 && protected.Played-baseline.Played < baseline.NetworkLost*9/10 {
				t.Fatal("RED recovered less than 90% of primary loss")
			}
			if protected.Played < p.frames*98/100 {
				t.Fatal("more than 2% of frames missing")
			}
			if p.delayStep && protected.Resyncs != 1 {
				t.Fatal("path delay failed to settle")
			}
			if p.clockPPM != 0 && protected.Resyncs > 8 {
				t.Fatal("unstable clock recovery")
			}
		})
	}
}
