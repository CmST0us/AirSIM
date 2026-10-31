package cloud

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/state"
)

func TestSignalSnapshots(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := state.New("module", "boot", "profile")
	a := &Agent{Control: &fakeControl{boot: uid(), epoch: uid(), call: uid()}, Media: &fakeMedia{}, Signal: s}
	c := &connection{agent: a, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 8)}
	u := &USB{agent: a}
	var snap, messages string
	var sent time.Time
	observed := time.Now().UTC().Add(-time.Second)
	for _, rssi := range []int{0, 20, 31, 99} {
		s.Commit(map[string]hal.Field{"signal": {Status: "available", ObservedAt: &observed, Data: hal.Signal{RSSI: rssi}}}, true, "")
		if !c.sync(&snap, &messages, &sent) {
			t.Fatal("cloud snapshot failed")
		}
		var cloudSignal any
		for len(c.queue) > 0 {
			frame := <-c.queue
			if frame.kind == "snapshot" {
				data, err := json.Marshal(frame.payload)
				var payload map[string]json.RawMessage
				if err != nil || json.Unmarshal(data, &payload) != nil {
					t.Fatal("invalid cloud payload")
				}
				cloudSignal = payload["signal"]
			}
		}
		if cloudSignal == nil {
			t.Fatal("signal change did not publish a snapshot")
		}
		usb, err := u.snapshot(ctx)
		if err != nil {
			t.Fatal(err)
		}
		cloudJSON, _ := json.Marshal(cloudSignal)
		usbJSON, _ := json.Marshal(usb["signal"])
		wantJSON, _ := json.Marshal(s.Signal(time.Now()))
		if string(cloudJSON) != string(usbJSON) || string(cloudJSON) != string(wantJSON) {
			t.Fatal("cloud and USB signal differ from the sampled state")
		}
		var wire map[string]any
		if err := json.Unmarshal(cloudJSON, &wire); err != nil || len(wire) != 4 || wire["observed_at"] != observed.Format(time.RFC3339Nano) {
			t.Fatal("signal wire fields or sample timestamp changed")
		}
		if rssi == 99 && (wire["available"] != false || wire["rssi"] != nil || wire["dbm"] != nil) {
			t.Fatal("CSQ 99 exposed as a strength")
		}
	}
	a.Signal = nil
	if got := a.signalView(); got.Available || got.ObservedAt != nil || got.RSSI != nil || got.DBM != nil {
		t.Fatal("missing provider fabricated signal")
	}
}

func TestUSBModuleDirectorySignal(t *testing.T) {
	a, grant, _ := usbFixture(t)
	s := state.New("module", "boot", "profile")
	observed := time.Now().UTC().Add(-time.Second)
	s.Commit(map[string]hal.Field{"signal": {Status: "available", ObservedAt: &observed, Data: hal.Signal{RSSI: 20}}}, true, "")
	a.Signal = s
	w := httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, grant, "GET", "/v2/modules", nil, strings.Repeat("a", 64)))
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	var response struct {
		Modules []struct {
			Signal state.SignalView `json:"signal"`
		} `json:"modules"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || len(response.Modules) != 1 {
		t.Fatal("invalid directory")
	}
	got := response.Modules[0].Signal
	if !got.Available || got.RSSI == nil || *got.RSSI != 20 || got.DBM == nil || *got.DBM != -73 || got.ObservedAt == nil || !got.ObservedAt.Equal(observed) {
		t.Fatal("directory lost signal sample")
	}
}
