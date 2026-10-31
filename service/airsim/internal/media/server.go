// Package media implements the R4 ephemeral media relay. It has no database access.
package media

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"airsim.local/server/internal/wire"
	"github.com/coder/websocket"
)

type AudioFormat struct {
	Codec           string `json:"codec"`
	SampleRate      int    `json:"sample_rate"`
	Channels        int    `json:"channels"`
	SampleFormat    string `json:"sample_format"`
	FrameSamples    int    `json:"frame_samples"`
	CodecFrameUS    int    `json:"codec_frame_us"`
	CodecFrameBytes int    `json:"codec_frame_bytes"`
}

const PacketBytes = 120

type Spec struct {
	Format     AudioFormat `json:"format"`
	ID         string      `json:"session_id"`
	Module     string      `json:"module_id"`
	Call       string      `json:"call_id"`
	Boot       string      `json:"agent_boot_id"`
	Backend    string      `json:"backend_epoch"`
	Connection string      `json:"connection_epoch"`
	Client     string      `json:"client_installation_id"`
	Generation string      `json:"generation"`
	AgentHash  string      `json:"agent_ticket_hash"`
	ClientHash string      `json:"client_ticket_hash"`
	Expires    time.Time   `json:"expires_at"`
}
type Stats struct {
	State   string    `json:"state"`
	Reason  string    `json:"reason"`
	Frames  [2]uint64 `json:"frames"`
	Gaps    [2]uint64 `json:"sequence_gaps"`
	Dropped [2]uint64 `json:"dropped"`
}
type session struct {
	spec                    Spec
	stats                   Stats
	pairedAt                time.Time
	renewed, created, first time.Time
	peers                   [2]*websocket.Conn
	used                    [2]bool
	last                    [2]time.Time
	sequence                [2]uint64
	queues                  [2]chan []byte
	paired                  chan struct{}
	ctx                     context.Context
	cancel                  context.CancelFunc
}
type Server struct {
	mu         sync.Mutex
	sessions   map[string]*session
	token      string
	handshakes chan struct{}
}

var Format = AudioFormat{Codec: "lc3", SampleRate: 16000, Channels: 1, SampleFormat: "s16le", FrameSamples: 320, CodecFrameUS: 10000, CodecFrameBytes: 40}

func New(token string) *Server {
	return &Server{sessions: map[string]*session{}, token: token, handshakes: make(chan struct{}, 32)}
}
func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { wire.JSON(w, 200, map[string]bool{"alive": true}) })
	m.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) { wire.JSON(w, 200, map[string]bool{"ready": true}) })
	m.HandleFunc("/internal/", s.internal)
	m.HandleFunc("GET /v2/media", s.socket)
	return m
}
func (s *Server) Run(ctx context.Context) {
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			for _, v := range s.sessions {
				s.close(v, "shutdown")
			}
			s.mu.Unlock()
			return
		case now := <-t.C:
			s.expire(now)
		}
	}
}

func (s *Server) expire(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, v := range s.sessions {
		reason := ""
		switch {
		case now.Sub(v.renewed) > 3*time.Second:
			reason = "lease_expired"
		case now.Sub(v.created) >= 30*time.Minute:
			reason = "duration_expired"
		case v.stats.State != "paired" && !now.Before(v.spec.Expires):
			reason = "ticket_expired"
		case !v.first.IsZero() && v.stats.State != "paired" && now.Sub(v.first) >= 20*time.Second:
			reason = "pair_timeout"
		case v.stats.State == "paired" && (now.Sub(v.last[0]) > 2*time.Second || now.Sub(v.last[1]) > 2*time.Second):
			reason = "frame_timeout"
		}
		if reason != "" {
			s.close(v, reason)
		}
	}
}

