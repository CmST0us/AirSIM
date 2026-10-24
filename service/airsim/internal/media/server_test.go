package media

import (
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"github.com/coder/websocket"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFrameRejection(t *testing.T) {
	id := wire.ID()
	frame := make([]byte, 360)
	copy(frame, "ASMP")
	frame[4] = 1
	frame[5] = 1
	binary.LittleEndian.PutUint16(frame[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(frame[8:24], sid)
	binary.LittleEndian.PutUint64(frame[24:32], 3)
	binary.LittleEndian.PutUint32(frame[32:36], 320)
	if seq, ok := ValidateFrame(frame, id, 1, 1); !ok || seq != 3 {
		t.Fatal("legal gap rejected")
	}
	for _, b := range [][]byte{frame[:359], append(append([]byte{}, frame...), 0)} {
		if _, ok := ValidateFrame(b, id, 1, 0); ok {
			t.Fatal("invalid size")
		}
	}
	if _, ok := ValidateFrame(frame, id, 1, 3); ok {
		t.Fatal("replay accepted")
	}
	if _, ok := ValidateFrame(frame, wire.ID(), 1, 0); ok {
		t.Fatal("wrong session")
	}
	if _, ok := ValidateFrame(frame, id, 2, 0); ok {
		t.Fatal("wrong direction")
	}
}
func TestTicketLeaseAndLimits(t *testing.T) {
	token := wire.Token()
	s := New(token)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.Run(ctx)
	h := httptest.NewServer(s.Handler())
	defer h.Close()
	call := func(method, path string, v any, auth bool) int {
		b, _ := json.Marshal(v)
		r, _ := http.NewRequest(method, h.URL+path, bytes.NewReader(b))
		r.Header.Set("Content-Type", "application/json")
		if auth {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		res, e := http.DefaultClient.Do(r)
		if e != nil {
			t.Fatal("internal_request_failed")
		}
		res.Body.Close()
		return res.StatusCode
	}
	ticket := wire.Token()
	spec := Spec{ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(ticket), ClientHash: wire.Hash(wire.Token()), Expires: time.Now().UTC().Add(25 * time.Second)}
	if call("POST", "/internal/sessions", spec, false) != 401 {
		t.Fatal("missing internal auth")
	}
	if call("POST", "/internal/sessions", spec, true) != 201 {
		t.Fatal("session create")
	}
	if call("POST", "/internal/sessions", spec, true) != 409 {
		t.Fatal("duplicate session")
	}
	dial := func() *websocket.Conn {
		c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/v2/media", &websocket.DialOptions{Subprotocols: []string{"airsim.media.v2"}})
		if e != nil {
			t.Fatal("ws failed")
		}
		b, _ := json.Marshal(map[string]string{"session_id": spec.ID, "role": "agent", "ticket": ticket})
		if c.Write(ctx, websocket.MessageText, b) != nil {
			t.Fatal("ws auth write")
		}
		return c
	}
	one := dial()
	defer one.CloseNow()
	readctx, cc := context.WithTimeout(ctx, time.Second)
	_, _, e := one.Read(readctx)
	cc()
	if e != nil {
		t.Fatal("first ticket rejected")
	}
	two := dial()
	defer two.CloseNow()
	readctx, cc = context.WithTimeout(ctx, time.Second)
	_, _, e = two.Read(readctx)
	cc()
	if e == nil {
		t.Fatal("ticket replay accepted")
	}
	if call("POST", "/internal/sessions/"+spec.ID+"/renew", map[string]string{"connection_epoch": wire.ID(), "generation": spec.Generation}, true) != 409 {
		t.Fatal("wrong epoch renew")
	}
	readctx, cc = context.WithTimeout(ctx, 5*time.Second)
	_, _, e = one.Read(readctx)
	cc()
	if e == nil {
		t.Fatal("lease did not close peer")
	}
	s.mu.Lock()
	count := len(s.sessions)
	s.mu.Unlock()
	if count != 0 {
		t.Fatal("session not released")
	}
	if call("DELETE", "/internal/sessions/"+spec.ID, nil, true) != 204 {
		t.Fatal("delete not idempotent")
	}
	for i := 0; i < 32; i++ {
		sp := spec
		sp.ID = wire.ID()
		sp.Module = wire.ID()
		sp.Client = wire.ID()
		sp.Expires = time.Now().UTC().Add(25 * time.Second)
		if call("POST", "/internal/sessions", sp, true) != 201 {
			t.Fatal("capacity unexpectedly low")
		}
	}
	spec.ID = wire.ID()
	spec.Module = wire.ID()
	spec.Client = wire.ID()
	spec.Expires = time.Now().UTC().Add(25 * time.Second)
	if call("POST", "/internal/sessions", spec, true) != 429 {
		t.Fatal("global limit missing")
	}
}
func TestSlowConsumerQueueBound(t *testing.T) {
	token := wire.Token()
	s := New(token)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.Run(ctx)
	h := httptest.NewServer(s.Handler())
	defer h.Close()
	a, c := wire.Token(), wire.Token()
	spec := Spec{ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(a), ClientHash: wire.Hash(c), Expires: time.Now().UTC().Add(25 * time.Second)}
	b, _ := json.Marshal(spec)
	r, _ := http.NewRequest("POST", h.URL+"/internal/sessions", bytes.NewReader(b))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	res, e := http.DefaultClient.Do(r)
	if e != nil {
		t.Fatal("session create failed")
	}
	res.Body.Close()
	if res.StatusCode != 201 {
		t.Fatal("session create rejected")
	}
	connect := func(role, ticket string) *websocket.Conn {
		conn, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/v2/media", &websocket.DialOptions{Subprotocols: []string{"airsim.media.v2"}})
		if e != nil {
			t.Fatal("dial failed")
		}
		data, _ := json.Marshal(map[string]string{"session_id": spec.ID, "role": role, "ticket": ticket})
		if conn.Write(ctx, websocket.MessageText, data) != nil {
			t.Fatal("auth write failed")
		}
		if _, _, e = conn.Read(ctx); e != nil {
			t.Fatal("waiting failed")
		}
		return conn
	}
	agent := connect("agent", a)
	defer agent.CloseNow()
	client := connect("client", c)
	defer client.CloseNow()
	if _, _, e = agent.Read(ctx); e != nil {
		t.Fatal("paired failed")
	}
	if _, _, e = client.Read(ctx); e != nil {
		t.Fatal("paired failed")
	}
	s.mu.Lock()
	session := s.sessions[spec.ID]
	s.mu.Unlock()
	frame := make([]byte, 360)
	copy(frame, "ASMP")
	frame[4] = 1
	frame[5] = 1
	binary.LittleEndian.PutUint16(frame[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(spec.ID, "-", ""))
	copy(frame[8:24], sid)
	binary.LittleEndian.PutUint32(frame[32:36], 320)
	// Agent deliberately stops reading. The producer is bounded by its own test deadline.
	producer, stop := context.WithTimeout(ctx, 3*time.Second)
	defer stop()
	for seq := uint64(1); seq <= 100000; seq++ {
		binary.LittleEndian.PutUint64(frame[24:32], seq)
		if client.Write(producer, websocket.MessageBinary, frame) != nil {
			break
		}
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		closed := session.stats.State == "closed"
		bounded := len(session.queues[0]) <= 5 && len(session.queues[1]) <= 5
		s.mu.Unlock()
		if !bounded {
			t.Fatal("unbounded queue")
		}
		if closed {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("slow peer not reclaimed")
}
