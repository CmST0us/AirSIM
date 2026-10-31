package media

import (
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/coder/websocket"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFrameRejection(t *testing.T) {
	id := wire.ID()
	frame := make([]byte, 120)
	copy(frame, "ASMP")
	frame[4] = 2
	frame[5] = 1
	binary.LittleEndian.PutUint16(frame[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(frame[8:24], sid)
	binary.LittleEndian.PutUint64(frame[24:32], 3)
	binary.LittleEndian.PutUint32(frame[32:36], 80)
	if seq, ok := ValidateFrame(frame, id, 1, 1); !ok || seq != 3 {
		t.Fatal("legal gap rejected")
	}
	for _, b := range [][]byte{frame[:119], append(append([]byte{}, frame...), 0)} {
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
	spec := Spec{Format: Format, ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(ticket), ClientHash: wire.Hash(wire.Token()), Expires: time.Now().UTC().Add(25 * time.Second)}
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
	spec := Spec{Format: Format, ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(a), ClientHash: wire.Hash(c), Expires: time.Now().UTC().Add(25 * time.Second)}
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
	frame := make([]byte, 120)
	copy(frame, "ASMP")
	frame[4] = 2
	frame[5] = 1
	binary.LittleEndian.PutUint16(frame[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(spec.ID, "-", ""))
	copy(frame[8:24], sid)
	binary.LittleEndian.PutUint32(frame[32:36], 80)
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

func lc3Frame(id string, direction byte, sequence uint64, erasure bool) []byte {
	b := make([]byte, PacketBytes)
	copy(b, "ASMP")
	b[4] = 2
	b[5] = direction
	binary.LittleEndian.PutUint16(b[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(b[8:24], sid)
	binary.LittleEndian.PutUint64(b[24:32], sequence)
	binary.LittleEndian.PutUint32(b[32:36], 80)
	if erasure {
		binary.LittleEndian.PutUint32(b[36:40], 1)
	} else {
		for i := 40; i < len(b); i++ {
			b[i] = byte(i)
		}
	}
	return b
}

func TestLC3FrameFlagsAndVersion(t *testing.T) {
	id := wire.ID()
	for _, erased := range []bool{false, true} {
		if _, ok := ValidateFrame(lc3Frame(id, 1, 1, erased), id, 1, 0); !ok {
			t.Fatal("valid LC3 packet rejected")
		}
	}
	for _, change := range []func([]byte){
		func(b []byte) { b[4] = 1 },
		func(b []byte) { binary.LittleEndian.PutUint32(b[36:40], 2) },
		func(b []byte) { binary.LittleEndian.PutUint32(b[36:40], 1) },
		func(b []byte) { binary.LittleEndian.PutUint32(b[32:36], 320) },
		func(b []byte) { binary.LittleEndian.PutUint16(b[6:8], 39) },
	} {
		b := lc3Frame(id, 1, 1, false)
		change(b)
		if _, ok := ValidateFrame(b, id, 1, 0); ok {
			t.Fatal("invalid LC3 packet accepted")
		}
	}
}

func TestLC3RelayFormatAndDuplex(t *testing.T) {
	token := wire.Token()
	s := New(token)
	h := httptest.NewServer(s.Handler())
	defer h.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a, c := wire.Token(), wire.Token()
	spec := Spec{Format: Format, ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(a), ClientHash: wire.Hash(c), Expires: time.Now().UTC().Add(25 * time.Second)}
	post := func(value any) int {
		data, _ := json.Marshal(value)
		r := httptest.NewRequest("POST", "/internal/sessions", bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w.Code
	}
	raw, _ := json.Marshal(spec)
	var fields map[string]any
	json.Unmarshal(raw, &fields)
	delete(fields, "format")
	if post(fields) != 400 {
		t.Fatal("missing format accepted")
	}
	for _, field := range []string{"codec", "sample_rate", "channels", "sample_format", "frame_samples", "codec_frame_us", "codec_frame_bytes"} {
		json.Unmarshal(raw, &fields)
		format := fields["format"].(map[string]any)
		delete(format, field)
		if post(fields) != 400 {
			t.Fatalf("missing format field %s accepted", field)
		}
	}
	json.Unmarshal(raw, &fields)
	fields["format"].(map[string]any)["extra"] = 1
	if post(fields) != 400 {
		t.Fatal("unknown format field accepted")
	}
	for _, change := range []func(*AudioFormat){
		func(f *AudioFormat) { f.Codec = "pcm" }, func(f *AudioFormat) { f.SampleRate = 8000 }, func(f *AudioFormat) { f.Channels = 2 }, func(f *AudioFormat) { f.SampleFormat = "lc3" }, func(f *AudioFormat) { f.FrameSamples = 80 }, func(f *AudioFormat) { f.CodecFrameUS = 7500 }, func(f *AudioFormat) { f.CodecFrameBytes = 30 },
	} {
		bad := spec
		change(&bad.Format)
		if post(bad) != 400 {
			t.Fatal("unsupported format accepted")
		}
	}
	if post(spec) != 201 {
		t.Fatal("LC3 session rejected")
	}
	connect := func(role, ticket string) *websocket.Conn {
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/v2/media", &websocket.DialOptions{Subprotocols: []string{"airsim.media.v2"}})
		if err != nil {
			t.Fatal(err)
		}
		payload, _ := json.Marshal(map[string]string{"session_id": spec.ID, "role": role, "ticket": ticket})
		if err = conn.Write(ctx, websocket.MessageText, payload); err != nil {
			t.Fatal(err)
		}
		if _, _, err = conn.Read(ctx); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	agent := connect("agent", a)
	defer agent.CloseNow()
	client := connect("client", c)
	defer client.CloseNow()
	for _, conn := range []*websocket.Conn{agent, client} {
		typ, data, err := conn.Read(ctx)
		var paired struct {
			Type    string      `json:"type"`
			Session string      `json:"session_id"`
			Format  AudioFormat `json:"format"`
		}
		if err != nil || typ != websocket.MessageText || wire.Decode(data, &paired) != nil || paired.Type != "paired" || paired.Format != spec.Format {
			t.Fatal("paired format mismatch")
		}
	}
	for _, erased := range []bool{false, true} {
		seq := uint64(1)
		if erased {
			seq = 3
		}
		for _, way := range []struct {
			from, to  *websocket.Conn
			direction byte
		}{{client, agent, 1}, {agent, client, 2}} {
			want := lc3Frame(spec.ID, way.direction, seq, erased)
			if err := way.from.Write(ctx, websocket.MessageBinary, want); err != nil {
				t.Fatal(err)
			}
			typ, got, err := way.to.Read(ctx)
			if err != nil || typ != websocket.MessageBinary || !bytes.Equal(got, want) {
				t.Fatal("relay changed LC3 or erasure packet")
			}
		}
	}
	s.mu.Lock()
	v := s.sessions[spec.ID]
	gaps := v.stats.Gaps
	s.mu.Unlock()
	if gaps != [2]uint64{1, 1} {
		t.Fatalf("gaps %v", gaps)
	}
	bad := lc3Frame(spec.ID, 1, 4, false)
	bad[4] = 1
	if err := client.Write(ctx, websocket.MessageBinary, bad); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []*websocket.Conn{agent, client} {
		if _, _, err := conn.Read(ctx); err == nil {
			t.Fatal("invalid packet did not close both peers")
		}
	}
}

func TestPairDeadlineAndActiveFrameTimeout(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name                                          string
		firstAge, ticketRemaining, leaseAge, frameAge time.Duration
		paired                                        bool
		reason                                        string
	}{
		{"WAN upgrade beyond five seconds", 6 * time.Second, 24 * time.Second, 0, 0, false, ""},
		{"before pair boundary", 19 * time.Second, 11 * time.Second, 0, 0, false, ""},
		{"pair boundary", 20 * time.Second, 10 * time.Second, 0, 0, false, "pair_timeout"},
		{"earlier absolute ticket boundary", 6 * time.Second, 0, 0, 0, false, "ticket_expired"},
		{"lease still expires", 6 * time.Second, 24 * time.Second, 4 * time.Second, 0, false, "lease_expired"},
		{"paired ignores setup deadline", 21 * time.Second, 9 * time.Second, 0, 0, true, ""},
		{"paired frames retain two second timeout", 6 * time.Second, 24 * time.Second, 0, 2100 * time.Millisecond, true, "frame_timeout"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := New(wire.Token())
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			id := wire.ID()
			state := "waiting"
			if tc.paired {
				state = "paired"
			}
			v := &session{spec: Spec{ID: id, Expires: now.Add(tc.ticketRemaining)}, stats: Stats{State: state}, created: now.Add(-tc.firstAge), first: now.Add(-tc.firstAge), renewed: now.Add(-tc.leaseAge), last: [2]time.Time{now.Add(-tc.frameAge), now}, ctx: ctx, cancel: cancel}
			s.sessions[id] = v
			s.expire(now)
			if v.stats.Reason != tc.reason {
				t.Fatalf("reason %q want %q", v.stats.Reason, tc.reason)
			}
			if tc.reason == "" {
				if s.sessions[id] != v || ctx.Err() != nil {
					t.Fatal("live session closed early")
				}
			} else if s.sessions[id] != nil || ctx.Err() == nil {
				t.Fatal("expired session not cancelled and removed")
			}
		})
	}
}

func TestCloseDiagnosticIsOnceAndBounded(t *testing.T) {
	var output bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&output)
	defer log.SetOutput(previous)
	for _, reason := range []string{"frame_timeout", "lease_expired", "write_timeout", "peer_closed", "revoked", "untrusted-secret-value"} {
		output.Reset()
		s := New("private-ticket")
		ctx, cancel := context.WithCancel(context.Background())
		v := &session{spec: Spec{ID: "private-session"}, ctx: ctx, cancel: cancel, renewed: time.Now(), pairedAt: time.Now(), stats: Stats{State: "paired", Frames: [2]uint64{135, 142}}}
		s.sessions[v.spec.ID] = v
		s.close(v, reason)
		s.close(v, "shutdown")
		line := output.String()
		expected := reason
		if reason == "untrusted-secret-value" {
			expected = "unknown"
		}
		if strings.Count(line, "media_closed") != 1 || !strings.Contains(line, "reason="+expected+" ") || !strings.Contains(line, "agent_frames=135 client_frames=142") || strings.Contains(line, "private-") || strings.Contains(line, "untrusted-secret-value") {
			t.Fatalf("unexpected bounded close diagnostic: %q", line)
		}
		if len(s.sessions) != 0 {
			t.Fatal("closed session retained")
		}
	}
}

func TestLC3RelaySustainedDuplex(t *testing.T) {
	s := New(wire.Token())
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	go s.Run(ctx)
	h := httptest.NewServer(s.Handler())
	defer h.Close()
	a, c := wire.Token(), wire.Token()
	spec := Spec{Format: Format, ID: wire.ID(), Module: wire.ID(), Call: wire.ID(), Boot: wire.ID(), Backend: wire.ID(), Connection: wire.ID(), Client: wire.ID(), Generation: wire.ID(), AgentHash: wire.Hash(a), ClientHash: wire.Hash(c), Expires: time.Now().UTC().Add(25 * time.Second)}
	request := func(path string, value any) int {
		data, _ := json.Marshal(value)
		r := httptest.NewRequest("POST", path, bytes.NewReader(data))
		r.Header.Set("Authorization", "Bearer "+s.token)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w.Code
	}
	if request("/internal/sessions", spec) != 201 {
		t.Fatal("create failed")
	}
	connect := func(role, ticket string) *websocket.Conn {
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/v2/media", &websocket.DialOptions{Subprotocols: []string{"airsim.media.v2"}})
		if err != nil {
			t.Fatal(err)
		}
		payload, _ := json.Marshal(map[string]string{"session_id": spec.ID, "role": role, "ticket": ticket})
		if err = conn.Write(ctx, websocket.MessageText, payload); err != nil {
			t.Fatal(err)
		}
		if _, _, err = conn.Read(ctx); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	agent := connect("agent", a)
	defer agent.CloseNow()
	client := connect("client", c)
	defer client.CloseNow()
	for _, conn := range []*websocket.Conn{agent, client} {
		if _, _, err := conn.Read(ctx); err != nil {
			t.Fatal(err)
		}
	}
	errors := make(chan error, 5)
	renewCtx, stopRenew := context.WithCancel(ctx)
	defer stopRenew()
	go func() {
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		for {
			select {
			case <-renewCtx.Done():
				return
			case <-tick.C:
				if request("/internal/sessions/"+spec.ID+"/renew", map[string]string{"connection_epoch": spec.Connection, "generation": spec.Generation}) != 204 {
					errors <- fmt.Errorf("renew failed")
					return
				}
			}
		}
	}()
	for _, way := range []struct {
		from, to  *websocket.Conn
		direction byte
	}{{client, agent, 1}, {agent, client, 2}} {
		way := way
		go func() {
			tick := time.NewTicker(20 * time.Millisecond)
			defer tick.Stop()
			for seq := uint64(1); seq <= 400; seq++ {
				select {
				case <-ctx.Done():
					errors <- ctx.Err()
					return
				case <-tick.C:
				}
				if err := way.from.Write(ctx, websocket.MessageBinary, lc3Frame(spec.ID, way.direction, seq, seq%7 == 0)); err != nil {
					errors <- err
					return
				}
			}
			errors <- nil
		}()
		go func() {
			for seq := uint64(1); seq <= 400; seq++ {
				readCtx, cc := context.WithTimeout(ctx, 2*time.Second)
				typ, b, err := way.to.Read(readCtx)
				cc()
				if err != nil {
					errors <- err
					return
				}
				if typ != websocket.MessageBinary || !bytes.Equal(b, lc3Frame(spec.ID, way.direction, seq, seq%7 == 0)) {
					errors <- fmt.Errorf("direction %d sequence %d mismatch", way.direction, seq)
					return
				}
			}
			errors <- nil
		}()
	}
	for i := 0; i < 4; i++ {
		if err := <-errors; err != nil {
			t.Fatal(err)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.sessions[spec.ID]
	if v == nil || v.stats.State != "paired" || v.stats.Frames != [2]uint64{400, 400} || v.stats.Dropped != [2]uint64{} {
		t.Fatal("sustained relay lost frames or closed")
	}
}
