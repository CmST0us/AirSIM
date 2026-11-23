package control

import (
	"airsim.local/server/internal/ice"
	"airsim.local/server/internal/wire"
	"context"
	"github.com/jackc/pgx/v5"
	"log"
	"net/http"
	"strings"
	"time"
)

const (
	// mediaCodec is the only codec negotiated in the WebRTC audio track.
	mediaCodec  = "opus"
	offerWindow = 30 * time.Second
	// answerWindow covers the Agent's candidate gathering, which ends within 8 s.
	answerWindow = 10 * time.Second
	// controlReconnectGrace keeps running WebRTC media alive across brief WSS drops.
	controlReconnectGrace = 20 * time.Second
	closedSessionTTL      = 24 * time.Hour
	maxSDP                = 32768
)

type mediaSpec struct {
	ID, Module, Call, Boot, Backend, Connection, Client, Generation string
	Created, Expires                                                time.Time
}
type mediaSession struct {
	Spec                  mediaSpec
	Request               string
	Offer, Answer, Reason string
	Closed, busy, started bool
	answerBy              time.Time
	closedAt              time.Time
	offlineSince          time.Time
	// answered closes once the Agent answers or the session closes.
	answered chan struct{}
	signaled bool
}

func (m *mediaSession) signal() {
	if !m.signaled {
		m.signaled = true
		close(m.answered)
	}
}

func validSDP(sdp string) bool { return len(sdp) <= maxSDP && strings.HasPrefix(sdp, "v=0\r\n") }

// stopMedia is called with mu held. It never performs network I/O.
func (s *Server) stopMedia(m *mediaSession, reason string) {
	if m.Closed {
		return
	}
	m.Closed = true
	m.Reason = reason
	m.closedAt = time.Now()
	m.Offer, m.Answer = "", ""
	m.signal()
	log.Printf("media_session_closed session=%s module=%s reason=%s", m.Spec.ID, m.Spec.Module, reason)
	if p := s.peers[m.Spec.Module]; m.started && p != nil && p.epoch == m.Spec.Connection {
		s.enqueue(p, "media_stop", map[string]string{"session_id": m.Spec.ID, "reason": reason})
	}
}

// pruneClosedSessions removes closed media records older than closedSessionTTL.
// Called with s.mu held. Synthetic records with zero closedAt are retained.
func (s *Server) pruneClosedSessions(now time.Time) {
	for id, m := range s.sessions {
		if m.Closed && !m.closedAt.IsZero() && now.Sub(m.closedAt) > closedSessionTTL {
			delete(s.sessions, id)
		}
	}
}
func (s *Server) queueMedia(m *mediaSession) {
	if m.busy {
		return
	}
	m.busy = true
	select {
	case s.mediaJobs <- m:
	default:
		m.busy = false
	}
}
func (s *Server) mediaActive(m *mediaSession) bool {
	if m.Closed {
		return false
	}
	p := s.peers[m.Spec.Module]
	if p == nil {
		// Allow an already-answered streaming session to survive a transient
		// control WSS drop while the module reconnects.
		return m.Answer != "" && !m.offlineSince.IsZero() && time.Since(m.offlineSince) < controlReconnectGrace
	}
	if p.epoch != m.Spec.Connection || p.boot != m.Spec.Boot || p.backend != m.Spec.Backend || p.snapshot == nil {
		return false
	}
	return activeCall(p, m.Spec.Call)
}
func activeCall(p *peer, call string) bool {
	for _, c := range p.snapshot.Calls.Calls {
		if c.ID == call && c.State == "active" && c.Ownership == "managed" {
			return true
		}
	}
	return false
}
func (s *Server) mediaWorker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case m := <-s.mediaJobs:
			s.performMedia(ctx, m)
		}
	}
}

// performMedia revalidates call ownership in the database. It holds no lock during the query.
func (s *Server) performMedia(ctx context.Context, m *mediaSession) {
	s.mu.Lock()
	active := s.mediaActive(m)
	now := time.Now()
	late := !m.started && !now.Before(m.Spec.Expires)
	unanswered := m.started && m.Answer == "" && !now.Before(m.answerBy)
	spec := m.Spec
	s.mu.Unlock()
	reason := ""
	switch {
	case !active:
		reason = "lease_revoked"
	case late:
		reason = "offer_timeout"
	case unanswered:
		reason = "answer_timeout"
	default:
		check, cancel := context.WithTimeout(ctx, time.Second)
		owned, err := s.mediaOwner(check, spec)
		cancel()
		if err != nil || !owned {
			reason = "lease_revoked"
		}
	}
	s.mu.Lock()
	if reason != "" || !s.mediaActive(m) {
		if reason == "" {
			reason = "lease_revoked"
		}
		s.stopMedia(m, reason)
	}
	m.busy = false
	s.mu.Unlock()
}

