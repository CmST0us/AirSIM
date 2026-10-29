package state

import (
	"airsim.local/airsim-agent/internal/hal"
	"sync"
	"time"
)

type Snapshot struct {
	Schema        int                  `json:"schema_version"`
	ModuleID      string               `json:"module_id"`
	BootID        string               `json:"agent_boot_id"`
	Revision      uint64               `json:"revision"`
	ObservedAt    time.Time            `json:"observed_at"`
	Freshness     string               `json:"freshness"`
	Scope         string               `json:"scope"`
	VoiceReady    bool                 `json:"voice_ready"`
	IdentityState string               `json:"identity_state"`
	Fields        map[string]hal.Field `json:"fields"`
}
type Ready struct {
	Ready      bool     `json:"ready"`
	Scope      string   `json:"scope"`
	Degraded   bool     `json:"degraded"`
	VoiceReady bool     `json:"voice_ready"`
	Reasons    []string `json:"reasons"`
}
type Capabilities struct {
	Schema       int                       `json:"schema_version"`
	ModuleID     string                    `json:"module_id"`
	Profile      string                    `json:"profile"`
	Capabilities map[string]hal.Capability `json:"capabilities"`
}
type Store struct {
	profile  string
	mu       sync.RWMutex
	s        Snapshot
	atOK     bool
	reason   string
	observed map[string]time.Time
}

func New(module, boot, profile string) *Store {
	s := &Store{profile: profile, s: Snapshot{Schema: 1, ModuleID: module, BootID: boot, Scope: "read_only", IdentityState: "unenrolled", Fields: map[string]hal.Field{}}, reason: "initializing", observed: map[string]time.Time{}}
	for _, k := range []string{"sim", "signal", "registration", "ims", "calls", "network", "platform"} {
		s.s.Fields[k] = hal.Unavailable("", "initializing")
	}
	return s
}
func (s *Store) Commit(fields map[string]hal.Field, atOK bool, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.s.Revision++
	s.s.ObservedAt = time.Now().UTC()
	s.s.Fields = fields
	s.atOK = atOK
	s.reason = reason
	for k, f := range fields {
		if f.ObservedAt != nil {
			s.observed[k] = *f.ObservedAt
		}
	}
}
func (s *Store) View(now time.Time) (Snapshot, Ready) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v := s.s
	v.Fields = map[string]hal.Field{}
	r := Ready{Ready: s.atOK, Scope: "read_only", Reasons: []string{}}
	seen := map[string]bool{}
	add := func(code string) {
		if code != "" && !seen[code] {
			r.Reasons = append(r.Reasons, code)
			seen[code] = true
		}
	}
	if !s.atOK {
		add(s.reason)
	}
	stale := false
	for k, f := range s.s.Fields {
		if !s.atOK && (k == "sim" || k == "signal" || k == "registration" || k == "ims" || k == "calls") {
			f.Status = "unavailable"
			f.ErrorCode = s.reason
			f.Data = nil
		}
		if f.Status == "available" && now.Sub(s.observed[k]) > 30*time.Second {
			f.Status = "unavailable"
			f.ErrorCode = "stale"
			f.Data = nil
			stale = true
		}
		if f.ObservedAt != nil {
			t := f.ObservedAt.UTC()
			f.ObservedAt = &t
		}
		v.Fields[k] = f
		if f.Status != "available" {
			r.Degraded = true
			add(f.ErrorCode)
			if k == "sim" || k == "signal" || k == "registration" || k == "calls" {
				r.Ready = false
			}
		}
	}
	for _, k := range []string{"sim", "signal", "registration", "calls"} {
		if _, ok := v.Fields[k]; !ok {
			r.Ready = false
			r.Degraded = true
			add("initializing")
		}
	}
	v.Freshness = "fresh"
	if !r.Ready {
		v.Freshness = "unavailable"
	}
	if stale {
		v.Freshness = "stale"
	}
	return v, r
}
func (s *Store) Capabilities(now time.Time) Capabilities {
	v, r := s.View(now)
	c := Capabilities{1, v.ModuleID, s.profile, map[string]hal.Capability{}}
	for cap, fields := range map[string][]string{"telephony": {"calls"}, "radio_sim": {"sim", "signal", "registration", "ims"}, "network": {"network"}, "platform": {"platform"}} {
		x := hal.Capability{Support: "supported", Readiness: "ready"}
		for _, k := range fields {
			f := v.Fields[k]
			if f.Status != "available" {
				x.Readiness = "unavailable"
				x.Reason = f.ErrorCode
			}
		}
		if cap == "radio_sim" && r.Ready && r.Degraded {
			x.Readiness = "degraded"
		}
		c.Capabilities[cap] = x
	}
	for _, k := range []string{"audio", "messaging"} {
		c.Capabilities[k] = hal.Capability{Support: "unknown", Readiness: "unavailable", Reason: "not_implemented"}
	}
	c.Capabilities["audio"] = hal.Capability{Support: "implemented", Readiness: "unverified", Reason: "profile_not_verified"}
	return c
}

func (s *Store) Invalidate(code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.atOK = false
	s.reason = code
}
