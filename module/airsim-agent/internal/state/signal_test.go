package state

import (
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/hal"
)

func TestSignalSample(t *testing.T) {
	now := time.Now().UTC()
	for _, tc := range []struct {
		name      string
		rssi      int
		age       time.Duration
		atOK      bool
		available bool
	}{
		{"weak", 0, 0, true, true},
		{"strong", 31, 0, true, true},
		{"unknown", 99, 0, true, false},
		{"fresh_boundary", 20, 30 * time.Second, true, true},
		{"stale", 20, 31 * time.Second, true, false},
		{"at_unavailable", 20, 0, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := New("module", "boot", "profile")
			observed := now.Add(-tc.age)
			s.Commit(map[string]hal.Field{"signal": {Status: "available", ObservedAt: &observed, Data: hal.Signal{RSSI: tc.rssi}}}, tc.atOK, "at_unavailable")
			got := s.Signal(now)
			if got.Available != tc.available || got.ObservedAt == nil || !got.ObservedAt.Equal(observed) {
				t.Fatalf("unexpected availability or sample time: %+v", got)
			}
			if tc.available {
				if got.RSSI == nil || *got.RSSI != tc.rssi || got.DBM == nil || *got.DBM != -113+2*tc.rssi {
					t.Fatalf("incorrect strength: %+v", got)
				}
			} else if got.RSSI != nil || got.DBM != nil {
				t.Fatal("unavailable sample retained strength")
			}
		})
	}
	s := New("module", "boot", "profile")
	if got := s.Signal(now); got.Available || got.ObservedAt != nil || got.RSSI != nil || got.DBM != nil {
		t.Fatal("initializing sample must be unavailable without a timestamp")
	}
	s.Commit(map[string]hal.Field{"signal": hal.Unavailable("at", "query_failed")}, true, "")
	if got := s.Signal(now); got.Available || got.ObservedAt != nil || got.RSSI != nil || got.DBM != nil {
		t.Fatal("failed query must not fabricate a sample")
	}
}
