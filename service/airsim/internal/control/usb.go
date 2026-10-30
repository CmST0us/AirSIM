package control

import (
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"time"
)

type usbAuthorization struct {
	Server      string    `json:"server_id"`
	Module      string    `json:"module_id"`
	Client      string    `json:"client_installation_id"`
	Origin      string    `json:"api_origin"`
	Certificate string    `json:"certificate_der_base64"`
	Token       string    `json:"token"`
	Expires     time.Time `json:"expires_at"`
}

type usbRequest struct {
	client  string
	expires time.Time
	result  chan *usbAuthorization
}

func (s *Server) usbAuthorization(w http.ResponseWriter, r *http.Request, client, module string) {
	w.Header().Set("Cache-Control", "no-store")
	var body struct{}
	if wire.Body(w, r, &body, 8192) != nil {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	id := wire.ID()
	pending := &usbRequest{client: client, expires: time.Now().UTC().Truncate(time.Second).Add(24 * time.Hour), result: make(chan *usbAuthorization, 1)}
	s.mu.Lock()
	p := s.peers[module]
	if p == nil || !p.usbLocal || p.ctx.Err() != nil || p.usbRevoked[client] {
		s.mu.Unlock()
		wire.Error(w, 503, "usb_unavailable")
		return
	}
	if p.usbRequests == nil {
		p.usbRequests = make(map[string]*usbRequest)
	}
	p.usbRequests[id] = pending
	sent := s.enqueue(p, "usb_authorize", map[string]any{"request_id": id, "client_installation_id": client, "expires_at": pending.expires})
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(p.usbRequests, id); s.mu.Unlock() }()
	if !sent {
		wire.Error(w, 503, "usb_unavailable")
		return
	}
	select {
	case result := <-pending.result:
		s.mu.Lock()
		current := s.peers[module] == p && p.ctx.Err() == nil
		s.mu.Unlock()
		if result != nil && current && ctx.Err() == nil {
			wire.JSON(w, 200, result)
			return
		}
	case <-p.ctx.Done():
	case <-ctx.Done():
	}
	wire.Error(w, 503, "usb_unavailable")
}

// Called with s.mu held, as part of the current control connection's receive loop.
func (s *Server) usbResponse(p *peer, payload json.RawMessage) bool {
	var response struct {
		Request       string          `json:"request_id"`
		Status        int             `json:"status_code"`
		Authorization json.RawMessage `json:"authorization"`
	}
	if len(payload) > 16*1024 || wire.DecodeNullable(payload, &response, "authorization") != nil || !wire.UUID.MatchString(response.Request) || (response.Status != 200 && response.Status != 503) {
		return false
	}
	if s.peers[p.module] != p || !p.usbLocal {
		return false
	}
	pending := p.usbRequests[response.Request]
	// Responses to timed-out or disconnected HTTP requests contain no reusable state.
	if pending == nil {
		return true
	}
	var authorization *usbAuthorization
	if response.Status == 503 {
		if !bytes.Equal(bytes.TrimSpace(response.Authorization), []byte("null")) {
			return false
		}
	} else {
		authorization = &usbAuthorization{}
		if wire.Decode(response.Authorization, authorization) != nil || authorization.Server != s.cfg.Server || authorization.Module != p.module || authorization.Client != pending.client || !authorization.Expires.Equal(pending.expires) || !authorization.Expires.After(time.Now()) || !wire.Hex.MatchString(authorization.Token) {
			return false
		}
		origin, err := url.Parse(authorization.Origin)
		if err != nil || origin.Scheme != "https" || origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.ForceQuery || origin.Fragment != "" {
			return false
		}
		ip, err := netip.ParseAddr(origin.Hostname())
		if err != nil || !ip.Is4() || !ip.IsPrivate() {
			return false
		}
		if origin.Port() != "" {
			port, err := strconv.Atoi(origin.Port())
			if err != nil || port < 1 || port > 65535 {
				return false
			}
		}
		der, err := base64.StdEncoding.Strict().DecodeString(authorization.Certificate)
		if err != nil {
			return false
		}
		if _, err = x509.ParseCertificate(der); err != nil {
			return false
		}
	}
	delete(p.usbRequests, response.Request)
	pending.result <- authorization
	return true
}

// RunUSBRevocations observes administrator CLI revocation and reconnects without
// persisting USB credentials or requiring a live HTTP request from the old client.
func (s *Server) RunUSBRevocations(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.syncUSBRevocations(ctx)
		}
	}
}

func (s *Server) syncUSBRevocations(ctx context.Context) {
	s.mu.Lock()
	peers := make(map[string]*peer)
	modules := []string{}
	for id, p := range s.peers {
		if p.usbLocal && p.ctx.Err() == nil {
			peers[id] = p
			modules = append(modules, id)
		}
	}
	s.mu.Unlock()
	if len(modules) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	rows, err := s.db.Query(ctx, `SELECT m.id,c.id FROM modules m JOIN clients c ON c.user_id=m.user_id
 WHERE m.id=ANY($1::uuid[]) AND (c.module_id IS NULL OR c.module_id=m.id)
 AND (m.revoked OR NOT (`+sessionAuthorization+`))`, modules)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var module, client string
		if rows.Scan(&module, &client) != nil {
			return
		}
		s.mu.Lock()
		if p := peers[module]; s.peers[module] == p {
			s.revokeUSB(p, client)
		}
		s.mu.Unlock()
	}
}

// Called with s.mu held. Reconnecting peers receive revocations again.
func (s *Server) revokeUSB(p *peer, client string) {
	if p == nil || !p.usbLocal || p.ctx.Err() != nil || p.usbRevoked[client] {
		return
	}
	if len(p.queue) == cap(p.queue) {
		return
	}
	if !s.enqueue(p, "usb_revoke", map[string]string{"client_installation_id": client}) {
		return
	}
	if p.usbRevoked == nil {
		p.usbRevoked = map[string]bool{}
	}
	p.usbRevoked[client] = true
	for id, pending := range p.usbRequests {
		if pending.client == client {
			delete(p.usbRequests, id)
			pending.result <- nil
		}
	}
}
