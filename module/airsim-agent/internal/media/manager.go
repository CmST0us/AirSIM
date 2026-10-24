package media

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/strictjson"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"net"
	"sync"
	"time"
)

type Qualifier interface {
	AudioQualification(context.Context) (control.AudioQualification, error)
	AudioEvents() <-chan struct{}
}
type Request struct {
	RequestID string `json:"request_id"`
	Boot      string `json:"agent_boot_id"`
	Epoch     string `json:"backend_epoch"`
	CallID    string `json:"call_id"`
}

func ParseRequest(b []byte) (Request, error) {
	var r Request
	if len(b) > 1024 || strictjson.Decode(b, []string{"request_id", "agent_boot_id", "backend_epoch", "call_id"}, nil, &r) != nil || !control.ValidID(r.RequestID) || !control.ValidID(r.Boot) || !control.ValidID(r.Epoch) || !control.ValidID(r.CallID) {
		return r, ErrProtocol
	}
	return r, nil
}

type Format struct {
	SampleRate   int    `json:"sample_rate"`
	Channels     int    `json:"channels"`
	SampleFormat string `json:"sample_format"`
	FrameSamples int    `json:"frame_samples"`
}

var format = Format{8000, 1, "s16le", 160}

type Created struct {
	ID     string `json:"session_id"`
	Token  string `json:"token"`
	Boot   string `json:"agent_boot_id"`
	Epoch  string `json:"backend_epoch"`
	CallID string `json:"call_id"`
	Format Format `json:"format"`
	Socket string `json:"media_socket"`
}
type SessionStatus struct {
	ID             string       `json:"session_id"`
	CallID         string       `json:"call_id"`
	Boot           string       `json:"agent_boot_id"`
	Epoch          string       `json:"backend_epoch"`
	State          string       `json:"state"`
	Reason         string       `json:"reason"`
	Created        time.Time    `json:"created_at"`
	Closed         *time.Time   `json:"closed_at,omitempty"`
	UplinkFrames   uint64       `json:"uplink_frames"`
	DownlinkFrames uint64       `json:"downlink_frames"`
	UplinkGaps     uint64       `json:"uplink_sequence_gaps"`
	DownlinkGaps   uint64       `json:"downlink_sequence_gaps"`
	LastUplink     *time.Time   `json:"last_uplink,omitempty"`
	LastDownlink   *time.Time   `json:"last_downlink,omitempty"`
	Actual         *HelperEvent `json:"actual,omitempty"`
	Stats          *HelperEvent `json:"helper_stats,omitempty"`
}
type Status struct {
	Available      bool           `json:"available"`
	Implementation string         `json:"implementation"`
	Verification   string         `json:"verification"`
	VoiceReady     bool           `json:"voice_ready"`
	Reason         string         `json:"reason"`
	Session        *SessionStatus `json:"session,omitempty"`
}
type session struct {
	expires     time.Time
	connectBy   time.Time
	handshakeBy time.Time
	req         Request
	result      Created
	generation  uint64
	status      SessionStatus
	ctx         context.Context
	cancel      context.CancelFunc
	bound       bool
	connection  chan net.Conn
	done        chan struct{}
	reason      string
}
type closedRequest struct{ requestID, sessionID string }
type Manager struct {
	mu           sync.Mutex
	q            Qualifier
	path, socket string
	active       *session
	last         *SessionStatus
	closed       []closedRequest
	ctx          context.Context
	cancel       context.CancelFunc
	done         chan struct{}
	wg           sync.WaitGroup
	start        func(context.Context, string, string) (helper, error)
	listening    bool
	err          string
}

