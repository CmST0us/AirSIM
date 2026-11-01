package cloud

import (
	"context"
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/journal"
)

type answerBackend struct {
	epoch    string
	events   chan hal.ControlEvent
	executed chan struct{}
	release  chan struct{}
}

func (b *answerBackend) Snapshot(context.Context) (hal.ControlSnapshot, error) {
	return hal.ControlSnapshot{}, nil
}
func (b *answerBackend) Execute(ctx context.Context, a hal.WriteAction) hal.WriteResult {
	close(b.executed)
	select {
	case <-b.release:
	case <-ctx.Done():
	}
	return hal.WriteResult{Object: a.Object}
}
func (b *answerBackend) EpochID() string                 { return b.epoch }
func (b *answerBackend) Events() <-chan hal.ControlEvent { return b.events }
func (*answerBackend) Overflow() <-chan struct{}         { return nil }
func (*answerBackend) Done() <-chan struct{}             { return nil }
func (*answerBackend) Dropped() uint64                   { return 0 }
func (*answerBackend) Close()                            {}

// A receipt query can observe the answer before the next cloud polling tick.
// The observed receipt must establish ownership before media_start is consumed.
func TestAnswerStartsMediaWithRealCoordinator(t *testing.T) {
	for _, query := range []bool{false, true} {
		t.Run(map[bool]string{false: "poll", true: "receipt_query"}[query], func(t *testing.T) { testAnswerStartsMedia(t, query) })
	}
}

func testAnswerStartsMedia(t *testing.T, query bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	store, err := journal.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	boot := uid()
	backend := &answerBackend{epoch: uid(), events: make(chan hal.ControlEvent, 1), executed: make(chan struct{}), release: make(chan struct{})}
	coordinator := control.New(boot, hash, func() bool { return true }, store, nil)
	go coordinator.RunWithBackend(ctx, func(context.Context) (hal.ControlSession, error) { return backend, nil })
	defer func() { cancel(); <-coordinator.Done() }()
	for {
		v, _ := coordinator.View(ctx, "control", "")
		if status, ok := v.(control.Status); ok && status.Ready {
			break
		}
		if ctx.Err() != nil {
			t.Fatal("control not ready")
		}
		time.Sleep(time.Millisecond)
	}
	backend.events <- hal.ControlEvent{Kind: "call.add", Object: "/call/1", State: "incoming", Sequence: 1}
	var call string
	for call == "" {
		v, _ := coordinator.View(ctx, "calls", "")
		if cv, ok := v.(control.CallsView); ok && cv.Available && len(cv.Calls) == 1 {
			call = cv.Calls[0].ID
		}
		if ctx.Err() != nil {
			t.Fatal("control did not become ready")
		}
		time.Sleep(time.Millisecond)
	}
	f := newFixture(t)
	server := tlsServer(t, f, http.NotFoundHandler())
	f.req.API = server.URL
	f.req.Device = server.URL
	f.req.Media = server.URL
	f.prepare(t)
	f.issue(t)
	if f.p.Activate(f.bundle) != 200 {
		t.Fatal("activate")
	}
	fm := &fakeMedia{id: uid(), socket: filepath.Join(t.TempDir(), "absent.sock")}
	a := &Agent{Control: coordinator, Media: fm, P: f.p, owners: map[string]owner{}, bindings: map[string]string{}}
	c := &connection{agent: a, config: f.p.config, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 32), pending: map[string]*pendingReceipt{}, owners: a.owners}
	client, generation := uid(), uid()
	req := control.Request{CommandID: uid(), BootID: boot, Epoch: backend.epoch, Deadline: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano), Action: "call.answer", Args: control.Args{CallID: call}}
	raw, _ := json.Marshal(map[string]any{"client_installation_id": client, "generation": generation, "command": req})
	if !c.handle(envelope{Type: "command", Payload: raw}) {
		t.Fatal("command rejected")
	}
	select {
	case <-backend.executed:
	case <-ctx.Done():
		t.Fatalf("answer did not execute: %+v", <-c.queue)
	}
	if query {
		raw, _ = json.Marshal(map[string]string{"command_id": req.CommandID})
		for i := 0; i < 2; i++ {
			before := len(c.queue)
			if !c.handle(envelope{Type: "receipt_query", Payload: raw}) || len(c.queue) != before+1 {
				t.Fatal("pending receipt query must reply every time")
			}
		}
	}
	close(backend.release)
	backend.events <- hal.ControlEvent{Kind: "call.state", Object: "/call/1", State: "active", Sequence: 2}
	for {
		v, _ := coordinator.View(ctx, "command", req.CommandID)
		raw, _ = json.Marshal(v)
		var receipt struct {
			State string `json:"state"`
		}
		json.Unmarshal(raw, &receipt)
		if receipt.State == "observed" {
			break
		}
		if ctx.Err() != nil {
			t.Fatal("answer not observed")
		}
		time.Sleep(time.Millisecond)
	}
	raw, _ = json.Marshal(map[string]string{"command_id": req.CommandID})
	if query {
		if !c.handle(envelope{Type: "receipt_query", Payload: raw}) {
			t.Fatal("receipt query rejected")
		}
	} else {
		value, code := coordinator.View(ctx, "command", req.CommandID)
		if !c.receipt(c.pending[req.CommandID], value, code) {
			t.Fatal("receipt rejected")
		}
	}
	start := testMediaStart(&fakeControl{call: call, boot: boot, epoch: backend.epoch}, time.Now().Add(15*time.Second))
	start.Client, start.Generation = client, generation
	raw, _ = json.Marshal(start)
	if !c.handle(envelope{Type: "media_start", Payload: raw}) {
		t.Fatal("media_start rejected")
	}
	if c.mediaDone == nil {
		t.Fatal("observed answer did not establish media ownership")
	}
	<-c.mediaDone
	c.wg.Wait()
	// The test offer is not negotiable, so the session ends at the answer step.
	if s := a.LastBridgeStats(); s.SessionID != start.Session || s.Reason != "media_offer" {
		t.Fatalf("media_start did not reach WebRTC negotiation: %+v", s)
	}
}