// Called with mu. Closing sockets asynchronously avoids blocking the lease sweeper.
func (s *Server) close(v *session, reason string) {
	if v.stats.State == "closed" {
		return
	}
	switch reason {
	case "shutdown", "lease_expired", "duration_expired", "ticket_expired", "pair_timeout", "frame_timeout", "revoked", "write_failed", "write_timeout", "peer_closed", "invalid_frame":
	default:
		reason = "unknown"
	}
	now := time.Now()
	age := func(at time.Time) int64 {
		if at.IsZero() {
			return -1
		}
		return now.Sub(at).Milliseconds()
	}
	log.Printf("media_closed reason=%s paired_ms=%d lease_age_ms=%d agent_frame_age_ms=%d client_frame_age_ms=%d agent_frames=%d client_frames=%d", reason, age(v.pairedAt), age(v.renewed), age(v.last[0]), age(v.last[1]), v.stats.Frames[0], v.stats.Frames[1])
	v.stats.State = "closed"
	v.stats.Reason = reason
	v.cancel()
	for _, c := range v.peers {
		if c != nil {
			c.CloseNow()
		}
	}
	delete(s.sessions, v.spec.ID)
}
func (s *Server) internal(w http.ResponseWriter, r *http.Request) {
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.token)) != 1 {
		wire.Error(w, 401, "unauthorized")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := strings.TrimPrefix(r.URL.Path, "/internal/sessions")
	if p == "" && r.Method == "POST" {
		var spec Spec
		if wire.Body(w, r, &spec, 4096, "session_id", "module_id", "call_id", "agent_boot_id", "backend_epoch", "connection_epoch", "client_installation_id", "generation", "agent_ticket_hash", "client_ticket_hash", "expires_at", "format") != nil || spec.Format != Format {
			wire.Error(w, 400, "invalid_parameters")
			return
		}
		for _, id := range []string{spec.ID, spec.Module, spec.Call, spec.Boot, spec.Backend, spec.Connection, spec.Client, spec.Generation} {
			if !wire.UUID.MatchString(id) {
				wire.Error(w, 400, "invalid_parameters")
				return
			}
		}
		if !wire.Hex.MatchString(spec.AgentHash) || !wire.Hex.MatchString(spec.ClientHash) || !spec.Expires.After(time.Now()) || time.Until(spec.Expires) > 30*time.Second {
			wire.Error(w, 400, "invalid_parameters")
			return
		}
		if len(s.sessions) >= 32 {
			wire.Error(w, 429, "capacity_exceeded")
			return
		}
		for _, v := range s.sessions {
			if v.spec.ID == spec.ID || v.spec.Module == spec.Module || v.spec.Client == spec.Client {
				wire.Error(w, 409, "session_conflict")
				return
			}
		}
		ctx, cancel := context.WithCancel(context.Background())
		now := time.Now()
		s.sessions[spec.ID] = &session{spec: spec, stats: Stats{State: "waiting"}, created: now, renewed: now, queues: [2]chan []byte{make(chan []byte, 5), make(chan []byte, 5)}, paired: make(chan struct{}), ctx: ctx, cancel: cancel}
		wire.JSON(w, 201, map[string]string{"session_id": spec.ID})
		return
	}
	parts := strings.Split(strings.TrimPrefix(p, "/"), "/")
	if len(parts) == 0 || !wire.UUID.MatchString(parts[0]) {
		wire.Error(w, 404, "not_found")
		return
	}
	v := s.sessions[parts[0]]
	if len(parts) == 1 && r.Method == "DELETE" {
		if v != nil {
			s.close(v, "revoked")
		}
		w.WriteHeader(204)
		return
	}
	if v == nil {
		wire.Error(w, 404, "not_found")
		return
	}
	if len(parts) == 1 && r.Method == "GET" {
		wire.JSON(w, 200, v.stats)
		return
	}
	if len(parts) == 2 && parts[1] == "renew" && r.Method == "POST" {
		var b struct {
			Connection string `json:"connection_epoch"`
			Generation string `json:"generation"`
		}
		if wire.Body(w, r, &b, 4096, "connection_epoch", "generation") != nil {
			wire.Error(w, 400, "invalid_parameters")
			return
		}
		if b.Connection != v.spec.Connection || b.Generation != v.spec.Generation {
			wire.Error(w, 409, "session_conflict")
			return
		}
		v.renewed = time.Now()
		w.WriteHeader(204)
		return
	}
	wire.Error(w, 404, "not_found")
}
func (s *Server) socket(w http.ResponseWriter, r *http.Request) {
	select {
	case s.handshakes <- struct{}{}:
	default:
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	held := true
	defer func() {
		if held {
			<-s.handshakes
		}
	}()
	c, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		return
	}
	defer c.CloseNow()
	if c.Subprotocol() != "airsim.media.v2" {
		return
	}
	c.SetReadLimit(2048)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	typ, b, e := c.Read(ctx)
	cancel()
	var auth struct {
		ID     string `json:"session_id"`
		Role   string `json:"role"`
		Ticket string `json:"ticket"`
	}
	if e != nil || typ != websocket.MessageText || wire.Decode(b, &auth, "session_id", "role", "ticket") != nil {
		return
	}
	role := 0
	if auth.Role == "client" {
		role = 1
	} else if auth.Role != "agent" {
		return
	}
	s.mu.Lock()
	v := s.sessions[auth.ID]
	if v == nil || v.used[role] || time.Now().After(v.spec.Expires) {
		s.mu.Unlock()
		return
	}
	hash := v.spec.AgentHash
	if role == 1 {
		hash = v.spec.ClientHash
	}
	if !wire.Hex.MatchString(auth.Ticket) || subtle.ConstantTimeCompare([]byte(wire.Hash(auth.Ticket)), []byte(hash)) != 1 {
		s.mu.Unlock()
		return
	}
	v.used[role] = true
	v.peers[role] = c
	if v.first.IsZero() {
		v.first = time.Now()
	}
	s.mu.Unlock()
	<-s.handshakes
	held = false
	if write(c, v.ctx, map[string]any{"type": "waiting", "session_id": auth.ID}, 3*time.Second) != nil {
		s.mu.Lock()
		s.close(v, "write_failed")
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	if v.peers[0] != nil && v.peers[1] != nil && v.stats.State == "waiting" {
		v.stats.State = "paired"
		v.pairedAt = time.Now()
		v.last = [2]time.Time{time.Now(), time.Now()}
		close(v.paired)
	}
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.close(v, "peer_closed"); s.mu.Unlock() }()
	select {
	case <-v.ctx.Done():
		return
	case <-v.paired:
	}
	if write(c, v.ctx, map[string]any{"type": "paired", "session_id": auth.ID, "format": v.spec.Format}, time.Second) != nil {
		return
	}
	c.SetReadLimit(PacketBytes)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-v.ctx.Done():
				return
			case frame := <-v.queues[role]:
				ctx, cancel := context.WithTimeout(v.ctx, 100*time.Millisecond)
				e := c.Write(ctx, websocket.MessageBinary, frame)
				cancel()
				if e != nil {
					s.mu.Lock()
					s.close(v, "write_timeout")
					s.mu.Unlock()
					return
				}
			}
		}
	}()
	defer func() { s.mu.Lock(); s.close(v, "peer_closed"); s.mu.Unlock(); <-done }()
	for {
		typ, b, e = c.Read(v.ctx)
		if e != nil {
			return
		}
		s.mu.Lock()
		direction := byte(2)
		if role == 1 {
			direction = 1
		}
		seq, valid := ValidateFrame(b, auth.ID, direction, v.sequence[role])
		if typ != websocket.MessageBinary || !valid {
			s.close(v, "invalid_frame")
			s.mu.Unlock()
			return
		}
		v.stats.Gaps[role] += seq - v.sequence[role] - 1
		v.sequence[role] = seq
		v.stats.Frames[role]++
		v.last[role] = time.Now()
		q := v.queues[1-role]
		select {
		case q <- b:
		default:
			select {
			case <-q:
				v.stats.Dropped[role]++
			default:
			}
			select {
			case q <- b:
			default:
				v.stats.Dropped[role]++
			}
		}
		s.mu.Unlock()
	}
}
func write(c *websocket.Conn, ctx context.Context, value any, d time.Duration) error {
	b, _ := json.Marshal(value)
	ctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()
	return c.Write(ctx, websocket.MessageText, b)
}
func ValidateFrame(b []byte, id string, direction byte, last uint64) (uint64, bool) {
	if len(b) != PacketBytes || string(b[:4]) != "ASMP" || b[4] != 2 || b[5] != direction || binary.LittleEndian.Uint16(b[6:8]) != 40 || binary.LittleEndian.Uint32(b[32:36]) != 80 {
		return 0, false
	}
	flags := binary.LittleEndian.Uint32(b[36:40])
	if flags > 1 || (flags == 1 && !bytes.Equal(b[40:], make([]byte, 80))) {
		return 0, false
	}
	sid, e := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	if e != nil || string(sid) != string(b[8:24]) {
		return 0, false
	}
	seq := binary.LittleEndian.Uint64(b[24:32])
	return seq, seq > last
}
