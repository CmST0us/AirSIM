package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/state"
	"context"
	"crypto/rand"
	"encoding/json"
	"github.com/coder/websocket"
	"io"
	"log"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"
)

type Controller interface {
	Submit(context.Context, control.Request) (any, int)
	View(context.Context, string, string) (any, int)
}
type Media interface {
	Create(context.Context, media.Request) (media.Created, int)
	View() media.Status
	Stop(string) int
}
type Agent struct {
	Signal interface {
		Signal(time.Time) state.SignalView
	}
	USB            *USB
	ownerMu        sync.Mutex
	claim          *callClaim
	entries        map[string]commandEntry
	P              *Provisioner
	Control        Controller
	Media          Media
	Boot, Version  string
	statsMu        sync.Mutex
	lastBridge     BridgeStats
	activeCounters *bridgeCounters
	bridgeMu       sync.Mutex
	bridge         *bridge
	media          sync.WaitGroup
	owners         map[string]owner
	bindings       map[string]string
	// RenewWindow overrides when automatic online certificate renewal starts.
	// Zero defaults to defaultCertRenewWindow (7 days).
	RenewWindow time.Duration
}
type envelope struct {
	Type     string          `json:"type"`
	Protocol int             `json:"protocol_version"`
	Module   string          `json:"module_id"`
	Epoch    string          `json:"connection_epoch"`
	Sequence uint64          `json:"sequence"`
	Payload  json.RawMessage `json:"payload"`
}
type outgoing struct {
	kind    string
	payload any
}
type owner struct{ call, client, generation, boot, epoch string }
type pendingReceipt struct {
	request            control.Request
	client, generation string
	last               string
	authorized         bool
	acceptedUntil      time.Time
}
type connection struct {
	agent  *Agent
	config *saved
	// life outlasts the connection and bounds the media sessions it starts.
	life    context.Context
	ctx     context.Context
	cancel  context.CancelFunc
	ws      *websocket.Conn
	queue   chan outgoing
	epoch   string
	seq     uint64
	pending map[string]*pendingReceipt
	owners  map[string]owner
	wg      sync.WaitGroup
	renewed bool
}

// Each connection attempt is short: after a cellular outage the next attempt
// starts soon after the network returns instead of waiting out a stalled one.
const (
	discoveryTimeout        = 10 * time.Second
	controlHandshakeTimeout = 10 * time.Second
	defaultCertRenewWindow  = 7 * 24 * time.Hour
	certRenewCheckInterval  = time.Hour
)

