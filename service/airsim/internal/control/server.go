package control

import (
	"airsim.local/server/internal/media"
	"airsim.local/server/internal/store"
	"airsim.local/server/internal/wire"
	"context"
	"crypto/ed25519"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/coder/websocket"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Server, API, Device, Media, EdgeToken, MediaToken, HMAC, MediaInternal string
	Roots                                                                  *x509.CertPool
}
type peer struct {
	queried                      bool
	conn                         *websocket.Conn
	module, epoch, boot, backend string
	ctx                          context.Context
	cancel                       context.CancelFunc
	queue                        chan Envelope
	last                         time.Time
	snapshot                     *Snapshot
	messages                     Messages
}
type Server struct {
	mediaJobs  chan *mediaSession
	mediaOwner func(context.Context, media.Spec) (bool, error)
	mediaHTTP  *http.Client
	db         *store.Store
	cfg        Config
	mu         sync.Mutex
	peers      map[string]*peer
	last       map[string]*peer
	sessions   map[string]*mediaSession
}

func New(db *store.Store, cfg Config) *Server {
	return &Server{mediaJobs: make(chan *mediaSession, 32), mediaOwner: func(ctx context.Context, spec media.Spec) (bool, error) {
		var owned bool
		e := db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM reservations r JOIN clients c ON c.id=r.client_id WHERE r.module_id=$1 AND r.client_id=$2 AND r.generation=$3 AND NOT c.revoked AND c.expires_at>now())", spec.Module, spec.Client, spec.Generation).Scan(&owned)
		return owned, e
	}, mediaHTTP: &http.Client{Timeout: time.Second, Transport: &http.Transport{Proxy: nil, MaxIdleConns: 4, MaxIdleConnsPerHost: 4, MaxConnsPerHost: 4, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: time.Second}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, db: db, cfg: cfg, peers: map[string]*peer{}, last: map[string]*peer{}, sessions: map[string]*mediaSession{}}
}
func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { wire.JSON(w, 200, map[string]bool{"alive": true}) })
	m.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if s.db.Ready(ctx) != nil {
			wire.Error(w, 503, "not_ready")
			return
		}
		wire.JSON(w, 200, map[string]bool{"ready": true})
	})
	m.HandleFunc("GET /.well-known/airsim", s.discovery)
	m.HandleFunc("GET /v2/device/control", s.device)
	m.HandleFunc("/v2/modules", s.client)
	m.HandleFunc("/v2/modules/", s.client)
	return m
}
func (s *Server) discovery(w http.ResponseWriter, r *http.Request) {
	wire.JSON(w, 200, map[string]any{"protocol_version": 2, "profile": "airsim-v2-r4.1", "server_id": s.cfg.Server, "api_origin": s.cfg.API, "device_origin": s.cfg.Device, "media_origin": s.cfg.Media, "capabilities": map[string]bool{"controlled_test_client": true, "telephony": true, "messaging": true, "experimental_audio": true, "apns": false, "interactive_login": false}})
}
func (s *Server) authenticateDevice(r *http.Request) (string, time.Time, error) {
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-AirSIM-Edge-Token")), []byte(s.cfg.EdgeToken)) != 1 {
		return "", time.Time{}, errors.New("unauthorized")
	}
	der, e := base64.StdEncoding.Strict().DecodeString(r.Header.Get("X-AirSIM-Client-Cert"))
	if e != nil {
		return "", time.Time{}, e
	}
	cert, e := x509.ParseCertificate(der)
	if e != nil {
		return "", time.Time{}, e
	}
	if _, e = cert.Verify(x509.VerifyOptions{Roots: s.cfg.Roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); e != nil {
		return "", time.Time{}, e
	}
	prefix := "urn:airsim:" + s.cfg.Server + ":module:"
	if len(cert.URIs) != 1 || !strings.HasPrefix(cert.URIs[0].String(), prefix) || len(cert.ExtKeyUsage) != 1 || cert.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth {
		return "", time.Time{}, wire.ErrInvalid
	}
	module := strings.TrimPrefix(cert.URIs[0].String(), prefix)
	if !wire.UUID.MatchString(module) {
		return "", time.Time{}, wire.ErrInvalid
	}
	var pub []byte
	var serial string
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	e = s.db.QueryRow(ctx, "SELECT public_key,serial FROM modules WHERE id=$1 AND server_id=$2 AND NOT revoked", module, s.cfg.Server).Scan(&pub, &serial)
	key, ok := cert.PublicKey.(ed25519.PublicKey)
	if e != nil || !ok || string(pub) != string(key) || serial != cert.SerialNumber.String() {
		return "", time.Time{}, wire.ErrInvalid
	}
	return module, cert.NotAfter, nil
}
func (s *Server) device(w http.ResponseWriter, r *http.Request) {
	module, certificateExpiry, e := s.authenticateDevice(r)
	if e != nil {
		wire.Error(w, 401, "unauthorized")
		return
	}
	c, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.control.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		return
	}
	defer c.CloseNow()
	if c.Subprotocol() != "airsim.control.v2" {
		return
	}
	c.SetReadLimit(131072)
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	typ, b, e := c.Read(ctx)
	cancel()
	var env Envelope
	var hello struct {
		Boot    string `json:"agent_boot_id"`
		Backend string `json:"backend_epoch"`
		Version string `json:"agent_version"`
	}
	if e != nil || typ != websocket.MessageText || wire.Decode(b, &env, "type", "protocol_version", "module_id", "connection_epoch", "sequence", "payload") != nil || env.Type != "hello" || env.Version != 2 || env.Module != module || env.Epoch != "" || env.Sequence != 1 || wire.Decode(env.Payload, &hello, "agent_boot_id", "backend_epoch", "agent_version") != nil || !wire.UUID.MatchString(hello.Boot) || (hello.Backend != "" && !wire.UUID.MatchString(hello.Backend)) {
		return
	}
	ctx, cancel = context.WithDeadline(r.Context(), certificateExpiry)
	defer cancel()
	p := &peer{conn: c, module: module, epoch: wire.ID(), boot: hello.Boot, backend: hello.Backend, ctx: ctx, cancel: cancel, queue: make(chan Envelope, 32), last: time.Now()}
	s.mu.Lock()
	if old := s.peers[module]; old != nil {
		for _, m := range s.sessions {
			if m.Spec.Module == module && !m.Closed {
				s.stopMedia(ctx, m, "connection_replaced")
			}
		}
		old.cancel()
		old.conn.CloseNow()
	}
	s.peers[module] = p
	s.last[module] = p
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.peers[module] == p {
			delete(s.peers, module)
			for _, m := range s.sessions {
				if m.Spec.Module == module && m.Spec.Connection == p.epoch {
					s.stopMedia(context.Background(), m, "control_closed")
				}
			}
		}
		s.mu.Unlock()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = s.db.Exec(ctx, "UPDATE commands SET state='outcome_unknown' WHERE module_id=$1 AND connection_epoch=$2 AND state IN ('pending','dispatched')", module, p.epoch)
	}()
	done := make(chan struct{})
	go func() {
		defer close(done)
		seq := uint64(0)
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			var msg Envelope
			select {
			case <-ctx.Done():
				return
			case msg = <-p.queue:
			case <-ticker.C:
				msg = Envelope{Type: "heartbeat", Payload: json.RawMessage(`{}`)}
			}
			seq++
			msg.Version = 2
			msg.Module = module
			msg.Epoch = p.epoch
			msg.Sequence = seq
			b, _ := json.Marshal(msg)
			wc, cc := context.WithTimeout(ctx, 3*time.Second)
			err := c.Write(wc, websocket.MessageText, b)
			cc()
			if err != nil {
				cancel()
				return
			}
		}
	}()
	defer func() { cancel(); <-done }()
	s.enqueue(p, "welcome", map[string]any{"server_id": s.cfg.Server, "heartbeat_seconds": 5})
	seq := uint64(1)
	for {
		rc, cc := context.WithTimeout(ctx, 15*time.Second)
		typ, b, e = c.Read(rc)
		cc()
		if e != nil {
			return
		}
		if typ != websocket.MessageText || wire.Decode(b, &env, "type", "protocol_version", "module_id", "connection_epoch", "sequence", "payload") != nil || env.Module != module || env.Epoch != p.epoch || env.Version != 2 || env.Sequence != seq+1 {
			return
		}
		seq++
		s.mu.Lock()
		if s.peers[module] != p {
			s.mu.Unlock()
			return
		}
		valid := s.consume(p, env)
		if valid {
			p.last = time.Now()
		}
		s.mu.Unlock()
		if !valid {
			return
		}
	}
}
func (s *Server) enqueue(p *peer, kind string, payload any) bool {
	b, e := json.Marshal(payload)
	if e != nil {
		return false
	}
	select {
	case p.queue <- Envelope{Type: kind, Payload: b}:
		return true
	default:
		p.cancel()
		return false
	}
}
func (s *Server) consume(p *peer, env Envelope) bool {
	switch env.Type {
	case "receipt":
		return s.receipt(p, env.Payload)
	case "media_status":
		var v struct {
			ID     string `json:"session_id"`
			State  string `json:"state"`
			Reason string `json:"reason"`
		}
		if wire.Decode(env.Payload, &v, "session_id", "state", "reason") != nil {
			return false
		}
		if v.State != "starting" && v.State != "streaming" && v.State != "closed" {
			return false
		}
		if v.State == "closed" {
			for _, m := range s.sessions {
				if m.Spec.ID == v.ID && m.Spec.Module == p.module && m.Spec.Connection == p.epoch {
					s.stopMedia(p.ctx, m, "agent_closed")
				}
			}
		}
		return true
	case "heartbeat":
		var v struct{}
		return wire.Decode(env.Payload, &v) == nil
	case "snapshot":
		var snap Snapshot
		if wire.Decode(env.Payload, &snap, "agent_boot_id", "backend_epoch", "observed_at", "control", "calls", "audio") != nil || snap.Control.Schema != 1 || snap.Boot != p.boot || snap.Control.Boot != snap.Boot || snap.Calls.Boot != snap.Boot || snap.Control.Backend != snap.Backend || snap.Calls.Backend != snap.Backend {
			return false
		}
		if p.backend != snap.Backend {
			p.messages = Messages{Gap: true, Messages: []Message{}}
		}
		var audio AudioStatus
		if wire.Decode(snap.Audio, &audio, "available", "implementation", "verification", "voice_ready", "reason") != nil {
			return false
		}
		p.backend = snap.Backend
		p.snapshot = &snap
		s.releaseDisconnected(p)
		if !p.queried {
			p.queried = true
			s.queryReceipts(p)
		}
		return true
	case "messages":
		var msg Messages
		if len(env.Payload) > 65536 || wire.Decode(env.Payload, &msg, "agent_boot_id", "backend_epoch", "observed_at", "inbox_gap", "inbox_dropped", "messages") != nil || msg.Boot != p.boot || msg.Backend != p.backend || len(msg.Messages) > 32 {
			return false
		}
		if p.messages.Boot != msg.Boot || p.messages.Backend != msg.Backend {
			p.messages = Messages{Boot: msg.Boot, Backend: msg.Backend, Gap: true, Messages: []Message{}}
		}
		p.messages.Gap = p.messages.Gap || msg.Gap
		p.messages.Dropped = msg.Dropped
		p.messages.Observed = msg.Observed
		for _, m := range msg.Messages {
			found := false
			for i, old := range p.messages.Messages {
				if old.ID == m.ID {
					p.messages.Messages[i] = m
					found = true
					break
				}
			}
			if !found {
				p.messages.Messages = append(p.messages.Messages, m)
			}
		}
		for {
			b, _ := json.Marshal(p.messages.Messages)
			if len(p.messages.Messages) <= 128 && len(b) <= 1<<20 {
				break
			}
			p.messages.Messages = p.messages.Messages[1:]
			p.messages.Gap = true
			p.messages.Dropped++
		}
		return true
	default:
		return false
	}
}
func Secret(path string) (string, error) {
	b, e := os.ReadFile(path)
	if e != nil {
		return "", e
	}
	v := strings.TrimSpace(string(b))
	if !wire.Hex.MatchString(v) {
		return "", wire.ErrInvalid
	}
	return v, nil
}
