package cloud

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/media"
	"github.com/coder/websocket"
)

type USBAuthorization struct {
	Server      string `json:"server_id"`
	Module      string `json:"module_id"`
	Client      string `json:"client_installation_id"`
	Origin      string `json:"api_origin"`
	Certificate string `json:"certificate_der_base64"`
	Token       string `json:"token"`
	Expires     string `json:"expires_at"`
}
type usbGrant struct {
	Token   string `json:"token"`
	Expires string `json:"expires_at"`
}
type usbRecord struct {
	Request            control.Request
	Client, Generation string
}
type usbMedia struct {
	Client, Call, Generation, Request, Ticket, ID string
	Expires                                       time.Time
	Used                                          bool
	Cancel                                        context.CancelFunc
}
type USB struct {
	agent                        *Agent
	mu                           sync.Mutex
	address, origin, epoch, path string
	certificate                  tls.Certificate
	nonces                       map[string]time.Time
	grants                       map[string]usbGrant
	records                      map[string]usbRecord
	sessions                     map[string]*usbMedia
}

// ConfigureUSB is called before Run. Only a specific private USB address is accepted.
func (a *Agent) ConfigureUSB(address, directory string) error {
	if address == "" {
		return nil
	}
	host, port, err := net.SplitHostPort(address)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || ip.To4() == nil || !ip.IsPrivate() || port == "0" {
		return errConfig
	}
	if _, err = net.ResolveTCPAddr("tcp4", address); err != nil {
		return errConfig
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	path := filepath.Join(directory, "usb-tls.pem")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		private, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if e != nil {
			return e
		}
		serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if e != nil {
			return e
		}
		now := time.Now()
		template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: a.P.id.ModuleID}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(10, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IPAddresses: []net.IP{ip}}
		der, e := x509.CreateCertificate(rand.Reader, template, template, &private.PublicKey, private)
		if e != nil {
			return e
		}
		key, e := x509.MarshalPKCS8PrivateKey(private)
		if e != nil {
			return e
		}
		data = append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...)
		if err = usbSave(path, data); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	cert, err := tls.X509KeyPair(data, data)
	if err != nil {
		return errConfig
	}
	epoch, err := identity.UUID()
	if err != nil {
		return err
	}
	u := &USB{agent: a, address: address, origin: "https://" + address, epoch: epoch, path: filepath.Join(directory, "usb-grants.json"), certificate: cert, nonces: map[string]time.Time{}, grants: map[string]usbGrant{}, records: map[string]usbRecord{}, sessions: map[string]*usbMedia{}}
	if b, e := os.ReadFile(u.path); e == nil {
		if len(b) > 16384 || json.Unmarshal(b, &u.grants) != nil {
			return errConfig
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	if b, e := os.ReadFile(filepath.Join(directory, "usb-commands.json")); e == nil {
		if len(b) > 512*1024 || json.Unmarshal(b, &u.records) != nil {
			return errConfig
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	if a.entries == nil {
		a.entries = map[string]commandEntry{}
	}
	for id, record := range u.records {
		a.entries[id] = commandEntry{record.Client, "usb"}
	}
	a.USB = u
	return nil
}
func usbSave(path string, b []byte) error {
	f, e := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	if _, e = f.Write(b); e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	return os.Rename(path+".tmp", path)
}
func usbToken() (string, error) {
	b := make([]byte, 32)
	_, e := rand.Read(b)
	return hex.EncodeToString(b), e
}
func (u *USB) authorize(client, expires string) (*USBAuthorization, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	now := time.Now()
	expiry, e := utc(expires)
	if !control.ValidID(client) || e != nil || !expiry.After(now) || expiry.Sub(now) > 24*time.Hour+5*time.Second {
		return nil, errConfig
	}
	for id, g := range u.grants {
		t, e := utc(g.Expires)
		if e != nil || !t.After(now) {
			delete(u.grants, id)
		}
	}
	g, ok := u.grants[client]
	if !ok {
		g.Token, e = usbToken()
		if e != nil {
			return nil, e
		}
	}
	oldGrants := u.grants
	g.Expires = expires
	u.grants = map[string]usbGrant{client: g}
	b, e := json.Marshal(u.grants)
	if e == nil {
		e = usbSave(u.path, b)
	}
	if e != nil {
		u.grants = oldGrants
		return nil, e
	}
	for _, m := range u.sessions {
		if m.Client != client && m.Cancel != nil {
			m.Cancel()
		}
	}
	s := u.agent.P.View()
	return &USBAuthorization{s.ServerID, u.agent.P.id.ModuleID, client, u.origin, base64.StdEncoding.EncodeToString(u.certificate.Certificate[0]), g.Token, expires}, nil
}
func (u *USB) Serve(ctx context.Context) {
	for ctx.Err() == nil {
		l, e := net.Listen("tcp4", u.address)
		if e != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
				continue
			}
		}
		server := &http.Server{Handler: u, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
		watch, watchCancel := context.WithCancel(ctx)
		go func() {
			tick := time.NewTicker(time.Second)
			defer tick.Stop()
			for {
				select {
				case <-watch.Done():
					return
				case <-tick.C:
					if !u.addressPresent() {
						server.Close()
						u.closeMedia()
						return
					}
				}
			}
		}()
		stop := context.AfterFunc(ctx, func() { server.Close(); u.closeMedia() })
		_ = server.Serve(tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{u.certificate}, MinVersion: tls.VersionTLS12}))
		stop()
		watchCancel()
		l.Close()
	}
}
func (u *USB) addressPresent() bool {
	host, _, _ := net.SplitHostPort(u.address)
	addrs, e := net.InterfaceAddrs()
	if e != nil {
		return false
	}
	for _, addr := range addrs {
		ip, _, e := net.ParseCIDR(addr.String())
		if e == nil && ip.String() == host {
			return true
		}
	}
	return false
}
func (u *USB) closeMedia() {
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, m := range u.sessions {
		if m.Cancel != nil {
			m.Cancel()
		}
	}
}
func (u *USB) client(r *http.Request) string {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !hex32(token) {
		return ""
	}
	stamp, nonce, signature := r.Header.Get("X-AirSIM-Timestamp"), r.Header.Get("X-AirSIM-Nonce"), r.Header.Get("X-AirSIM-Signature")
	seconds, e := strconv.ParseInt(stamp, 10, 64)
	if e != nil || !hex32(nonce) || !hex32(signature) {
		return ""
	}
	now := time.Now()
	delta := now.Unix() - seconds
	if delta < -30 || delta > 30 {
		return ""
	}
	body, e := io.ReadAll(io.LimitReader(r.Body, 8193))
	if e != nil || len(body) > 8192 {
		return ""
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	key, _ := hex.DecodeString(token)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(stamp + "\n" + nonce + "\n" + r.Method + "\n" + r.URL.RequestURI() + "\n"))
	_, _ = mac.Write(body)
	supplied, _ := hex.DecodeString(signature)
	if !hmac.Equal(mac.Sum(nil), supplied) {
		return ""
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	for n, expiry := range u.nonces {
		if !now.Before(expiry) {
			delete(u.nonces, n)
		}
	}
	if _, seen := u.nonces[nonce]; seen || len(u.nonces) >= 4096 {
		return ""
	}
	for id, g := range u.grants {
		expiry, e := utc(g.Expires)
		if e == nil && now.Before(expiry) && subtle.ConstantTimeCompare([]byte(token), []byte(g.Token)) == 1 {
			u.nonces[nonce] = now.Add(61 * time.Second)
			return id
		}
	}
	return ""
}
func usbJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}
func usbBody(w http.ResponseWriter, r *http.Request, out any, keys string) bool {
	b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 8192))
	return e == nil && exact(b, keys, out) == nil
}
func (u *USB) snapshot(ctx context.Context) (map[string]any, error) {
	first, e := u.agent.controlView(ctx)
	if e != nil {
		return nil, e
	}
	raw, code := u.agent.view(ctx, "calls", "")
	calls, ok := raw.(control.CallsView)
	if !ok || code != 200 {
		return nil, errConfig
	}
	second, e := u.agent.controlView(ctx)
	if e != nil || first.Boot != second.Boot || first.Epoch != second.Epoch || calls.Boot != second.Boot || calls.Epoch != second.Epoch {
		return nil, errConfig
	}
	audio := u.agent.Media.View()
	if audio.Session != nil && (audio.Session.Boot != second.Boot || audio.Session.Epoch != second.Epoch) {
		audio.Session = nil
	}
	return map[string]any{"agent_boot_id": second.Boot, "backend_epoch": second.Epoch, "observed_at": time.Now().UTC(), "control": second, "calls": calls, "audio": audio, "signal": u.agent.signalView()}, nil
}
func (u *USB) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/v2/media" {
		u.mediaSocket(w, r)
		return
	}
	client := u.client(r)
	if client == "" {
		usbJSON(w, 401, nil)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	module := u.agent.P.id.ModuleID
	server := u.agent.P.View().ServerID
	if r.URL.Path == "/v2/modules" && r.Method == "GET" {
		s, e := u.agent.controlView(ctx)
		if e != nil {
			usbJSON(w, 503, nil)
			return
		}
		usbJSON(w, 200, map[string]any{"server_id": server, "modules": []any{map[string]any{"module_id": module, "online": true, "last_seen": time.Now().UTC(), "agent_boot_id": s.Boot, "backend_epoch": s.Epoch, "connection_epoch": u.epoch, "signal": u.agent.signalView()}}})
		return
	}
	prefix := "/v2/modules/" + module + "/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		usbJSON(w, 404, nil)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, prefix), "/")
	if len(parts) >= 3 && parts[0] == "calls" && parts[2] == "media-sessions" {
		u.mediaAPI(w, r, client, parts)
		return
	}
	if len(parts) == 1 && r.Method == "GET" {
		switch parts[0] {
		case "snapshot":
			snap, e := u.snapshot(ctx)
			if e != nil {
				usbJSON(w, 503, nil)
				return
			}
			usbJSON(w, 200, map[string]any{"server_id": server, "module_id": module, "online": true, "last_seen": time.Now().UTC(), "connection_epoch": u.epoch, "snapshot": snap})
			return
		case "messages":
			raw, code := u.agent.view(ctx, "cloud_messages", "")
			m, ok := raw.(control.MessagesView)
			if !ok || code != 200 {
				usbJSON(w, 503, nil)
				return
			}
			usbJSON(w, 200, map[string]any{"server_id": server, "module_id": module, "agent_boot_id": m.Boot, "backend_epoch": m.Epoch, "online": true, "inbox_gap": m.Gap, "inbox_dropped": m.Dropped, "messages": m.Messages})
			return
		}
	}
	if len(parts) == 1 && parts[0] == "commands" && r.Method == "POST" {
		u.command(w, r, client)
		return
	}
	if len(parts) == 2 && parts[0] == "commands" && r.Method == "GET" {
		u.receipt(w, r, client, parts[1])
		return
	}
	usbJSON(w, 404, nil)
}
func (u *USB) record(ctx context.Context, rec usbRecord) (any, int) {
	value, code := u.agent.view(ctx, "command", rec.Request.CommandID)
	if code != 200 {
		if code == 404 {
			return map[string]any{"command_id": rec.Request.CommandID, "state": "outcome_unknown", "generation": rec.Generation, "receipt": nil}, 200
		}
		return nil, code
	}
	b, _ := json.Marshal(value)
	var state struct {
		State string `json:"state"`
		Call  string `json:"call_id"`
	}
	_ = json.Unmarshal(b, &state)
	u.agent.updateClaim(rec.Request, state.State, state.Call)
	if (state.State == "accepted" || state.State == "observed") && control.ValidID(state.Call) && (rec.Request.Action == "call.dial" || rec.Request.Action == "call.answer") {
		u.agent.ownerMu.Lock()
		u.agent.owners[state.Call] = owner{state.Call, rec.Client, rec.Generation, rec.Request.BootID, rec.Request.Epoch}
		u.agent.ownerMu.Unlock()
	}
	serverState := "completed"
	if state.State == "prepared" {
		serverState = "pending"
	}
	if state.State == "dispatched" {
		serverState = "dispatched"
	}
	if state.State == "outcome_unknown" {
		serverState = "outcome_unknown"
	}
	return map[string]any{"command_id": rec.Request.CommandID, "state": serverState, "generation": rec.Generation, "receipt": value}, 200
}
func (u *USB) command(w http.ResponseWriter, r *http.Request, client string) {
	var b struct {
		Epoch   string          `json:"connection_epoch"`
		Command json.RawMessage `json:"command"`
	}
	if !usbBody(w, r, &b, "connection_epoch,command") {
		usbJSON(w, 400, nil)
		return
	}
	req, e := control.Parse(b.Command)
	if e != nil {
		usbJSON(w, 400, nil)
		return
	}
	if b.Epoch != u.epoch {
		usbJSON(w, 409, nil)
		return
	}
	u.mu.Lock()
	old, exists := u.records[req.CommandID]
	if exists {
		u.mu.Unlock()
		if old.Client != client {
			usbJSON(w, 409, nil)
			return
		}
		if !u.agent.reserveCommand(r.Context(), req, client, "usb") {
			usbJSON(w, 409, nil)
			return
		}
		_, code := u.agent.Control.Submit(r.Context(), req)
		if code != 200 && code != 202 {
			usbJSON(w, code, nil)
			return
		}
		v, code := u.record(r.Context(), old)
		usbJSON(w, code, v)
		return
	}
	if len(u.records) >= 1024 {
		u.mu.Unlock()
		usbJSON(w, 429, nil)
		return
	}
	generation, e := identity.UUID()
	if e != nil {
		u.mu.Unlock()
		usbJSON(w, 503, nil)
		return
	}
	rec := usbRecord{req, client, generation}
	u.records[req.CommandID] = rec
	encoded, saveErr := json.Marshal(u.records)
	if saveErr == nil {
		saveErr = usbSave(filepath.Join(filepath.Dir(u.path), "usb-commands.json"), encoded)
	}
	if saveErr != nil {
		delete(u.records, req.CommandID)
		u.mu.Unlock()
		usbJSON(w, 503, nil)
		return
	}
	u.mu.Unlock()
	if !u.agent.reserveCommand(r.Context(), req, client, "usb") {
		u.mu.Lock()
		delete(u.records, req.CommandID)
		u.mu.Unlock()
		usbJSON(w, 409, nil)
		return
	}
	value, code := u.agent.Control.Submit(r.Context(), req)
	if code != 202 && code != 200 {
		u.agent.rejectClaim(req, code)
		usbJSON(w, code, nil)
		return
	}
	_ = value
	v, code := u.record(r.Context(), rec)
	usbJSON(w, code, v)
}
func (u *USB) receipt(w http.ResponseWriter, r *http.Request, client, id string) {
	u.mu.Lock()
	rec, ok := u.records[id]
	u.mu.Unlock()
	if !ok || rec.Client != client {
		usbJSON(w, 404, nil)
		return
	}
	v, code := u.record(r.Context(), rec)
	usbJSON(w, code, v)
}