func New(q Qualifier, path, socket string) *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{q: q, path: path, socket: socket, ctx: ctx, cancel: cancel, done: make(chan struct{}), start: startChild}
	if e := checkHelper(path); e != nil {
		m.err = e.Error()
	}
	return m
}
func (m *Manager) qualification(ctx context.Context) (control.AudioQualification, error) {
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	return m.q.AudioQualification(ctx)
}
func eligible(q control.AudioQualification, r Request) bool {
	return q.Eligible && q.Boot == r.Boot && q.Epoch == r.Epoch && q.CallID == r.CallID
}
func (m *Manager) Create(ctx context.Context, r Request) (Created, int) {
	q, e := m.qualification(ctx)
	if ctx.Err() != nil {
		return Created{}, 503
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.active != nil && m.active.req.RequestID == r.RequestID {
		if m.active.req != r {
			return Created{}, 409
		}
		if m.active.reason != "" || m.active.ctx.Err() != nil {
			return Created{}, 410
		}
		if e != nil || !eligible(q, r) || q.Generation != m.active.generation {
			m.stopLocked(m.active, "lease_revoked")
			return Created{}, 409
		}
		return m.active.result, 200
	}
	for _, old := range m.closed {
		if old.requestID == r.RequestID {
			return Created{}, 410
		}
	}
	if m.active != nil {
		return Created{}, 409
	}
	if m.ctx.Err() != nil || !m.listening || m.err != "" {
		return Created{}, 503
	}
	if e != nil {
		return Created{}, 503
	}
	if !eligible(q, r) {
		return Created{}, 409
	}
	id, err := identity.UUID()
	if err != nil {
		return Created{}, 503
	}
	var token [32]byte
	if _, err = rand.Read(token[:]); err != nil {
		return Created{}, 503
	}
	child, cancel := context.WithCancel(m.ctx)
	s := &session{expires: time.Now().Add(30 * time.Minute), connectBy: time.Now().Add(5 * time.Second), req: r, result: Created{id, hex.EncodeToString(token[:]), r.Boot, r.Epoch, r.CallID, format, m.socket}, generation: q.Generation, ctx: child, cancel: cancel, connection: make(chan net.Conn, 1), done: make(chan struct{})}
	s.status = SessionStatus{ID: id, CallID: r.CallID, Boot: r.Boot, Epoch: r.Epoch, State: "awaiting_connection", Created: time.Now().UTC()}
	m.active = s
	m.wg.Add(1)
	go m.run(s)
	return s.result, 201
}
func (m *Manager) View() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	v := Status{Available: m.err == "" && m.listening && m.ctx.Err() == nil, Implementation: "implemented", Verification: "unverified", Reason: m.err}
	if m.active != nil {
		x := m.active.status
		v.Session = &x
	} else if m.last != nil {
		x := *m.last
		v.Session = &x
	}
	return v
}
func (m *Manager) stopLocked(s *session, reason string) {
	if s.reason == "" {
		s.reason = reason
		s.status.State = "stopping"
		s.status.Reason = reason
	}
	s.cancel()
}
func (m *Manager) Stop(id string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.active != nil && m.active.result.ID == id {
		m.stopLocked(m.active, "requested_stop")
		return 204
	}
	for _, old := range m.closed {
		if old.sessionID == id {
			return 204
		}
	}
	return 404
}
func (m *Manager) fail(s *session, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopLocked(s, reason)
}
func (m *Manager) Close() { m.cancel(); <-m.done }
func (m *Manager) watch() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	events := m.q.AudioEvents()
	for {
		select {
		case <-m.ctx.Done():
			return
		case _, ok := <-events:
			if !ok {
				m.cancel()
				return
			}
		case <-ticker.C:
		}
		m.mu.Lock()
		s := m.active
		m.mu.Unlock()
		if s == nil {
			continue
		}
		q, e := m.qualification(m.ctx)
		if e != nil || !eligible(q, s.req) || q.Generation != s.generation {
			m.fail(s, "lease_revoked")
		}
	}
}
func (m *Manager) authenticate(conn net.Conn) {
	defer conn.Close()
	handshakeBy := time.Now().Add(3 * time.Second)
	conn.SetDeadline(handshakeBy)
	b, e := ReadJSON(conn, 1024)
	if e != nil {
		return
	}
	var auth struct {
		ID    string `json:"session_id"`
		Token string `json:"token"`
	}
	if strictjson.Decode(b, []string{"session_id", "token"}, nil, &auth) != nil || !control.ValidID(auth.ID) || len(auth.Token) != 64 {
		return
	}
	q, e := m.qualification(m.ctx)
	m.mu.Lock()
	s := m.active
	if s == nil || s.result.ID != auth.ID || s.bound || s.ctx.Err() != nil || subtle.ConstantTimeCompare([]byte(auth.Token), []byte(s.result.Token)) != 1 {
		m.mu.Unlock()
		return
	}
	if e != nil || !eligible(q, s.req) || q.Generation != s.generation {
		m.stopLocked(s, "lease_revoked")
		m.mu.Unlock()
		return
	}
	s.handshakeBy = handshakeBy
	s.bound = true
	s.status.State = "starting"
	s.connection <- conn
	m.mu.Unlock()
	<-s.done
}
func (m *Manager) run(s *session) {
	defer m.wg.Done()
	defer close(s.done)
	defer func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		now := time.Now().UTC()
		s.status.Closed = &now
		s.status.State = "closed"
		if s.reason == "" {
			s.reason = "stopped"
		}
		s.status.Reason = s.reason
		m.last = &s.status
		m.closed = append(m.closed, closedRequest{s.req.RequestID, s.result.ID})
		if len(m.closed) > 64 {
			m.closed = m.closed[len(m.closed)-64:]
		}
		if m.active == s {
			m.active = nil
		}
	}()
	timer := time.NewTimer(time.Until(s.connectBy))
	defer timer.Stop()
	var conn net.Conn
	select {
	case conn = <-s.connection:
	case <-s.ctx.Done():
		return
	case <-timer.C:
		m.fail(s, "connect_timeout")
		return
	}
	defer conn.Close()
	if s.ctx.Err() != nil {
		return
	}
	h, e := m.start(s.ctx, m.path, s.result.ID)
	if e != nil {
		m.fail(s, "helper_start")
		return
	}
	defer h.Stop()
	stopIO := context.AfterFunc(s.ctx, func() { h.PCM().Close(); h.Control().Close(); conn.Close() })
	defer stopIO()
	ctrl := h.Control()
	ctrl.SetReadDeadline(s.handshakeBy)
	b, e := ReadJSON(ctrl, 2048)
	if e != nil {
		m.fail(s, "helper_ready")
		return
	}
	event, e := parseHelper(b)
	if e == nil && event.Type == "error" {
		m.fail(s, event.Code)
		return
	}
	if e != nil || event.Type != "ready" {
		m.fail(s, "helper_ready")
		return
	}
	m.mu.Lock()
	s.status.Actual = &event
	m.mu.Unlock()
	q, e := m.qualification(s.ctx)
	if e != nil || !eligible(q, s.req) || q.Generation != s.generation || s.ctx.Err() != nil {
		m.fail(s, "lease_revoked")
		return
	}
	deadline := time.Now().Add(100 * time.Millisecond)
	if s.handshakeBy.Before(deadline) {
		deadline = s.handshakeBy
	}
	conn.SetWriteDeadline(deadline)
	if WriteJSON(conn, struct {
		OK bool `json:"ok"`
		Format
	}{true, format}, 1024) != nil {
		m.fail(s, "handshake_write")
		return
	}
	conn.SetDeadline(time.Time{})
	m.mu.Lock()
	s.status.State = "streaming"
	m.mu.Unlock()
	streamCtx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); m.relay(s, conn, h.PCM(), 1) }()
	go func() { defer wg.Done(); m.relay(s, h.PCM(), conn, 2) }()
	go func() {
		defer wg.Done()
		for {
			ctrl.SetReadDeadline(time.Now().Add(2500 * time.Millisecond))
			b, e := ReadJSON(ctrl, 2048)
			if e != nil {
				m.fail(s, "helper_control")
				return
			}
			event, e := parseHelper(b)
			if e == nil && event.Type == "error" {
				m.fail(s, event.Code)
				return
			}
			if e != nil || event.Type != "stats" {
				m.fail(s, "helper_error")
				return
			}
			m.mu.Lock()
			s.status.Stats = &event
			m.mu.Unlock()
		}
	}()
	ping := time.NewTicker(500 * time.Millisecond)
	defer ping.Stop()
	max := time.NewTimer(time.Until(s.expires))
	defer max.Stop()