func (a *Agent) status(connected bool, epoch, code string) {
	a.P.mu.Lock()
	defer a.P.mu.Unlock()
	a.P.status.Connected = connected
	a.P.status.Epoch = epoch
	a.P.status.LastError = code
	if connected {
		n := time.Now().UTC()
		a.P.status.LastConnected = &n
	}
}
func (a *Agent) Run(ctx context.Context) {
	a.ownerMu.Lock()
	a.owners = map[string]owner{}
	a.ownerMu.Unlock()
	if a.USB != nil {
		go a.USB.Serve(ctx)
	}
	a.bindings = map[string]string{}
	defer a.media.Wait()
	delays := []time.Duration{250 * time.Millisecond, 500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second}
	attempt := 0
	for ctx.Err() == nil {
		a.P.mu.Lock()
		cfg := a.P.config
		a.P.mu.Unlock()
		if cfg == nil {
			select {
			case <-ctx.Done():
				return
			case <-a.P.changed:
			}
			continue
		}
		code, established := a.connectSession(ctx, cfg)
		a.status(false, "", code)
		log.Printf("cloud connection ended: %s", code)
		if established || code == "certificate_renewed" {
			attempt = 0
		}
		if code == "certificate_renewed" {
			continue
		}
		var j [1]byte
		_, _ = rand.Read(j[:])
		wait := delays[attempt] + time.Duration(j[0])*delays[attempt]/1275
		if attempt < len(delays)-1 {
			attempt++
		}
		log.Printf("cloud reconnect scheduled in %s", wait)
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}
func (a *Agent) discover(ctx context.Context, s *saved) error {
	client, e := a.P.client(s, false)
	if e != nil {
		return e
	}
	defer client.CloseIdleConnections()
	req, e := http.NewRequestWithContext(ctx, "GET", s.Request.API+"/.well-known/airsim", nil)
	if e != nil {
		return e
	}
	resp, e := client.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return errConfig
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 16385))
	if e != nil || len(b) > 16384 {
		return errConfig
	}
	var v struct {
		Protocol     int             `json:"protocol_version"`
		Profile      string          `json:"profile"`
		Server       string          `json:"server_id"`
		API          string          `json:"api_origin"`
		Device       string          `json:"device_origin"`
		Media        string          `json:"media_origin"`
		Capabilities json.RawMessage `json:"capabilities"`
	}
	if exact(b, "protocol_version,profile,server_id,api_origin,device_origin,media_origin,capabilities", &v) != nil || v.Protocol != 2 || (v.Profile != Profile && v.Profile != "airsim-v2-callkit") || v.Server != s.Request.ServerID || v.API != s.Request.API || v.Device != s.Request.Device || v.Media != s.Request.Media {
		return errConfig
	}
	var caps struct {
		Test      bool `json:"controlled_test_client"`
		Telephony bool `json:"telephony"`
		Messaging bool `json:"messaging"`
		Audio     bool `json:"experimental_audio"`
		APNS      bool `json:"apns"`
		Login     bool `json:"interactive_login"`
		Pairing   bool `json:"device_pairing"`
		Refresh   bool `json:"client_session_refresh"`
	}
	if exactOptional(v.Capabilities, "controlled_test_client,telephony,messaging,experimental_audio,apns,interactive_login", "device_pairing,client_session_refresh", &caps) != nil || !caps.Test || !caps.Telephony || !caps.Messaging || !caps.Audio || (caps.APNS && v.Profile != "airsim-v2-callkit") || caps.Login {
		return errConfig
	}
	return nil
}
func (a *Agent) view(ctx context.Context, kind, id string) (any, int) {
	c, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	return a.Control.View(c, kind, id)
}
func (a *Agent) controlView(ctx context.Context) (control.Status, error) {
	v, code := a.view(ctx, "control", "")
	s, ok := v.(control.Status)
	if code != 200 || !ok {
		return s, errConfig
	}
	return s, nil
}
func (a *Agent) connect(parent context.Context, s *saved) string {
	reason, _ := a.connectSession(parent, s)
	return reason
}
func (a *Agent) connectSession(parent context.Context, s *saved) (reason string, established bool) {
	cert, err := a.P.validate(s, true)
	if err != nil {
		return "certificate_invalid", false
	}
	// TLS only checks validity at handshake. The authenticated connection and
	// every media child must also end at this exact leaf certificate deadline.
	ctx, cancel := context.WithDeadline(parent, cert.NotAfter)
	defer func() {
		cancel()
		if reason != "certificate_renewed" && !time.Now().Before(cert.NotAfter) {
			reason = "certificate_expired"
		}
		a.status(false, "", reason)
	}()
	discovery, discoveryCancel := context.WithTimeout(ctx, discoveryTimeout)
	err = a.discover(discovery, s)
	discoveryCancel()
	if err != nil {
		log.Printf("cloud discovery failed: %v", err)
		return "discovery_failed", false
	}
	client, e := a.P.client(s, true)
	if e != nil {
		return "certificate_invalid", false
	}
	defer client.CloseIdleConnections()
	handshake, hcancel := context.WithTimeout(ctx, controlHandshakeTimeout)
	defer hcancel()
	ws, resp, e := websocket.Dial(handshake, "wss"+strings.TrimPrefix(s.Request.Device, "https")+"/v2/device/control", &websocket.DialOptions{HTTPClient: client, Subprotocols: []string{"airsim.control.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		log.Printf("cloud control handshake failed: %v", e)
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		return "control_connect", false
	}
	canRenew := resp != nil && resp.Header.Get("X-AirSIM-Cert-Renewal") == "1"
	defer ws.CloseNow()
	if ws.Subprotocol() != "airsim.control.v2" {
		return "control_protocol", false
	}
	ws.SetReadLimit(131072)
	c := &connection{agent: a, config: s, life: parent, ctx: ctx, cancel: cancel, ws: ws, queue: make(chan outgoing, 32), pending: map[string]*pendingReceipt{}, owners: a.owners}
	defer func() {
		cancel()
		c.wg.Wait()
	}()
	status, e := a.controlView(handshake)
	if e != nil {
		return "control_unavailable", false
	}
	hello := envelope{Type: "hello", Protocol: 2, Module: a.P.id.ModuleID, Sequence: 1}
	hello.Payload, _ = json.Marshal(map[string]any{"agent_boot_id": a.Boot, "backend_epoch": status.Epoch, "agent_version": a.Version, "platform": a.P.profile, "usb_local": a.USB != nil, "media_codec": "opus"})
	b, _ := json.Marshal(hello)
	if ws.Write(handshake, websocket.MessageText, b) != nil {
		return "control_write", false
	}
	typ, b, e := ws.Read(handshake)
	if e != nil || typ != websocket.MessageText {
		return "control_welcome", false
	}
	frame, e := parseEnvelope(b, a.P.id.ModuleID, "", 1, true)
	if e != nil || frame.Type != "welcome" {
		return "control_welcome", false
	}
	var welcome struct {
		Server    string `json:"server_id"`
		Heartbeat int    `json:"heartbeat_seconds"`
	}
	if exact(frame.Payload, "server_id,heartbeat_seconds", &welcome) != nil || welcome.Server != s.Request.ServerID || welcome.Heartbeat != 5 {
		return "control_welcome", false
	}
	c.epoch = frame.Epoch
	c.seq = 1
	established = true
	a.status(true, c.epoch, "")
	log.Printf("cloud connected")
	c.wg.Add(1)
	go c.writer()
	frames := make(chan envelope, 1)
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer cancel()
		seq := uint64(1)
		for {
			rctx, rcancel := context.WithTimeout(ctx, 15*time.Second)
			t, b, e := ws.Read(rctx)
			rcancel()
			if e != nil || t != websocket.MessageText {
				return
			}
			seq++
			f, e := parseEnvelope(b, a.P.id.ModuleID, c.epoch, seq, false)
			if e != nil {
				return
			}
			select {
			case frames <- f:
			case <-ctx.Done():
				return
			}
		}
	}()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	// Only run the 250 ms receipt poller while commands are pending; avoid 4 Hz idle wakeups.
	var receipts *time.Ticker
	var receiptsCh <-chan time.Time
	defer func() {
		if receipts != nil {
			receipts.Stop()
		}
	}()
	armReceipts := func() {
		if len(c.pending) > 0 && receipts == nil {
			receipts = time.NewTicker(250 * time.Millisecond)
			receiptsCh = receipts.C
		} else if len(c.pending) == 0 && receipts != nil {
			receipts.Stop()
			receipts = nil
			receiptsCh = nil
		}
	}
	heart := time.NewTicker(5 * time.Second)
	defer heart.Stop()
	renewWindow := a.RenewWindow
	if renewWindow <= 0 {
		renewWindow = defaultCertRenewWindow
	}
	renewRequested := false
	tryRenew := func() bool {
		if !canRenew || renewRequested || time.Until(cert.NotAfter) > renewWindow {
			return true
		}
		reqID, nonce, csrPEM, ok := a.P.RenewalRequest()
		if !ok {
			return true
		}
		renewRequested = true
		log.Printf("cloud requesting certificate renewal (expires %s)", cert.NotAfter.UTC().Format(time.RFC3339))
		return c.send("cert_renew", map[string]string{"request_id": reqID, "nonce": nonce, "csr_pem": csrPEM})
	}
	var renewTick *time.Ticker
	var renewCh <-chan time.Time
	if canRenew {
		renewTick = time.NewTicker(certRenewCheckInterval)
		renewCh = renewTick.C
		defer renewTick.Stop()
	}
	var last synced
	if !c.sync(&last) {
		return "snapshot_failed", true
	}
	if !tryRenew() {
		return "control_queue", true
	}
	for {
		select {
		case <-ctx.Done():
			if c.renewed {
				return "certificate_renewed", true
			}
			return "control_disconnected", true
		case f := <-frames:
			if !c.handle(f) {
				return "control_protocol", true
			}
			if c.renewed {
				return "certificate_renewed", true
			}
			armReceipts()
		case <-tick.C:
			if !c.sync(&last) {
				return "snapshot_failed", true
			}
		case <-receiptsCh:
			for id, p := range c.pending {
				v, code := a.view(ctx, "command", id)
				if !c.receipt(p, v, code) {
					return "control_queue", true
				}
			}
			armReceipts()
		case <-renewCh:
			if !tryRenew() {
				return "control_queue", true
			}
		case <-heart.C:
			if !c.send("heartbeat", struct{}{}) {
				return "control_queue", true
			}
		}
	}
}
func parseEnvelope(b []byte, module, epoch string, seq uint64, welcome bool) (envelope, error) {
	var f envelope
	if exact(b, "type,protocol_version,module_id,connection_epoch,sequence,payload", &f) != nil || f.Protocol != 2 || f.Module != module || f.Sequence != seq || seq == 0 {
		return f, errConfig
	}
	if welcome {
		if !control.ValidID(f.Epoch) {
			return f, errConfig
		}
	} else if f.Epoch != epoch {
		return f, errConfig
	}
	return f, nil
}
func (c *connection) send(kind string, payload any) bool {
	raw, err := json.Marshal(payload)
	if err != nil {
		c.cancel()
		return false
	}
	// Bound queued encoded data before enqueue, including worst-case sequence width.
	module := ""
	if c.agent.P != nil {
		module = c.agent.P.id.ModuleID
	}
	encoded, err := json.Marshal(envelope{kind, 2, module, c.epoch, ^uint64(0), raw})
	limit := 131072
	if kind == "messages" {
		limit = 65536
	}
	if err != nil || len(encoded) > limit {
		c.cancel()
		return false
	}
	payload = json.RawMessage(raw)
	select {
	case <-c.ctx.Done():
		return false
	default:
	}
	select {
	case c.queue <- outgoing{kind, payload}:
		return true
	default:
		c.cancel()
		return false
	}
}
func (c *connection) writer() {
	defer c.wg.Done()
	defer c.cancel()
	seq := uint64(1)
	for {
		select {
		case <-c.ctx.Done():
			return
		case out := <-c.queue:
			seq++
			p, e := json.Marshal(out.payload)
			if e != nil {
				return
			}
			b, e := json.Marshal(envelope{out.kind, 2, c.agent.P.id.ModuleID, c.epoch, seq, p})
			if e != nil || len(b) > 131072 || (out.kind == "messages" && len(b) > 65536) {
				return
			}
			ctx, cancel := context.WithTimeout(c.ctx, 3*time.Second)
			e = c.ws.Write(ctx, websocket.MessageText, b)
			cancel()
			if e != nil {
				return
			}
		}
	}
}

// synced is what the connection last sent.
type synced struct {
	snapshot string
	control  control.Status
	calls    control.CallsView
	signal   state.SignalView
	haveBase bool
	messages *control.MessagesView
	sent     time.Time
}

func equalSignalView(a, b state.SignalView) bool {
	if a.Available != b.Available {
		return false
	}
	if (a.ObservedAt == nil) != (b.ObservedAt == nil) || (a.ObservedAt != nil && !a.ObservedAt.Equal(*b.ObservedAt)) {
		return false
	}
	if (a.RSSI == nil) != (b.RSSI == nil) || (a.RSSI != nil && *a.RSSI != *b.RSSI) {
		return false
	}
	if (a.DBM == nil) != (b.DBM == nil) || (a.DBM != nil && *a.DBM != *b.DBM) {
		return false
	}
	return true
}

func (c *connection) sync(last *synced) bool {
	a := c.agent
	first, e := a.controlView(c.ctx)
	if e != nil {
		return false
	}
	raw, code := a.view(c.ctx, "calls", "")
	calls, ok := raw.(control.CallsView)
	if code != 200 || !ok {
		return false
	}
	interval := 5 * time.Second
	for _, call := range calls.Calls {
		if call.State != "disconnected" {
			interval = time.Second
			break
		}
	}
	sig := a.signalView()
	// Fast path: when control/calls/signal match the last published state and
	// the periodic heartbeat snapshot interval has not elapsed, skip the
	// redundant second consistency read and full JSON marshal on EG25.
	unchanged := last.haveBase && first == last.control && equalSignalView(sig, last.signal) && calls.Boot == last.calls.Boot && calls.Epoch == last.calls.Epoch && calls.Available == last.calls.Available && slices.Equal(calls.Calls, last.calls.Calls)
	if unchanged && time.Since(last.sent) < interval && a.Media.View().Session == nil {
		goto syncMessages
	}
	{
		second, e := a.controlView(c.ctx)
		if e != nil {
			return false
		}
		raw, code = a.view(c.ctx, "calls", "")
		calls2, ok := raw.(control.CallsView)
		if code != 200 || !ok {
			return false
		}
		if first.Boot != second.Boot || first.Epoch != second.Epoch || calls.Boot != second.Boot || calls.Epoch != second.Epoch || calls2.Boot != second.Boot || calls2.Epoch != second.Epoch {
			return true
		}
		sig = a.signalView()
		payload := map[string]any{"agent_boot_id": second.Boot, "backend_epoch": second.Epoch, "observed_at": "", "control": second, "calls": calls2, "audio": a.Media.View(), "signal": sig}
		b, _ := json.Marshal(payload)
		interval = 5 * time.Second
		for _, call := range calls2.Calls {
			if call.State != "disconnected" {
				interval = time.Second
				break
			}
		}
		if string(b) != last.snapshot || time.Since(last.sent) >= interval {
			payload["observed_at"] = time.Now().UTC().Format(time.RFC3339Nano)
			if !c.send("snapshot", payload) {
				return false
			}
			last.snapshot = string(b)
			last.sent = time.Now()
		}
		last.control = second
		last.calls = calls2
		last.signal = sig
		last.haveBase = true
		// Ownership expires on observed disconnect or boot/backend replacement.
		a.ownerMu.Lock()
		for id, o := range c.owners {
			valid := false
			for _, call := range calls2.Calls {
				if call.ID == id && call.State != "disconnected" && o.boot == second.Boot && o.epoch == second.Epoch {
					valid = true
				}
			}
			if !valid {
				delete(c.owners, id)
			}
		}
		a.ownerMu.Unlock()
	}
syncMessages:
	raw, code = a.view(c.ctx, "cloud_messages", "")
	messages, ok := raw.(control.MessagesView)
	if code != 200 || !ok {
		return false
	}
	if messages.Boot != last.control.Boot || messages.Epoch != last.control.Epoch {
		return true
	}
	if p := last.messages; p != nil && p.Boot == messages.Boot && p.Epoch == messages.Epoch && p.Available == messages.Available && p.Gap == messages.Gap && p.Dropped == messages.Dropped && slices.Equal(p.Messages, messages.Messages) {
		return true
	}
	batch := []control.Message{}
	emit := func() bool {
		return c.send("messages", map[string]any{"agent_boot_id": messages.Boot, "backend_epoch": messages.Epoch, "observed_at": time.Now().UTC().Format(time.RFC3339Nano), "inbox_gap": messages.Gap, "inbox_dropped": messages.Dropped, "messages": batch})
	}
	for _, m := range messages.Messages {
		candidate := append(append([]control.Message{}, batch...), m)
		bb, _ := json.Marshal(candidate)
		if len(candidate) > 32 || len(bb) > 60000 {
			if len(batch) == 0 || !emit() {
				return false
			}
			batch = []control.Message{m}
		} else {
			batch = candidate
		}
	}
	if len(batch) > 0 || len(messages.Messages) == 0 {
		if !emit() {
			return false
		}
	}
	last.messages = &messages
	return true
}
func (c *connection) receipt(p *pendingReceipt, v any, code int) bool {
	return c.receiptAt(p, v, code, time.Now())
}
func (c *connection) receiptAt(p *pendingReceipt, v any, code int, now time.Time) bool {
	b, _ := json.Marshal(v)
	state := struct {
		State string `json:"state"`
		Call  string `json:"call_id"`
	}{}
	_ = json.Unmarshal(b, &state)
	key := string(b)
	if key != p.last {
		if !c.send("receipt", map[string]any{"command_id": p.request.CommandID, "status_code": code, "receipt": v}) {
			return false
		}
		p.last = key
	}
	if p.authorized && (state.State == "accepted" || state.State == "observed") && control.ValidID(state.Call) && (p.request.Action == "call.dial" || p.request.Action == "call.answer") {
		c.agent.ownerMu.Lock()
		c.owners[state.Call] = owner{state.Call, p.client, p.generation, p.request.BootID, p.request.Epoch}
		c.agent.ownerMu.Unlock()
	}
	c.agent.updateClaim(p.request, state.State, state.Call)
	keep := state.State == "prepared" || state.State == "dispatched"
	if state.State == "accepted" && (p.request.Action == "call.answer" || p.request.Action == "call.hangup") {
		if p.acceptedUntil.IsZero() {
			p.acceptedUntil = now.Add(11 * time.Second)
		}
		keep = now.Before(p.acceptedUntil)
	}
	if !keep {
		delete(c.pending, p.request.CommandID)
	}
	return true
}
func (c *connection) handle(f envelope) bool {
	if c.ctx.Err() != nil {
		return false
	}
	switch f.Type {
	case "heartbeat":
		var v struct{}
		return exact(f.Payload, "", &v) == nil
	case "cert_renewed":
		var b Bundle
		if exact(f.Payload, "request_id,server_id,module_id,certificate_pem,receipt_base64", &b) != nil {
			return false
		}
		cert, err := c.agent.P.Renew(b)
		if err != nil {
			log.Printf("cloud certificate renewal rejected: %v", err)
			return true
		}
		log.Printf("cloud certificate renewed (new expiry %s)", cert.NotAfter.UTC().Format(time.RFC3339))
		c.renewed = true
		c.cancel()
		return true
	case "usb_revoke":
		var v struct {
			Client string `json:"client_installation_id"`
		}
		if exact(f.Payload, "client_installation_id", &v) != nil || !control.ValidID(v.Client) {
			return false
		}
		return c.agent.USB == nil || c.agent.USB.revoke(v.Client) == nil
	case "usb_authorize":
		var v struct {
			Request string `json:"request_id"`
			Client  string `json:"client_installation_id"`
			Expires string `json:"expires_at"`
		}
		if exact(f.Payload, "request_id,client_installation_id,expires_at", &v) != nil || !control.ValidID(v.Request) || !control.ValidID(v.Client) {
			return false
		}
		expiry, e := utc(v.Expires)
		if e != nil || !expiry.After(time.Now()) || time.Until(expiry) > 24*time.Hour+5*time.Second {
			return false
		}
		var grant *USBAuthorization
		code := 503
		if c.agent.USB != nil {
			grant, e = c.agent.USB.authorize(v.Client, v.Expires)
			if e == nil {
				code = 200
			}
		}
		return c.send("usb_authorization", map[string]any{"request_id": v.Request, "status_code": code, "authorization": grant})
	case "command":
		var v struct {
			Client     string          `json:"client_installation_id"`
			Generation string          `json:"generation"`
			Command    json.RawMessage `json:"command"`
		}
		if exact(f.Payload, "client_installation_id,generation,command", &v) != nil || !control.ValidID(v.Client) || !control.ValidID(v.Generation) {
			return false
		}
		r, e := control.Parse(v.Command)
		if e != nil {
			return false
		}
		if len(c.pending) >= 64 {
			return c.send("receipt", map[string]any{"command_id": r.CommandID, "status_code": 429, "receipt": nil})
		}
		binding := hash(append(append(r.Canonical(), []byte(v.Client)...), []byte(v.Generation)...))
		oldBinding, known := c.agent.bindings[r.CommandID]
		if known && oldBinding != binding {
			return c.send("receipt", map[string]any{"command_id": r.CommandID, "status_code": 409, "receipt": nil})
		}
		p := &pendingReceipt{request: r, client: v.Client, generation: v.Generation, authorized: known}
		c.pending[r.CommandID] = p
		ctx, cancel := context.WithTimeout(c.ctx, time.Second)
		if !c.agent.reserveCommand(ctx, r, v.Client, "cloud") {
			cancel()
			delete(c.pending, r.CommandID)
			return c.send("receipt", map[string]any{"command_id": r.CommandID, "status_code": 409, "receipt": nil})
		}
		value, code := c.agent.Control.Submit(ctx, r)
		c.agent.rejectClaim(r, code)
		cancel()
		if code == 202 {
			p.authorized = true
			if c.agent.bindings == nil {
				c.agent.bindings = map[string]string{}
			}
			c.agent.bindings[r.CommandID] = binding
		}
		return c.receipt(p, value, code)
	case "receipt_query":
		var v struct {
			ID string `json:"command_id"`
		}
		if exact(f.Payload, "command_id", &v) != nil || !control.ValidID(v.ID) {
			return false
		}
		value, code := c.agent.view(c.ctx, "command", v.ID)
		if p := c.pending[v.ID]; p != nil {
			// Queries always return a receipt, including unchanged pending states.
			p.last = ""
			return c.receipt(p, value, code)
		}
		return c.send("receipt", map[string]any{"command_id": v.ID, "status_code": code, "receipt": value})
	case "media_start":
		return c.startMedia(f.Payload)
	case "media_stop":
		var v struct {
			ID     string `json:"session_id"`
			Reason string `json:"reason"`
		}
		if exact(f.Payload, "session_id,reason", &v) != nil || !control.ValidID(v.ID) || len(v.Reason) > 128 {
			return false
		}
		c.agent.stopBridge(v.ID)
		return true
	default:
		return false
	}
}