// ownsReservation locks the module reservation inside tx and reports whether
// the session still owns its call.
func ownsReservation(ctx context.Context, tx pgx.Tx, spec mediaSpec) bool {
	var owner, gen, boot, backend string
	var call *string
	e := tx.QueryRow(ctx, "SELECT client_id,generation,agent_boot_id,backend_epoch,call_id FROM reservations WHERE module_id=$1 FOR UPDATE", spec.Module).Scan(&owner, &gen, &boot, &backend, &call)
	return e == nil && owner == spec.Client && gen == spec.Generation && boot == spec.Boot && backend == spec.Backend && call != nil && *call == spec.Call
}

func (s *Server) mediaAPI(w http.ResponseWriter, r *http.Request, user, client, module string, parts []string) {
	if !wire.UUID.MatchString(parts[2]) {
		wire.Error(w, 404, "not_found")
		return
	}
	switch {
	case len(parts) == 5 && r.Method == "DELETE":
		s.mu.Lock()
		defer s.mu.Unlock()
		if m := s.ownedSession(client, module, parts[2], parts[4]); m != nil {
			s.stopMedia(m, "client_closed")
			w.WriteHeader(204)
			return
		}
		wire.Error(w, 404, "not_found")
	case len(parts) == 6 && parts[5] == "offer" && r.Method == "POST":
		s.mediaOffer(w, r, client, module, parts[2], parts[4])
	case len(parts) == 4 && r.Method == "POST":
		s.mediaCreate(w, r, client, module, parts[2])
	default:
		wire.Error(w, 404, "not_found")
	}
}
func (s *Server) ownedSession(client, module, call, id string) *mediaSession {
	for _, m := range s.sessions {
		if m.Spec.ID == id && m.Spec.Module == module && m.Spec.Call == call && m.Spec.Client == client {
			return m
		}
	}
	return nil
}
func (s *Server) mediaCreate(w http.ResponseWriter, r *http.Request, client, module, call string) {
	var b struct {
		Request    string `json:"request_id"`
		Connection string `json:"connection_epoch"`
		Generation string `json:"generation"`
		Codec      string `json:"codec"`
	}
	if wire.Body(w, r, &b, 8192, "request_id", "connection_epoch", "generation", "codec") != nil || b.Codec != mediaCodec || !wire.UUID.MatchString(b.Request) || !wire.UUID.MatchString(b.Connection) || !wire.UUID.MatchString(b.Generation) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	now := time.Now().UTC()
	s.mu.Lock()
	s.pruneClosedSessions(now)
	if old := s.sessions[b.Request]; old != nil {
		if old.Spec.Client != client || old.Spec.Module != module || old.Spec.Call != call || old.Spec.Connection != b.Connection || old.Spec.Generation != b.Generation {
			s.mu.Unlock()
			wire.Error(w, 409, "session_conflict")
		} else if old.Closed {
			s.mu.Unlock()
			wire.Error(w, 410, "session_closed")
		} else {
			s.mu.Unlock()
			s.mediaResult(w, 200, old)
		}
		return
	}
	if len(s.sessions) >= 10000 {
		s.mu.Unlock()
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	p := s.peers[module]
	if p == nil || p.snapshot == nil {
		s.mu.Unlock()
		wire.Error(w, 503, "module_offline")
		return
	}
	if p.mediaCodec != mediaCodec {
		s.mu.Unlock()
		wire.Error(w, 409, "media_unavailable")
		return
	}
	if p.epoch != b.Connection {
		s.mu.Unlock()
		wire.Error(w, 409, "epoch_conflict")
		return
	}
	if !activeCall(p, call) {
		s.mu.Unlock()
		wire.Error(w, 409, "call_conflict")
		return
	}
	spec := mediaSpec{ID: wire.ID(), Module: module, Call: call, Boot: p.boot, Backend: p.backend, Connection: p.epoch, Client: client, Generation: b.Generation, Created: now, Expires: now.Add(offerWindow)}
	s.mu.Unlock()

	// Verify reservation ownership in Postgres without holding s.mu.
	tx, e := s.db.Begin(r.Context())
	if e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	if !ownsReservation(r.Context(), tx, spec) {
		wire.Error(w, 409, "call_conflict")
		return
	}
	if tx.Commit(r.Context()) != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}

	s.mu.Lock()
	if old := s.sessions[b.Request]; old != nil {
		if old.Spec.Client != client || old.Spec.Module != module || old.Spec.Call != call || old.Spec.Connection != b.Connection || old.Spec.Generation != b.Generation {
			s.mu.Unlock()
			wire.Error(w, 409, "session_conflict")
		} else if old.Closed {
			s.mu.Unlock()
			wire.Error(w, 410, "session_closed")
		} else {
			s.mu.Unlock()
			s.mediaResult(w, 200, old)
		}
		return
	}
	if len(s.sessions) >= 10000 {
		s.mu.Unlock()
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	p = s.peers[module]
	if p == nil || p.snapshot == nil {
		s.mu.Unlock()
		wire.Error(w, 503, "module_offline")
		return
	}
	if p.epoch != spec.Connection || p.boot != spec.Boot || p.backend != spec.Backend || !activeCall(p, call) {
		s.mu.Unlock()
		wire.Error(w, 409, "call_conflict")
		return
	}
	count := 0
	var replaced []*mediaSession
	for _, m := range s.sessions {
		if m.Closed {
			continue
		}
		// The App recovers lost audio with a new session; it replaces the older one for the same call.
		if m.Spec.Module == module && m.Spec.Client == client && m.Spec.Call == call {
			replaced = append(replaced, m)
			continue
		}
		count++
		if m.Spec.Module == module || m.Spec.Client == client {
			s.mu.Unlock()
			wire.Error(w, 409, "session_conflict")
			return
		}
	}
	if count >= 32 {
		s.mu.Unlock()
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	for _, old := range replaced {
		s.stopMedia(old, "replaced")
	}
	m := &mediaSession{Request: b.Request, Spec: spec, answered: make(chan struct{})}
	s.sessions[b.Request] = m
	s.mu.Unlock()
	s.mediaResult(w, 201, m)
}
func (s *Server) mediaResult(w http.ResponseWriter, status int, m *mediaSession) {
	wire.JSON(w, status, map[string]any{"session_id": m.Spec.ID, "expires_at": m.Spec.Expires, "ice_servers": ice.Servers(s.cfg.TURNSecret, s.cfg.TURNHost, m.Spec.ID, "client", m.Spec.Created)})
}

// mediaOffer forwards the App's complete offer to the Agent once and waits for its complete answer.
func (s *Server) mediaOffer(w http.ResponseWriter, r *http.Request, client, module, call, id string) {
	var b struct {
		SDP string `json:"sdp"`
	}
	if !wire.UUID.MatchString(id) || wire.Body(w, r, &b, 2*maxSDP, "sdp") != nil || !validSDP(b.SDP) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	s.mu.Lock()
	m := s.ownedSession(client, module, call, id)
	switch {
	case m == nil:
		s.mu.Unlock()
		wire.Error(w, 404, "not_found")
		return
	case m.Closed:
		s.mu.Unlock()
		wire.Error(w, 410, "session_closed")
		return
	case m.started && m.Offer != b.SDP:
		s.mu.Unlock()
		wire.Error(w, 409, "session_conflict")
		return
	case !m.started:
		spec := m.Spec
		if !time.Now().Before(spec.Expires) {
			s.stopMedia(m, "offer_timeout")
			s.mu.Unlock()
			wire.Error(w, 410, "session_closed")
			return
		}
		if !s.mediaActive(m) {
			s.stopMedia(m, "lease_revoked")
			s.mu.Unlock()
			wire.Error(w, 409, "call_conflict")
			return
		}
		// Check DB reservation outside s.mu, then re-lock to transition m.started once.
		s.mu.Unlock()
		tx, e := s.db.Begin(r.Context())
		if e != nil {
			wire.Error(w, 503, "database_unavailable")
			return
		}
		owned := ownsReservation(r.Context(), tx, spec)
		if !owned {
			_ = tx.Rollback(r.Context())
			s.mu.Lock()
			s.stopMedia(m, "lease_revoked")
			s.mu.Unlock()
			wire.Error(w, 409, "call_conflict")
			return
		}
		if tx.Commit(r.Context()) != nil {
			wire.Error(w, 503, "database_unavailable")
			return
		}
		s.mu.Lock()
		if m.Closed {
			s.mu.Unlock()
			wire.Error(w, 410, "session_closed")
			return
		}
		if m.started {
			if m.Offer != b.SDP {
				s.mu.Unlock()
				wire.Error(w, 409, "session_conflict")
				return
			}
		} else if status, code := s.startMediaLocked(m, b.SDP); status != 0 {
			s.mu.Unlock()
			wire.Error(w, status, code)
			return
		}
	}
	answered := m.answered
	deadline := m.answerBy
	s.mu.Unlock()
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-answered:
	case <-timer.C:
	case <-r.Context().Done():
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if m.Answer != "" {
		wire.JSON(w, 200, map[string]string{"sdp": m.Answer})
		return
	}
	// Media failures leave call control intact, so they avoid the 409/503
	// statuses that tell the App its control state is no longer current.
	if !m.Closed {
		s.stopMedia(m, "answer_timeout")
		log.Printf("media_failed reason=%s", m.Reason)
		wire.Error(w, 504, "media_timeout")
		return
	}
	log.Printf("media_failed reason=%s", m.Reason)
	wire.Error(w, 502, "media_unavailable")
}

// startMediaLocked is called with mu held after reservation ownership has been
// verified in Postgres.
func (s *Server) startMediaLocked(m *mediaSession, offer string) (int, string) {
	if !time.Now().Before(m.Spec.Expires) {
		s.stopMedia(m, "offer_timeout")
		return 410, "session_closed"
	}
	if !s.mediaActive(m) {
		s.stopMedia(m, "lease_revoked")
		return 409, "call_conflict"
	}
	now := time.Now().UTC()
	p := s.peers[m.Spec.Module]
	if p == nil || !s.enqueue(p, "media_start", map[string]any{"request_id": m.Request, "session_id": m.Spec.ID, "call_id": m.Spec.Call, "agent_boot_id": m.Spec.Boot, "backend_epoch": m.Spec.Backend, "client_installation_id": m.Spec.Client, "generation": m.Spec.Generation, "expires_at": now.Add(answerWindow), "offer": offer, "ice_servers": ice.Servers(s.cfg.TURNSecret, s.cfg.TURNHost, m.Spec.ID, "agent", now)}) {
		s.stopMedia(m, "control_closed")
		return 503, "module_offline"
	}
	m.started = true
	m.Offer = offer
	m.answerBy = now.Add(answerWindow)
	return 0, ""
}

// mediaAnswer records the Agent's answer. Called with mu held.
func (s *Server) mediaAnswer(p *peer, id, sdp string) {
	for _, m := range s.sessions {
		if m.Spec.ID == id && m.Spec.Module == p.module && m.Spec.Connection == p.epoch && m.started && !m.Closed && m.Answer == "" {
			m.Answer = sdp
			m.signal()
		}
	}
}

func (s *Server) Run(ctx context.Context) {
	done := make(chan struct{}, 32)
	for i := 0; i < 32; i++ {
		go func() { defer func() { done <- struct{}{} }(); s.mediaWorker(ctx) }()
	}
	defer func() {
		for i := 0; i < 32; i++ {
			<-done
		}
	}()
	t := time.NewTicker(time.Second)
	defer t.Stop()
	cleanup := time.NewTicker(10 * time.Minute)
	defer cleanup.Stop()
	for {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			for _, p := range s.peers {
				p.cancel()
			}
			for _, m := range s.sessions {
				s.stopMedia(m, "shutdown")
			}
			s.mu.Unlock()
			return
		case <-t.C:
			s.mu.Lock()
			for _, m := range s.sessions {
				if !m.Closed {
					s.queueMedia(m)
				}
			}
			s.mu.Unlock()
		case <-cleanup.C:
			s.mu.Lock()
			s.pruneClosedSessions(time.Now())
			s.mu.Unlock()
			s.pruneDatabase(ctx)
		}
	}
}

// pruneDatabase prevents unbounded growth of historical commands, push
// deliveries and expired pairing rows so the server never hits the 10k wall.
func (s *Server) pruneDatabase(ctx context.Context) {
	if s.db == nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, _ = s.db.Exec(cctx, `DELETE FROM commands WHERE state IN ('completed','outcome_unknown') AND created_at < now() - interval '30 days' AND id NOT IN (SELECT command_id FROM reservations)`)
	_, _ = s.db.Exec(cctx, `DELETE FROM push_deliveries WHERE created_at < now() - interval '30 days'`)
	_, _ = s.db.Exec(cctx, `DELETE FROM pairing_requests WHERE expires_at < now() - interval '7 days'`)
}