loop:
	for {
		select {
		case <-streamCtx.Done():
			break loop
		case <-h.Exited():
			m.fail(s, "helper_exit")
			break loop
		case <-max.C:
			m.fail(s, "session_limit")
			break loop
		case <-ping.C:
			if h.Send("ping") != nil {
				m.fail(s, "helper_control")
				break loop
			}
		}
	}
	_ = h.Send("stop")
	conn.Close()
	h.PCM().Close()
	ctrl.Close()
	wg.Wait()
}
func (m *Manager) relay(s *session, src, dst net.Conn, direction byte) {
	var seq uint64
	lastValid := time.Now()
	for {
		src.SetReadDeadline(lastValid.Add(2 * time.Second))
		frame, gap, e := ReadFrame(src, s.result.ID, direction, &seq)
		if e != nil {
			m.fail(s, "media_read")
			return
		}
		lastValid = time.Now()
		if s.ctx.Err() != nil {
			return
		}
		dst.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
		if writeAll(dst, frame[:]) != nil {
			m.fail(s, "media_write")
			return
		}
		m.mu.Lock()
		now := time.Now().UTC()
		if direction == 1 {
			s.status.UplinkFrames++
			s.status.UplinkGaps += gap
			s.status.LastUplink = &now
		} else {
			s.status.DownlinkFrames++
			s.status.DownlinkGaps += gap
			s.status.LastDownlink = &now
		}
		m.mu.Unlock()
	}
}
