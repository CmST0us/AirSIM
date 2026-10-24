package control

import (
	"airsim.local/server/internal/media"
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestSlowMediaDoesNotHoldGlobalLockOrRevive(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			once.Do(func() { close(entered) })
			<-release
		}
		w.WriteHeader(204)
	}))
	defer backend.Close()
	s := New(nil, Config{MediaInternal: backend.URL, MediaToken: wire.Token()})
	defer s.mediaHTTP.CloseIdleConnections()
	s.mediaOwner = func(context.Context, media.Spec) (bool, error) { return true, nil }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	module, boot, epoch, call, connection := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.ID()
	pctx, pcancel := context.WithCancel(ctx)
	defer pcancel()
	p := &peer{module: module, boot: boot, backend: epoch, epoch: connection, ctx: pctx, cancel: pcancel, queue: make(chan Envelope, 32), snapshot: &Snapshot{Calls: Calls{Calls: []Call{{ID: call, State: "active", Ownership: "managed"}}}}}
	s.peers[module] = p
	m := &mediaSession{Request: wire.ID(), Ticket: wire.Token(), AgentTicket: wire.Token(), busy: true, Spec: media.Spec{ID: wire.ID(), Module: module, Call: call, Boot: boot, Backend: epoch, Connection: connection, Generation: wire.ID()}}
	s.sessions[m.Request] = m
	done := make(chan struct{})
	go func() { defer close(done); s.performMedia(ctx, m) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("renew never entered")
	}
	// A second module can process heartbeat and its bounded command queue while renew is stalled.
	progress := make(chan struct{})
	go func() {
		s.mu.Lock()
		otherCtx, otherCancel := context.WithCancel(ctx)
		defer otherCancel()
		other := &peer{ctx: otherCtx, cancel: otherCancel, queue: make(chan Envelope, 32), boot: wire.ID(), backend: wire.ID(), queried: true}
		if !s.consume(other, Envelope{Type: "heartbeat", Payload: json.RawMessage(`{}`)}) || !s.enqueue(other, "command", map[string]string{"command_id": wire.ID()}) {
			t.Error("other module did not progress")
		}
		snap := Snapshot{Boot: other.boot, Backend: other.backend, Observed: time.Now().UTC(), Control: Status{Schema: 1, Boot: other.boot, Backend: other.backend}, Calls: Calls{Boot: other.boot, Backend: other.backend, Calls: []Call{}}, Audio: json.RawMessage(`{"available":false,"implementation":"test","verification":"unverified","voice_ready":false,"reason":"test"}`)}
		payload, _ := json.Marshal(snap)
		if !s.consume(other, Envelope{Type: "snapshot", Payload: payload}) {
			t.Error("other module snapshot blocked")
		}
		s.stopMedia(ctx, m, "control_closed")
		s.mu.Unlock()
		close(progress)
	}()
	select {
	case <-progress:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("global lock blocked by media I/O")
	}
	close(release)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("worker stuck")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !m.Closed || m.Ticket != "" || m.AgentTicket != "" || m.busy {
		t.Fatal("stale renew revived or retained credentials")
	}
}
func TestMediaHistoryCapPreservesClosedIdentity(t *testing.T) {
	s := New(nil, Config{})
	defer s.mediaHTTP.CloseIdleConnections()
	module, client, call, epoch, generation := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.ID()
	var old string
	for i := 0; i < 10000; i++ {
		id := wire.ID()
		ready := make(chan struct{})
		close(ready)
		s.sessions[id] = &mediaSession{Request: id, Closed: true, ready: ready, Spec: media.Spec{Module: module, Client: client, Call: call, Connection: epoch, Generation: generation}}
		old = id
	}
	request := func(id string) int {
		body, _ := json.Marshal(map[string]string{"request_id": id, "connection_epoch": epoch, "generation": generation})
		r := httptest.NewRequest("POST", "/", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.mediaAPI(w, r, "", client, module, []string{module, "calls", call, "media-sessions"})
		return w.Code
	}
	if request(wire.ID()) != 429 {
		t.Fatal("history cap not enforced")
	}
	if request(old) != 410 {
		t.Fatal("closed idempotency evicted")
	}
}
