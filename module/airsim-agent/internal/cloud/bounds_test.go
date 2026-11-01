package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testConnection(t *testing.T) (*connection, *fakeControl) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	fc := &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}
	a := &Agent{Control: fc, Media: &fakeMedia{}, owners: map[string]owner{}, bindings: map[string]string{}}
	return &connection{agent: a, life: ctx, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 32), pending: map[string]*pendingReceipt{}, owners: a.owners}, fc
}
func TestControlBoundsAndNoOwnershipAdoption(t *testing.T) {
	c, fc := testConnection(t)
	for i := 0; i < 32; i++ {
		if !c.send("heartbeat", struct{}{}) {
			t.Fatal("early full")
		}
	}
	if c.send("heartbeat", struct{}{}) || c.ctx.Err() == nil {
		t.Fatal("full queue must disconnect")
	}
	c, fc = testConnection(t)
	r := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Deadline: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano), Action: "call.answer", Args: control.Args{CallID: fc.call}}
	p := &pendingReceipt{request: r, client: uid(), generation: uid()}
	if !c.receipt(p, map[string]string{"state": "observed", "call_id": fc.call}, 200) {
		t.Fatal("receipt")
	}
	if len(c.owners) != 0 {
		t.Fatal("adopted local/journal call without cloud submission")
	}
	query, _ := json.Marshal(map[string]string{"command_id": r.CommandID})
	if !c.handle(envelope{Type: "receipt_query", Payload: query}) || fc.submitted.Load() != 0 {
		t.Fatal("query caused side effect")
	}
	for i := 0; i < 64; i++ {
		c.pending[uid()] = p
	}
	command, _ := json.Marshal(map[string]any{"client_installation_id": uid(), "generation": uid(), "command": r})
	if !c.handle(envelope{Type: "command", Payload: command}) || fc.submitted.Load() != 0 {
		t.Fatal("pending cap")
	}
	c, fc = testConnection(t)
	r.BootID = fc.boot
	r.Epoch = fc.epoch
	r.Args.CallID = fc.call
	client, generation := uid(), uid()
	command, _ = json.Marshal(map[string]any{"client_installation_id": client, "generation": generation, "command": r})
	if !c.handle(envelope{Type: "command", Payload: command}) {
		t.Fatal("submit")
	}
	if fc.submitted.Load() != 1 {
		t.Fatal("submit count")
	}
	command, _ = json.Marshal(map[string]any{"client_installation_id": uid(), "generation": uid(), "command": r})
	if !c.handle(envelope{Type: "command", Payload: command}) || fc.submitted.Load() != 1 {
		t.Fatal("duplicate ownership conflict")
	}
}
func TestMediaOwnerWrongSessionStopAndOfferValidation(t *testing.T) {
	c, fc := testConnection(t)
	r := testMediaStart(fc, time.Now().Add(15*time.Second))
	b, _ := json.Marshal(r)
	if !c.startMedia(b) {
		t.Fatal("owner rejection should report status")
	}
	if c.agent.Media.(*fakeMedia).creates.Load() != 0 {
		t.Fatal("foreign owner created media")
	}
	canceled := false
	session := uid()
	release := c.agent.takeBridge(session, func() { canceled = true })
	defer release()
	stop, _ := json.Marshal(map[string]string{"session_id": uid(), "reason": "client_stop"})
	if !c.handle(envelope{Type: "media_stop", Payload: stop}) || canceled {
		t.Fatal("wrong session stopped")
	}
	stop, _ = json.Marshal(map[string]string{"session_id": session, "reason": "client_stop"})
	if !c.handle(envelope{Type: "media_stop", Payload: stop}) || !canceled {
		t.Fatal("matching stop")
	}
	for _, mutate := range []func(*mediaStart){
		func(r *mediaStart) { r.Offer = "not sdp" },
		func(r *mediaStart) { r.Offer = "v=0\r\n" + strings.Repeat("a", maxSDP) },
		func(r *mediaStart) { r.Servers = nil },
		func(r *mediaStart) {
			r.Servers = []json.RawMessage{json.RawMessage(`{"urls":["stun:203.0.113.7:3478"],"username":"u","credential":"c"}`)}
		},
		func(r *mediaStart) {
			r.Servers = []json.RawMessage{json.RawMessage(`{"urls":["turn:203.0.113.7:3478"],"username":"","credential":"c"}`)}
		},
		func(r *mediaStart) {
			r.Servers = []json.RawMessage{json.RawMessage(`{"urls":["turn:203.0.113.7:3478"],"username":"u","credential":"c","extra":1}`)}
		},
	} {
		bad := testMediaStart(fc, time.Now().Add(15*time.Second))
		mutate(&bad)
		b, _ := json.Marshal(bad)
		if c.startMedia(b) {
			t.Fatal("malformed media_start accepted")
		}
	}
}