func (u *USB) mediaAPI(w http.ResponseWriter, r *http.Request, client string, parts []string) {
	if !control.ValidID(parts[1]) {
		usbJSON(w, 404, nil)
		return
	}
	if len(parts) == 4 && r.Method == "DELETE" {
		u.mu.Lock()
		m := u.sessions[parts[3]]
		if m == nil || m.Client != client || m.Call != parts[1] {
			u.mu.Unlock()
			usbJSON(w, 404, nil)
			return
		}
		m.Used = true
		if m.Cancel != nil {
			m.Cancel()
		}
		u.mu.Unlock()
		usbJSON(w, 204, nil)
		return
	}
	if len(parts) != 3 || r.Method != "POST" {
		usbJSON(w, 404, nil)
		return
	}
	var b struct {
		Codec      string `json:"codec"`
		Request    string `json:"request_id"`
		Epoch      string `json:"connection_epoch"`
		Generation string `json:"generation"`
	}
	if !usbBody(w, r, &b, "request_id,connection_epoch,generation,codec") || b.Codec != "lc3" || !control.ValidID(b.Request) || !control.ValidID(b.Generation) {
		usbJSON(w, 400, nil)
		return
	}
	if b.Epoch != u.epoch {
		usbJSON(w, 409, nil)
		return
	}
	u.agent.ownerMu.Lock()
	o, ok := u.agent.owners[parts[1]]
	claim := u.agent.claim
	owned := ok && o.client == client && o.generation == b.Generation && claim != nil && claim.route == "usb" && claim.client == client
	u.agent.ownerMu.Unlock()
	if !owned {
		usbJSON(w, 409, nil)
		return
	}
	raw, code := u.agent.view(r.Context(), "calls", "")
	calls, ok := raw.(control.CallsView)
	active := false
	if code == 200 && ok && calls.Boot == o.boot && calls.Epoch == o.epoch {
		for _, c := range calls.Calls {
			if c.ID == parts[1] && c.State == "active" {
				active = true
			}
		}
	}
	if !active {
		usbJSON(w, 409, nil)
		return
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, old := range u.sessions {
		if old.Request == b.Request {
			if old.Client != client || old.Call != parts[1] || old.Generation != b.Generation {
				usbJSON(w, 409, nil)
				return
			}
			if old.Used || !time.Now().Before(old.Expires) {
				usbJSON(w, 410, nil)
				return
			}
			u.mediaResult(w, 200, old)
			return
		}
	}
	for id, m := range u.sessions {
		if m.Cancel == nil && !time.Now().Before(m.Expires) {
			delete(u.sessions, id)
		}
	}
	if len(u.sessions) >= 32 {
		usbJSON(w, 429, nil)
		return
	}
	id, e := identity.UUID()
	if e != nil {
		usbJSON(w, 503, nil)
		return
	}
	ticket, e := usbToken()
	if e != nil {
		usbJSON(w, 503, nil)
		return
	}
	m := &usbMedia{Client: client, Call: parts[1], Generation: b.Generation, Request: b.Request, Ticket: ticket, ID: id, Expires: time.Now().Add(30 * time.Second)}
	u.sessions[id] = m
	u.mediaResult(w, 201, m)
}
func (u *USB) mediaResult(w http.ResponseWriter, code int, m *usbMedia) {
	usbJSON(w, code, map[string]any{"session_id": m.ID, "ticket": m.Ticket, "expires_at": m.Expires.UTC(), "media_url": "wss" + strings.TrimPrefix(u.origin, "https") + "/v2/media", "format": media.LC3Format})
}
func (u *USB) mediaSocket(w http.ResponseWriter, r *http.Request) {
	ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		return
	}
	defer ws.CloseNow()
	if ws.Subprotocol() != "airsim.media.v2" {
		return
	}
	ws.SetReadLimit(2048)
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	setup, done := context.WithTimeout(ctx, 5*time.Second)
	defer done()
	typ, b, e := ws.Read(setup)
	if e != nil || typ != websocket.MessageText {
		return
	}
	var auth struct {
		ID     string `json:"session_id"`
		Role   string `json:"role"`
		Ticket string `json:"ticket"`
	}
	if exact(b, "session_id,role,ticket", &auth) != nil || auth.Role != "client" || !hex32(auth.Ticket) {
		return
	}
	u.mu.Lock()
	m := u.sessions[auth.ID]
	if m == nil || m.Used || !time.Now().Before(m.Expires) || subtle.ConstantTimeCompare([]byte(auth.Ticket), []byte(m.Ticket)) != 1 {
		u.mu.Unlock()
		return
	}
	grant := u.grants[m.Client]
	expires, e := utc(grant.Expires)
	if e != nil || !time.Now().Before(expires) {
		u.mu.Unlock()
		return
	}
	authorized, authCancel := context.WithDeadline(ctx, expires)
	defer authCancel()
	ctx = authorized
	setup, setupCancel := context.WithTimeout(ctx, 5*time.Second)
	defer setupCancel()
	m.Used = true
	m.Cancel = cancel
	u.mu.Unlock()
	defer func() { u.mu.Lock(); m.Cancel = nil; u.mu.Unlock() }()
	u.agent.ownerMu.Lock()
	o, ok := u.agent.owners[m.Call]
	claim := u.agent.claim
	owned := ok && o.client == m.Client && o.generation == m.Generation && claim != nil && claim.route == "usb"
	u.agent.ownerMu.Unlock()
	if !owned {
		return
	}
	waiting, _ := json.Marshal(map[string]string{"type": "waiting", "session_id": m.ID})
	if ws.Write(setup, websocket.MessageText, waiting) != nil {
		return
	}
	local, code := u.agent.Media.Create(setup, media.Request{RequestID: m.Request, Boot: o.boot, Epoch: o.epoch, CallID: m.Call})
	if code != 200 && code != 201 {
		return
	}
	defer u.agent.Media.Stop(local.ID)
	conn, e := (&net.Dialer{}).DialContext(setup, "unix", local.Socket)
	if e != nil {
		return
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close(); ws.CloseNow() })
	defer stop()
	deadline, _ := setup.Deadline()
	_ = conn.SetDeadline(deadline)
	if media.WriteJSON(conn, map[string]string{"session_id": local.ID, "token": local.Token}, 1024) != nil {
		return
	}
	b, e = media.ReadJSON(conn, 1024)
	if e != nil {
		return
	}
	var ack struct {
		OK bool `json:"ok"`
		media.Format
	}
	if exact(b, "ok,codec,sample_rate,channels,sample_format,frame_samples,codec_frame_us,codec_frame_bytes", &ack) != nil || !ack.OK || ack.Format != media.LC3Format {
		return
	}
	_ = conn.SetDeadline(time.Time{})
	b, _ = json.Marshal(map[string]any{"type": "paired", "session_id": m.ID, "format": local.Format})
	if ws.Write(setup, websocket.MessageText, b) != nil {
		return
	}
	bridgeFrames(ctx, cancel, ws, conn, local.ID, m.ID, &bridgeCounters{})
}

