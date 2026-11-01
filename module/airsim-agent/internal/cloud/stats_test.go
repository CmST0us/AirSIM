package cloud

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestLocalMediaStatsLifecycleAndRace(t *testing.T) {
	f := newFixture(t)
	a := &Agent{P: f.p}
	handler := WithLocal(http.NotFoundHandler(), f.p, a)
	read := func() BridgeStats {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", "/v2/local/cloud/media-stats", nil))
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
		var s BridgeStats
		if e := exact(w.Body.Bytes(), "session_id,state,reason,candidate,packets_received,packets_sent,packets_lost,packets_late,fec_frames,plc_frames,queue_drops,local_input_gaps,local_stalls,local_stall_max_ms,send_stalls,send_stall_max_ms,rtp_stalls,rtp_stall_max_ms,playout_stalls,playout_stall_max_ms,gc_cycles,heap_live_kb", &s); e != nil {
			t.Fatal("stats fields", e)
		}
		return s
	}
	s := read()
	if s.State != "idle" || s.SessionID != "" || s.Reason != "" || s.Candidate != "" || s.Received+s.Lost+s.LocalGaps+s.Drops+s.PLC != 0 {
		t.Fatal("initial stats", s)
	}
	id := uid()
	counts := &bridgeCounters{}
	a.beginBridge(id, counts)
	if read().State != "starting" {
		t.Fatal("starting")
	}
	counts.candidate.Store("relay")
	a.bridgeState(id, "streaming", "")
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			counts.received.Add(1)
			counts.local.Add(2)
			counts.drops.Add(3)
			counts.plc.Add(4)
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			s := a.LastBridgeStats()
			_, _ = json.Marshal(s)
		}
	}()
	wg.Wait()
	a.endBridge(id, "media_closed")
	s = read()
	if s.State != "closed" || s.Candidate != "relay" || s.Received != 1000 || s.LocalGaps != 2000 || s.Drops != 3000 || s.PLC != 4000 {
		t.Fatal("closed counters", s)
	}
	next := uid()
	a.beginBridge(next, &bridgeCounters{})
	s = read()
	if s.SessionID != next || s.Received+s.LocalGaps+s.Drops+s.PLC != 0 || s.Candidate != "" || s.Reason != "" {
		t.Fatal("new bridge reset")
	}
	a.endBridge(id, "late_old_failure")
	if read().State != "starting" {
		t.Fatal("old bridge changed new stats")
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("POST", "/v2/local/cloud/media-stats", nil))
	if w.Code != 405 {
		t.Fatal("method")
	}
}

func TestStallKeepsLongestInterval(t *testing.T) {
	var s stall
	var last time.Time
	start := time.Now()
	for _, at := range []time.Duration{0, 20, 40, 150, 170, 400, 420} {
		s.observe(&last, start.Add(at*time.Millisecond), frameStall)
	}
	if s.count.Load() != 2 || s.max.Load() != 230 {
		t.Fatalf("stalls %d max %d", s.count.Load(), s.max.Load())
	}
}
