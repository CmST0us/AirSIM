package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestSnapshotSignalContract(t *testing.T) {
	cases := []struct {
		name, signal string
		valid        bool
	}{
		{"legacy", "", true},
		{"null", "null", true},
		{"available", `{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":20,"dbm":-73}`, true},
		{"zero", `{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":0,"dbm":-113}`, true},
		{"unavailable", `{"available":false,"observed_at":null,"rssi":null,"dbm":null}`, true},
		{"expired", `{"available":false,"observed_at":"2026-10-31T00:00:00Z","rssi":null,"dbm":null}`, true},
		{"unknownCSQ", `{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":99,"dbm":85}`, false},
		{"missingTime", `{"available":true,"observed_at":null,"rssi":20,"dbm":-73}`, false},
		{"offsetTime", `{"available":true,"observed_at":"2026-10-31T00:00:00+00:00","rssi":20,"dbm":-73}`, false},
		{"badTime", `{"available":true,"observed_at":"invalidZ","rssi":20,"dbm":-73}`, false},
		{"badDBM", `{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":20,"dbm":-72}`, false},
		{"cachedUnavailable", `{"available":false,"observed_at":null,"rssi":20,"dbm":-73}`, false},
		{"missingField", `{"available":false,"rssi":null,"dbm":null}`, false},
		{"unknownField", `{"available":false,"observed_at":null,"rssi":null,"dbm":null,"extra":0}`, false},
		{"nullAvailable", `{"available":null,"observed_at":null,"rssi":null,"dbm":null}`, false},
		{"fraction", `{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":20.5,"dbm":-72}`, false},
		{"duplicate", `{"available":false,"available":true,"observed_at":null,"rssi":null,"dbm":null}`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := New(nil, Config{})
			p := &peer{ctx: context.Background(), boot: wire.ID(), backend: wire.ID(), queried: true}
			snap := Snapshot{Boot: p.boot, Backend: p.backend, Observed: time.Now().UTC(), Control: Status{Schema: 1, Boot: p.boot, Backend: p.backend}, Calls: Calls{Boot: p.boot, Backend: p.backend, Calls: []Call{}}, Audio: json.RawMessage(`{"available":false,"implementation":"test","verification":"unverified","voice_ready":false,"reason":"test"}`), Signal: json.RawMessage(tc.signal)}
			payload, err := json.Marshal(snap)
			if err != nil {
				t.Fatal(err)
			}
			if got := s.consume(p, Envelope{Type: "snapshot", Payload: payload}); got != tc.valid {
				t.Fatalf("accepted = %v, want %v", got, tc.valid)
			}
			if tc.valid && string(p.snapshot.Signal) != tc.signal {
				t.Fatal("signal not preserved")
			}
		})
	}
}

func TestModuleSignalVisibility(t *testing.T) {
	s := New(nil, Config{})
	signal := json.RawMessage(`{"available":true,"observed_at":"2026-10-31T00:00:00Z","rssi":20,"dbm":-73}`)
	for _, id := range []string{wire.ID(), wire.ID()} {
		p := &peer{module: id, snapshot: &Snapshot{Signal: signal}}
		s.peers[id], s.last[id] = p, p
		if got := s.moduleSummary(id)["signal"]; string(got.(json.RawMessage)) != string(signal) {
			t.Fatal("directory lost signal")
		}
		if string(visibleSnapshot(p, true).Signal) != string(signal) {
			t.Fatal("snapshot lost signal")
		}
		delete(s.peers, id)
		if _, ok := s.moduleSummary(id)["signal"]; ok {
			t.Fatal("offline directory retained signal")
		}
		if len(visibleSnapshot(p, false).Signal) != 0 {
			t.Fatal("offline snapshot retained signal")
		}
		if string(p.snapshot.Signal) != string(signal) {
			t.Fatal("cached snapshot mutated")
		}
	}
}
