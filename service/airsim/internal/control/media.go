package control

import (
	"airsim.local/server/internal/media"
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
)

type mediaSession struct {
	Spec                         media.Spec
	Request, Ticket, AgentTicket string
	Closed, busy, cleanup        bool
	ready                        chan struct{}
}

func (s *Server) mediaCall(ctx context.Context, method, path string, body any) error {
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	req, e := http.NewRequestWithContext(ctx, method, s.cfg.MediaInternal+path, bytes.NewReader(data))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.cfg.MediaToken)
	resp, e := s.mediaHTTP.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 300 {
		return errors.New("media_unavailable")
	}
	return nil
}

// stopMedia is called with mu held. It never performs network I/O.
func (s *Server) stopMedia(_ context.Context, m *mediaSession, reason string) {
	if m.Closed {
		return
	}
	m.Closed = true
	m.cleanup = true
	m.Ticket = ""
	m.AgentTicket = ""
	if p := s.peers[m.Spec.Module]; p != nil && p.epoch == m.Spec.Connection {
		s.enqueue(p, "media_stop", map[string]string{"session_id": m.Spec.ID, "reason": reason})
	}
	s.queueMedia(m)
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
	if p == nil || p.epoch != m.Spec.Connection || p.boot != m.Spec.Boot || p.backend != m.Spec.Backend || p.snapshot == nil {
		return false
	}
	for _, c := range p.snapshot.Calls.Calls {
		if c.ID == m.Spec.Call && c.State == "active" && c.Ownership == "managed" {
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
func (s *Server) performMedia(ctx context.Context, m *mediaSession) {
	s.mu.Lock()
	active := s.mediaActive(m)
	closed := m.Closed
	spec := m.Spec
	s.mu.Unlock()
	check, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	var err error
	if !closed && active {
		var owned bool
		owned, err = s.mediaOwner(check, spec)
		if err == nil && !owned {
			err = errors.New("lease_revoked")
		}
		if err == nil {
			err = s.mediaCall(check, "POST", "/internal/sessions/"+spec.ID+"/renew", map[string]string{"connection_epoch": spec.Connection, "generation": spec.Generation})
		}
	} else {
		err = errors.New("lease_revoked")
	}
	s.mu.Lock()
	if !m.Closed && (err != nil || !s.mediaActive(m)) {
		s.stopMedia(ctx, m, "lease_revoked")
	}
	needDelete := m.Closed && m.cleanup
	s.mu.Unlock()
	if needDelete {
		dc, cc := context.WithTimeout(ctx, time.Second)
		_ = s.mediaCall(dc, "DELETE", "/internal/sessions/"+spec.ID, nil)
		cc()
	}
	s.mu.Lock()
	if needDelete {
		m.cleanup = false
	}
	m.busy = false
	s.mu.Unlock()
}
func (s *Server) mediaAPI(w http.ResponseWriter, r *http.Request, user, client, module string, parts []string) {
	if !wire.UUID.MatchString(parts[2]) {
		wire.Error(w, 404, "not_found")
		return
	}
	s.mu.Lock()
	if len(parts) == 5 && r.Method == "DELETE" {
		for _, m := range s.sessions {
			if m.Spec.ID == parts[4] && m.Spec.Module == module && m.Spec.Call == parts[2] && m.Spec.Client == client {
				s.stopMedia(r.Context(), m, "client_closed")
				s.mu.Unlock()
				w.WriteHeader(204)
				return
			}
		}
		s.mu.Unlock()
		wire.Error(w, 404, "not_found")
		return
	}
	s.mu.Unlock()
	if len(parts) != 4 || r.Method != "POST" {
		wire.Error(w, 404, "not_found")
		return
	}
	var b struct {
		Request    string `json:"request_id"`
		Connection string `json:"connection_epoch"`
		Generation string `json:"generation"`
	}
	if wire.Body(w, r, &b, 8192, "request_id", "connection_epoch", "generation") != nil || !wire.UUID.MatchString(b.Request) || !wire.UUID.MatchString(b.Connection) || !wire.UUID.MatchString(b.Generation) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	s.mu.Lock()
	if old := s.sessions[b.Request]; old != nil {
		if old.Spec.Client != client || old.Spec.Module != module || old.Spec.Call != parts[2] || old.Spec.Connection != b.Connection || old.Spec.Generation != b.Generation {
			s.mu.Unlock()
			wire.Error(w, 409, "session_conflict")
			return
		}
		ready := old.ready
		s.mu.Unlock()
		select {
		case <-ready:
		case <-r.Context().Done():
			wire.Error(w, 503, "media_unavailable")
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if old.Closed {
			wire.Error(w, 410, "session_closed")
		} else {
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
	if p.epoch != b.Connection {
		s.mu.Unlock()
		wire.Error(w, 409, "epoch_conflict")
		return
	}
	active := false
	for _, c := range p.snapshot.Calls.Calls {
		if c.ID == parts[2] && c.State == "active" && c.Ownership == "managed" {
			active = true
		}
	}
	if !active {
		s.mu.Unlock()
		wire.Error(w, 409, "call_conflict")
		return
	}
	tx, e := s.db.Begin(r.Context())
	if e != nil {
		s.mu.Unlock()
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var owner, gen, boot, backend string
	var call *string
	e = tx.QueryRow(r.Context(), "SELECT client_id,generation,agent_boot_id,backend_epoch,call_id FROM reservations WHERE module_id=$1 FOR UPDATE", module).Scan(&owner, &gen, &boot, &backend, &call)
	if e != nil || owner != client || gen != b.Generation || call == nil || *call != parts[2] || boot != p.boot || backend != p.backend {
		s.mu.Unlock()
		wire.Error(w, 409, "call_conflict")
		return
	}
	count := 0
	for _, m := range s.sessions {
		if !m.Closed {
			count++
			if m.Spec.Module == module || m.Spec.Client == client {
				s.mu.Unlock()
				wire.Error(w, 409, "session_conflict")
				return
			}
		}
	}
	if count >= 32 {
		s.mu.Unlock()
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	m := &mediaSession{Request: b.Request, Ticket: wire.Token(), AgentTicket: wire.Token(), busy: true, ready: make(chan struct{})}
	m.Spec = media.Spec{ID: wire.ID(), Module: module, Call: parts[2], Boot: p.boot, Backend: p.backend, Connection: p.epoch, Client: client, Generation: gen, AgentHash: wire.Hash(m.AgentTicket), ClientHash: wire.Hash(m.Ticket), Expires: time.Now().UTC().Add(30 * time.Second)}
	s.sessions[b.Request] = m
	if e = tx.Commit(r.Context()); e != nil {
		m.busy = false
		close(m.ready)
		s.stopMedia(r.Context(), m, "database_unavailable")
		s.mu.Unlock()
		wire.Error(w, 503, "database_unavailable")
		return
	}
	s.mu.Unlock()
	// A pending slot preserves same-request arbitration while global state stays available.
	e = s.mediaCall(r.Context(), "POST", "/internal/sessions", m.Spec)
	s.mu.Lock()
	m.busy = false
	close(m.ready)
	if e != nil || !s.mediaActive(m) {
		s.stopMedia(r.Context(), m, "media_unavailable")
		if m.cleanup {
			s.queueMedia(m)
		}
		s.mu.Unlock()
		wire.Error(w, 503, "media_unavailable")
		return
	}
	// Reacquire the reservation transaction after I/O. Never hold a DB row lock while waiting for mu.
	tx, e = s.db.Begin(r.Context())
	if e != nil {
		s.stopMedia(r.Context(), m, "database_unavailable")
		s.mu.Unlock()
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	e = tx.QueryRow(r.Context(), "SELECT client_id,generation,agent_boot_id,backend_epoch,call_id FROM reservations WHERE module_id=$1 FOR UPDATE", module).Scan(&owner, &gen, &boot, &backend, &call)
	if e != nil || owner != client || gen != m.Spec.Generation || boot != m.Spec.Boot || backend != m.Spec.Backend || call == nil || *call != m.Spec.Call {
		s.stopMedia(r.Context(), m, "lease_revoked")
		s.mu.Unlock()
		wire.Error(w, 409, "call_conflict")
		return
	}
	if !s.enqueue(p, "media_start", map[string]any{"request_id": m.Request, "session_id": m.Spec.ID, "call_id": m.Spec.Call, "agent_boot_id": m.Spec.Boot, "backend_epoch": m.Spec.Backend, "client_installation_id": client, "generation": gen, "ticket": m.AgentTicket, "expires_at": m.Spec.Expires}) {
		s.stopMedia(r.Context(), m, "control_closed")
		s.mu.Unlock()
		wire.Error(w, 503, "module_offline")
		return
	}
	if tx.Commit(r.Context()) != nil {
		s.stopMedia(r.Context(), m, "database_unavailable")
		s.mu.Unlock()
		wire.Error(w, 503, "database_unavailable")
		return
	}
	s.mediaResult(w, 201, m)
	s.mu.Unlock()
}
func (s *Server) mediaResult(w http.ResponseWriter, status int, m *mediaSession) {
	wire.JSON(w, status, map[string]any{"session_id": m.Spec.ID, "ticket": m.Ticket, "expires_at": m.Spec.Expires, "media_url": "wss" + strings.TrimPrefix(s.cfg.Media, "https") + "/v2/media", "format": media.Format})
}
func (s *Server) Run(ctx context.Context) {
	defer s.mediaHTTP.CloseIdleConnections()
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
	for {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			for _, p := range s.peers {
				p.cancel()
			}
			for _, m := range s.sessions {
				s.stopMedia(ctx, m, "shutdown")
			}
			s.mu.Unlock()
			return
		case <-t.C:
			s.mu.Lock()
			for _, m := range s.sessions {
				if !m.Closed || m.cleanup {
					s.queueMedia(m)
				}
			}
			s.mu.Unlock()
		}
	}
}
