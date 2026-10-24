package cloud

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
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
		if e := exact(w.Body.Bytes(), "session_id,state,reason,cloud_input_gaps,local_input_gaps,queue_drops,zero_frames", &s); e != nil {
			t.Fatal("stats fields", e)
		}
		return s
	}
	s := read()
	if s.State != "idle" || s.SessionID != "" || s.Reason != "" || s.CloudInputGaps+s.LocalInputGaps+s.QueueDrops+s.ZeroFrames != 0 {
		t.Fatal("initial stats", s)
	}
	id := uid()
	counts := &bridgeCounters{}
	a.beginBridge(id, counts)
	if read().State != "starting" {
		t.Fatal("starting")
	}
	a.bridgeState(id, "streaming", "")
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			counts.cloud.Add(1)
			counts.local.Add(2)
			counts.drops.Add(3)
			counts.zeros.Add(4)
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
	if s.State != "closed" || s.CloudInputGaps != 1000 || s.LocalInputGaps != 2000 || s.QueueDrops != 3000 || s.ZeroFrames != 4000 {
		t.Fatal("closed counters", s)
	}
	next := uid()
	a.beginBridge(next, &bridgeCounters{})
	s = read()
	if s.SessionID != next || s.CloudInputGaps+s.LocalInputGaps+s.QueueDrops+s.ZeroFrames != 0 || s.Reason != "" {
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