func (u *USB) revoke(client string) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	old := u.grants
	next := map[string]usbGrant{}
	for id, g := range old {
		if id != client {
			next[id] = g
		}
	}
	b, e := json.Marshal(next)
	if e == nil {
		e = usbSave(u.path, b)
	}
	if e != nil {
		return e
	}
	u.grants = next
	for _, m := range u.sessions {
		if m.Client == client && m.Cancel != nil {
			m.Cancel()
		}
	}
	return nil
}

type usbCommandMetadata struct {
	ID         string `json:"command_id"`
	Boot       string `json:"agent_boot_id"`
	Epoch      string `json:"backend_epoch"`
	Action     string `json:"action"`
	Client     string `json:"client_installation_id"`
	Generation string `json:"generation"`
}

func (r usbRecord) MarshalJSON() ([]byte, error) {
	return json.Marshal(usbCommandMetadata{r.Request.CommandID, r.Request.BootID, r.Request.Epoch, r.Request.Action, r.Client, r.Generation})
}
func (r *usbRecord) UnmarshalJSON(b []byte) error {
	var m usbCommandMetadata
	if exact(b, "command_id,agent_boot_id,backend_epoch,action,client_installation_id,generation", &m) != nil {
		return errConfig
	}
	for _, id := range []string{m.ID, m.Boot, m.Epoch, m.Client, m.Generation} {
		if !control.ValidID(id) {
			return errConfig
		}
	}
	r.Request = control.Request{CommandID: m.ID, BootID: m.Boot, Epoch: m.Epoch, Action: m.Action}
	r.Client = m.Client
	r.Generation = m.Generation
	return nil
}
