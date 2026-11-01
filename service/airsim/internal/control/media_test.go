package control

import (
	"airsim.local/server/internal/ice"
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSlowOwnershipCheckDoesNotHoldGlobalLock(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	s := New(nil, Config{})
	s.mediaOwner = func(context.Context, mediaSpec) (bool, error) {
		close(entered)
		<-release
		return true, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	module, boot, epoch, call, connection := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.ID()
	pctx, pcancel := context.WithCancel(ctx)
	defer pcancel()
	p := &peer{module: module, boot: boot, backend: epoch, epoch: connection, ctx: pctx, cancel: pcancel, queue: make(chan Envelope, 32), snapshot: &Snapshot{Calls: Calls{Calls: []Call{{ID: call, State: "active", Ownership: "managed"}}}}}
	s.peers[module] = p
	m := &mediaSession{Request: wire.ID(), busy: true, started: true, Offer: "v=0\r\n", answered: make(chan struct{}), answerBy: time.Now().Add(time.Minute), Spec: mediaSpec{ID: wire.ID(), Module: module, Call: call, Boot: boot, Backend: epoch, Connection: connection, Generation: wire.ID(), Expires: time.Now().Add(time.Minute)}}
	s.sessions[m.Request] = m
	done := make(chan struct{})
	go func() { defer close(done); s.performMedia(ctx, m) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("ownership check never entered")
	}
	// A second module can process heartbeat and its bounded command queue while the check is stalled.
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
		s.stopMedia(m, "control_closed")
		s.mu.Unlock()
		close(progress)
	}()
	select {
	case <-progress:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("global lock blocked by ownership check")
	}
	close(release)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("worker stuck")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !m.Closed || m.Reason != "control_closed" || m.Offer != "" || m.busy {
		t.Fatal("stale check revived or retained session description")
	}
	if env := <-p.queue; env.Type != "media_stop" {
		t.Fatal("started session closed without media_stop")
	}
}

func TestMediaTimeoutsCloseSessions(t *testing.T) {
	s := New(nil, Config{})
	s.mediaOwner = func(context.Context, mediaSpec) (bool, error) { return true, nil }
	module, boot, backend, call, connection := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.ID()
	pctx, pcancel := context.WithCancel(context.Background())
	defer pcancel()
	p := &peer{module: module, boot: boot, backend: backend, epoch: connection, ctx: pctx, cancel: pcancel, queue: make(chan Envelope, 32), snapshot: &Snapshot{Calls: Calls{Calls: []Call{{ID: call, State: "active", Ownership: "managed"}}}}}
	s.peers[module] = p
	spec := mediaSpec{ID: wire.ID(), Module: module, Call: call, Boot: boot, Backend: backend, Connection: connection, Generation: wire.ID()}
	offerless := &mediaSession{answered: make(chan struct{}), Spec: spec}
	offerless.Spec.Expires = time.Now().Add(-time.Second)
	unanswered := &mediaSession{answered: make(chan struct{}), started: true, Offer: "v=0\r\n", answerBy: time.Now().Add(-time.Second), Spec: spec}
	unanswered.Spec.Expires = time.Now().Add(time.Minute)
	answered := &mediaSession{answered: make(chan struct{}), started: true, Offer: "v=0\r\n", Answer: "v=0\r\n", answerBy: time.Now().Add(-time.Second), Spec: spec}
	answered.Spec.Expires = time.Now().Add(-time.Second)
	for m, want := range map[*mediaSession]string{offerless: "offer_timeout", unanswered: "answer_timeout", answered: ""} {
		s.performMedia(context.Background(), m)
		if m.Reason != want || m.Closed != (want != "") {
			t.Fatalf("reason %q want %q", m.Reason, want)
		}
	}
	p.snapshot.Calls.Calls[0].State = "disconnected"
	s.performMedia(context.Background(), answered)
	if answered.Reason != "lease_revoked" {
		t.Fatal("ended call kept media")
	}
}

func TestMediaAnswerMatchesStartedSession(t *testing.T) {
	s := New(nil, Config{})
	module, connection := wire.ID(), wire.ID()
	p := &peer{module: module, epoch: connection}
	m := &mediaSession{answered: make(chan struct{}), Spec: mediaSpec{ID: wire.ID(), Module: module, Connection: connection}}
	s.sessions[wire.ID()] = m
	answer := "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"
	s.mediaAnswer(p, m.Spec.ID, answer)
	if m.Answer != "" {
		t.Fatal("answer accepted before media_start")
	}
	m.started = true
	s.mediaAnswer(&peer{module: module, epoch: wire.ID()}, m.Spec.ID, answer)
	if m.Answer != "" {
		t.Fatal("answer accepted from another connection")
	}
	s.mediaAnswer(p, m.Spec.ID, answer)
	select {
	case <-m.answered:
	default:
		t.Fatal("waiter not signalled")
	}
	s.mediaAnswer(p, m.Spec.ID, "v=0\r\nother")
	s.stopMedia(m, "client_closed")
	if m.Answer != "" || m.Reason != "client_closed" {
		t.Fatal("closed session retained description")
	}
	for _, payload := range []string{
		`{"session_id":"` + m.Spec.ID + `","answer":"not sdp"}`,
		`{"session_id":"` + m.Spec.ID + `","answer":"v=0\r\n` + strings.Repeat("a", maxSDP) + `"}`,
		`{"session_id":"` + m.Spec.ID + `"}`,
	} {
		if s.consume(p, Envelope{Type: "media_answer", Payload: json.RawMessage(payload)}) {
			t.Fatalf("invalid answer accepted: %.60s", payload)
		}
	}
}

func TestMediaHistoryCapPreservesClosedIdentity(t *testing.T) {
	s := New(nil, Config{})
	module, client, call, epoch, generation := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.ID()
	var old string
	for i := 0; i < 10000; i++ {
		id := wire.ID()
		s.sessions[id] = &mediaSession{Request: id, Closed: true, answered: make(chan struct{}), Spec: mediaSpec{Module: module, Client: client, Call: call, Connection: epoch, Generation: generation}}
		old = id
	}
	request := func(id string) int {
		body, _ := json.Marshal(map[string]string{"request_id": id, "connection_epoch": epoch, "generation": generation, "codec": "opus"})
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
	for _, codec := range []string{"", "lc3", "opus", "pcm", "OPUS"} {
		payload, _ := json.Marshal(map[string]string{"agent_boot_id": wire.ID(), "backend_epoch": wire.ID(), "agent_version": "test", "media_codec": codec})
		var hello agentHello
		if got := decodeAgentHello(payload, &hello); got != (codec == "" || codec == "lc3" || codec == "opus") {
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
	p := &peer{epoch: epoch, mediaCodec: "lc3", snapshot: &Snapshot{}}
	s.peers[module] = p
	for _, tc := range []struct {
		codec   string
		include bool
		status  int
	}{
		{"", false, 400}, {"lc3", true, 400}, {"opus", true, 409},
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
		if tc.codec == "opus" && !bytes.Contains(w.Body.Bytes(), []byte(`"media_unavailable"`)) {
			t.Fatal("legacy agent error mismatch")
		}
	}
	if s.peers[module] != p {
		t.Fatal("legacy agent control disconnected")
	}
}

func TestMediaResultIssuesClientRelayCredential(t *testing.T) {
	s := New(nil, Config{TURNSecret: "secret", TURNHost: "203.0.113.7"})
	created := time.Now().UTC()
	m := &mediaSession{Spec: mediaSpec{ID: wire.ID(), Created: created, Expires: created.Add(offerWindow)}}
	w := httptest.NewRecorder()
	s.mediaResult(w, 201, m)
	var result struct {
		ID      string       `json:"session_id"`
		Expires time.Time    `json:"expires_at"`
		Servers []ice.Server `json:"ice_servers"`
	}
	if wire.Decode(w.Body.Bytes(), &result) != nil || result.ID != m.Spec.ID || !result.Expires.Equal(m.Spec.Expires) || len(result.Servers) != 1 {
		t.Fatal("media result shape")
	}
	server := result.Servers[0]
	if !strings.HasSuffix(server.Username, ":"+m.Spec.ID+":client") || !ice.Valid(server.Username, created) || server.Credential != ice.Password("secret", server.Username) || server.URLs[0] != "turn:203.0.113.7:3478?transport=udp" {
		t.Fatalf("credential %+v", server)
	}
	again := httptest.NewRecorder()
	s.mediaResult(again, 200, m)
	if !bytes.Equal(bytes.TrimSpace(w.Body.Bytes()), bytes.TrimSpace(again.Body.Bytes())) {
		t.Fatal("idempotent result changed")
	}
}

func TestOpusHelperReadySnapshot(t *testing.T) {
	s := New(nil, Config{})
	p := &peer{ctx: context.Background(), boot: wire.ID(), backend: wire.ID(), queried: true}
	ready := json.RawMessage(`{"type":"ready","codec":"opus","codec_frame_us":20000,"sample_rate":16000,"channels":1,"sample_format":"s16le","frame_samples":320,"capture":{"sample_rate":8000,"period_size":320,"period_count":2,"buffer_frames":640},"playback":{"sample_rate":8000,"period_size":320,"period_count":2,"buffer_frames":640}}`)
	session := map[string]any{"session_id": wire.ID(), "call_id": wire.ID(), "agent_boot_id": p.boot, "backend_epoch": p.backend, "state": "streaming", "reason": "", "created_at": time.Now().UTC(), "uplink_frames": uint64(1), "downlink_frames": uint64(1), "uplink_sequence_gaps": uint64(0), "downlink_sequence_gaps": uint64(0), "actual": ready}
	audio, _ := json.Marshal(map[string]any{"available": true, "implementation": "native", "verification": "unverified", "voice_ready": true, "reason": "", "session": session})
	snap := Snapshot{Boot: p.boot, Backend: p.backend, Observed: time.Now().UTC(), Control: Status{Schema: 1, Boot: p.boot, Backend: p.backend}, Calls: Calls{Boot: p.boot, Backend: p.backend, Calls: []Call{}}, Audio: audio}
	payload, _ := json.Marshal(snap)
	if !s.consume(p, Envelope{Type: "snapshot", Payload: payload}) {
		t.Fatal("Opus helper ready snapshot rejected")
	}
	var got AudioStatus
	if json.Unmarshal(p.snapshot.Audio, &got) != nil || got.Session == nil || got.Session.Actual == nil {
		t.Fatal("helper ready missing")
	}
	actual := got.Session.Actual
	if actual.Codec != "opus" || actual.CodecFrameUS != 20000 || actual.SampleFormat != "s16le" || actual.Capture.SampleRate != 8000 {
		t.Fatal("codec or hardware PCM metadata lost")
	}
}
