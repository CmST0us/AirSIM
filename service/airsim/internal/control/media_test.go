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
	m := &mediaSession{Request: wire.ID(), Ticket: wire.Token(), AgentTicket: wire.Token(), busy: true, Spec: media.Spec{Format: media.Format, ID: wire.ID(), Module: module, Call: call, Boot: boot, Backend: epoch, Connection: connection, Generation: wire.ID()}}
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
		s.sessions[id] = &mediaSession{Request: id, Closed: true, ready: ready, Spec: media.Spec{Format: media.Format, Module: module, Client: client, Call: call, Connection: epoch, Generation: generation}}
		old = id
	}
	request := func(id string) int {
		body, _ := json.Marshal(map[string]string{"request_id": id, "connection_epoch": epoch, "generation": generation, "codec": "lc3"})
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

func TestAgentHelloMediaCodec(t *testing.T) {
	for _, codec := range []string{"", "lc3", "pcm", "LC3"} {
		payload, _ := json.Marshal(map[string]string{"agent_boot_id": wire.ID(), "backend_epoch": wire.ID(), "agent_version": "test", "media_codec": codec})
		var hello agentHello
		if got := decodeAgentHello(payload, &hello); got != (codec == "" || codec == "lc3") {
			t.Fatalf("codec %q accepted=%v", codec, got)
		}
	}
	legacy, _ := json.Marshal(map[string]string{"agent_boot_id": wire.ID(), "backend_epoch": "", "agent_version": "test"})
	var hello agentHello
	if !decodeAgentHello(legacy, &hello) || hello.MediaCodec != "" {
		t.Fatal("legacy hello rejected")
	}
}

func TestMediaCodecRequestAndLegacyAgent(t *testing.T) {
	s := New(nil, Config{})
	module, client, call, epoch := wire.ID(), wire.ID(), wire.ID(), wire.ID()
	p := &peer{epoch: epoch, snapshot: &Snapshot{}}
	s.peers[module] = p
	for _, tc := range []struct {
		codec   string
		include bool
		status  int
	}{
		{"", false, 400}, {"pcm", true, 400}, {"lc3", true, 409},
	} {
		body := map[string]string{"request_id": wire.ID(), "connection_epoch": epoch, "generation": wire.ID()}
		if tc.include {
			body["codec"] = tc.codec
		}
		data, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", "/", bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.mediaAPI(w, r, "", client, module, []string{module, "calls", call, "media-sessions"})
		if w.Code != tc.status {
			t.Fatalf("codec %q: got %d want %d", tc.codec, w.Code, tc.status)
		}
		if tc.codec == "lc3" && !bytes.Contains(w.Body.Bytes(), []byte(`"media_unavailable"`)) {
			t.Fatal("legacy agent error mismatch")
		}
	}
	if s.peers[module] != p {
		t.Fatal("legacy agent control disconnected")
	}
}

func TestMediaResultPreservesSessionFormat(t *testing.T) {
	s := New(nil, Config{Media: "https://media.invalid"})
	m := &mediaSession{Spec: media.Spec{ID: wire.ID(), Format: media.Format}}
	w := httptest.NewRecorder()
	s.mediaResult(w, 201, m)
	var result struct {
		Format media.AudioFormat `json:"format"`
	}
	if json.Unmarshal(w.Body.Bytes(), &result) != nil || result.Format != m.Spec.Format {
		t.Fatal("response format differs from session")
	}
}

func TestLC3HelperReadySnapshot(t *testing.T) {
	s := New(nil, Config{})
	p := &peer{ctx: context.Background(), boot: wire.ID(), backend: wire.ID(), queried: true}
	ready := json.RawMessage(`{"type":"ready","codec":"lc3","codec_frame_us":10000,"codec_frame_bytes":40,"sample_rate":16000,"channels":1,"sample_format":"s16le","frame_samples":320,"capture":{"sample_rate":8000,"period_size":320,"period_count":2,"buffer_frames":640},"playback":{"sample_rate":8000,"period_size":320,"period_count":2,"buffer_frames":640}}`)
	session := map[string]any{"session_id": wire.ID(), "call_id": wire.ID(), "agent_boot_id": p.boot, "backend_epoch": p.backend, "state": "streaming", "reason": "", "created_at": time.Now().UTC(), "uplink_frames": uint64(1), "downlink_frames": uint64(1), "uplink_sequence_gaps": uint64(0), "downlink_sequence_gaps": uint64(0), "actual": ready}
	audio, _ := json.Marshal(map[string]any{"available": true, "implementation": "native", "verification": "unverified", "voice_ready": true, "reason": "", "session": session})
	snap := Snapshot{Boot: p.boot, Backend: p.backend, Observed: time.Now().UTC(), Control: Status{Schema: 1, Boot: p.boot, Backend: p.backend}, Calls: Calls{Boot: p.boot, Backend: p.backend, Calls: []Call{}}, Audio: audio}
	payload, _ := json.Marshal(snap)
	if !s.consume(p, Envelope{Type: "snapshot", Payload: payload}) {
		t.Fatal("LC3 helper ready snapshot rejected")
	}
	var got AudioStatus
	if json.Unmarshal(p.snapshot.Audio, &got) != nil || got.Session == nil || got.Session.Actual == nil {
		t.Fatal("helper ready missing")
	}
	actual := got.Session.Actual
	if actual.Codec != "lc3" || actual.CodecFrameUS != 10000 || actual.CodecFrameBytes != 40 || actual.SampleFormat != "s16le" || actual.Capture.SampleRate != 8000 {
		t.Fatal("codec or hardware PCM metadata lost")
	}
}
