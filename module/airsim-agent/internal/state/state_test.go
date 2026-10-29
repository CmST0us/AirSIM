package state

import (
	"airsim.local/airsim-agent/internal/hal"
	"testing"
	"time"
)

func TestReadyDegradedAndStale(t *testing.T) {
	s := New("m", "b", "rm500u-embedded")
	fs := map[string]hal.Field{}
	for _, k := range []string{"sim", "signal", "registration", "calls", "network", "platform"} {
		fs[k] = hal.Available("fake", nil)
	}
	fs["ims"] = hal.Unavailable("at", "query_failed")
	s.Commit(fs, true, "")
	v, r := s.View(time.Now())
	if !r.Ready || !r.Degraded || r.VoiceReady || v.Revision != 1 {
		t.Fatal(r)
	}
	v, r = s.View(time.Now().Add(31 * time.Second))
	if r.Ready || v.Freshness != "stale" || v.Fields["signal"].Data != nil {
		t.Fatal("stale still ready")
	}
	s.Invalidate("at_desynchronized")
	_, r = s.View(time.Now())
	if r.Ready {
		t.Fatal("fence still ready")
	}
}
func TestFailedSampleDoesNotReuseData(t *testing.T) {
	s := New("m", "b", "rm500u-embedded")
	s.Commit(map[string]hal.Field{"sim": hal.Available("at", hal.SIM{State: "READY"})}, true, "")
	s.Commit(map[string]hal.Field{"sim": hal.Unavailable("at", "query_failed")}, true, "")
	v, r := s.View(time.Now())
	if r.Ready || v.Revision != 2 || v.Fields["sim"].Data != nil || v.Fields["sim"].ObservedAt != nil {
		t.Fatal("failed result reused")
	}
}

func TestFenceInvalidatesPreviouslyReadyCapabilities(t *testing.T) {
	s := New("m", "b", "rm500u-embedded")
	fields := map[string]hal.Field{}
	for _, k := range []string{"sim", "signal", "registration", "ims", "calls", "network", "platform"} {
		fields[k] = hal.Available("fake", nil)
	}
	s.Commit(fields, true, "")
	s.Invalidate("at_desynchronized")
	v, r := s.View(time.Now())
	if r.Ready || v.Fields["calls"].Status != "unavailable" || s.Capabilities(time.Now()).Capabilities["telephony"].Readiness == "ready" {
		t.Fatal("advertised old ready data after fence")
	}
}