func testMediaStart(fc *fakeControl, expires time.Time) mediaStart {
	return mediaStart{Request: uid(), Session: uid(), Call: fc.call, Boot: fc.boot, Epoch: fc.epoch, Client: uid(), Generation: uid(), Expires: expires.UTC().Format(time.RFC3339Nano), Offer: "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n", Servers: []json.RawMessage{json.RawMessage(`{"urls":["turn:203.0.113.7:3478?transport=udp","turn:203.0.113.7:3478?transport=tcp"],"username":"1:` + uid() + `:agent","credential":"c2VjcmV0"}`)}}
}

// Allocations are scoped to a read-only control snapshot/message synchronization;
// this is not a claim about RM500 RSS or real TLS/voice endurance.
func BenchmarkCloudSnapshot(b *testing.B) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fc := &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}
	a := &Agent{Control: fc, Media: &fakeMedia{}}
	c := &connection{agent: a, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 32), owners: map[string]owner{}}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		var last synced
		if !c.sync(&last) {
			b.Fatal("sync")
		}
		for len(c.queue) > 0 {
			<-c.queue
		}
	}
}

func TestAcceptedReceiptSlotsReleasedAndObservationBounded(t *testing.T) {
	c, _ := testConnection(t)
	now := time.Now()
	for _, action := range []string{"call.dial", "call.dtmf", "sms.send"} {
		for i := 0; i < 130; i++ {
			id := uid()
			p := &pendingReceipt{request: control.Request{CommandID: id, Action: action}}
			c.pending[id] = p
			if !c.receiptAt(p, map[string]string{"command_id": id, "state": "accepted"}, 200, now) {
				t.Fatal("receipt")
			}
			<-c.queue
			if len(c.pending) != 0 {
				t.Fatal("accepted slot retained", action, i)
			}
		}
	}
	for _, action := range []string{"call.answer", "call.hangup"} {
		id := uid()
		p := &pendingReceipt{request: control.Request{CommandID: id, Action: action}}
		c.pending[id] = p
		value := map[string]string{"command_id": id, "state": "accepted"}
		if !c.receiptAt(p, value, 200, now) {
			t.Fatal("initial receipt")
		}
		<-c.queue
		if len(c.pending) != 1 {
			t.Fatal("missing observation")
		}
		if !c.receiptAt(p, value, 200, now.Add(10999*time.Millisecond)) || len(c.pending) != 1 {
			t.Fatal("early release")
		}
		if !c.receiptAt(p, value, 200, now.Add(11*time.Second)) || len(c.pending) != 0 {
			t.Fatal("observation timeout")
		}
		if len(c.queue) != 0 || value["state"] != "accepted" {
			t.Fatal("fabricated terminal receipt")
		}
	}
}

func TestMediaAnswerDeadlineClockSkewExactBoundaries(t *testing.T) {
	serverNow := time.Date(2026, 10, 24, 12, 0, 0, 123456789, time.UTC)
	answerBy := serverNow.Add(15 * time.Second)
	expires := answerBy.Format(time.RFC3339Nano)
	tests := []struct {
		name  string
		now   time.Time
		valid bool
	}{
		{"normal_15_seconds", serverNow, true},
		{"device_behind_1_second", serverNow.Add(-time.Second), true},
		{"device_behind_5_seconds_exact_20", serverNow.Add(-5 * time.Second), true},
		{"over_20_by_nanosecond", serverNow.Add(-5*time.Second - time.Nanosecond), false},
		{"one_nanosecond_remaining", answerBy.Add(-time.Nanosecond), true},
		{"exactly_current", answerBy, false},
		{"expired_by_nanosecond", answerBy.Add(time.Nanosecond), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if validMediaExpiry(expires, tt.now) != tt.valid {
				t.Fatal("expiry boundary")
			}
			c, fc := testConnection(t)
			r := testMediaStart(fc, answerBy)
			payload, _ := json.Marshal(r)
			if c.startMediaAt(payload, tt.now) != tt.valid {
				t.Fatal("startMedia protocol boundary")
			}
			if c.agent.Media.(*fakeMedia).creates.Load() != 0 {
				t.Fatal("unexpected local media creation")
			}
			if tt.valid {
				select {
				case out := <-c.queue:
					if out.kind != "media_status" {
						t.Fatal("wrong reply")
					}
					b, _ := json.Marshal(out.payload)
					var v map[string]string
					if json.Unmarshal(b, &v) != nil || v["reason"] != "media_owner" || v["state"] != "closed" || v["session_id"] != r.Session {
						t.Fatal("did not reach owner rejection")
					}
				default:
					t.Fatal("missing owner rejection")
				}
			} else if len(c.queue) != 0 {
				t.Fatal("invalid expiry passed protocol validation")
			}
			if r.Expires != expires {
				t.Fatal("absolute answer deadline changed")
			}
		})
	}
	if validMediaExpiry("not-a-time", serverNow) {
		t.Fatal("malformed expiry")
	}
}
