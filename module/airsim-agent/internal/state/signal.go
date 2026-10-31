package state

import (
	"time"

	"airsim.local/airsim-agent/internal/hal"
)

// SignalView carries the radio sample independently of control snapshot freshness.
type SignalView struct {
	Available  bool       `json:"available"`
	ObservedAt *time.Time `json:"observed_at"`
	RSSI       *int       `json:"rssi"`
	DBM        *int       `json:"dbm"`
}

func (s *Store) Signal(now time.Time) SignalView {
	v, _ := s.View(now)
	f := v.Fields["signal"]
	out := SignalView{ObservedAt: f.ObservedAt}
	signal, ok := f.Data.(hal.Signal)
	if f.Status != "available" || !ok || signal.RSSI < 0 || signal.RSSI > 31 {
		return out
	}
	dbm := -113 + 2*signal.RSSI
	out.Available = true
	out.RSSI = &signal.RSSI
	out.DBM = &dbm
	return out
}
