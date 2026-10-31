package cloud

import (
	"context"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/journal"
	"airsim.local/airsim-agent/internal/media"
	"github.com/coder/websocket"
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
		t.Run(map[bool]string{false: "poll", true: "receipt_query"}[query], func(t *testing.T) { testAnswerStartsMedia(t, query, 0) })
	}
}
func TestAnswerStartsMediaAfterSlowWANUpgrade(t *testing.T) {
	testAnswerStartsMedia(t, false, 6*time.Second)
}

func testAnswerStartsMedia(t *testing.T, query bool, delay time.Duration) {
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
	server := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return
			}
		}
		ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}})
		if e != nil {
			return
		}
		defer ws.CloseNow()
		_, raw, e := ws.Read(ctx)
		if e != nil {
			return
		}
		var auth struct {
			ID string `json:"session_id"`
		}
		json.Unmarshal(raw, &auth)
		raw, _ = json.Marshal(map[string]any{"type": "paired", "session_id": auth.ID, "format": media.LC3Format})
		ws.Write(ctx, websocket.MessageText, raw)
		_, _, _ = ws.Read(ctx)
	}))
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
	raw, _ = json.Marshal(map[string]any{"request_id": uid(), "session_id": uid(), "call_id": call, "agent_boot_id": boot, "backend_epoch": backend.epoch, "client_installation_id": client, "generation": generation, "ticket": strings.Repeat("a", 64), "expires_at": time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano), "format": media.LC3Format})
	if !c.handle(envelope{Type: "media_start", Payload: raw}) {
		t.Fatal("media_start rejected")
	}
	if c.mediaDone == nil {
		t.Fatal("observed answer did not establish media ownership")
	}
	<-c.mediaDone
	c.wg.Wait()
	if fm.creates.Load() != 1 {
		t.Fatal("media_start did not reach local media creation")
	}
}

func TestMediaSetupDeadlineHonorsTicketAndParent(t *testing.T) {
	now := time.Now().UTC()
	for _, tc := range []struct {
		name         string
		ticket, want time.Duration
	}{{"wan_budget", 30 * time.Second, 20 * time.Second}, {"ticket_expiry", 8 * time.Second, 8 * time.Second}, {"already_expired", -time.Second, -time.Second}} {
		t.Run(tc.name, func(t *testing.T) {
			deadline := mediaSetupDeadline(now, now.Add(tc.ticket).Format(time.RFC3339Nano))
			if !deadline.Equal(now.Add(tc.want)) {
				t.Fatal("incorrect setup deadline")
			}
		})
	}
	parent, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	ctx, stop := context.WithDeadline(parent, mediaSetupDeadline(now, now.Add(30*time.Second).Format(time.RFC3339Nano)))
	defer stop()
	<-ctx.Done()
	if ctx.Err() != context.DeadlineExceeded {
		t.Fatal("parent deadline was extended")
	}
	expired, stopExpired := context.WithDeadline(context.Background(), mediaSetupDeadline(now, now.Add(-time.Second).Format(time.RFC3339Nano)))
	defer stopExpired()
	select {
	case <-expired.Done():
	case <-time.After(time.Second):
		t.Fatal("expired ticket did not cancel setup")
	}
}
