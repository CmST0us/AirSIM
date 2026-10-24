package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"context"
	"crypto/rand"
	"encoding/json"
	"github.com/coder/websocket"
	"io"
	"net/http"
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
	P              *Provisioner
	Control        Controller
	Media          Media
	Boot, Version  string
	statsMu        sync.Mutex
	lastBridge     BridgeStats
	activeCounters *bridgeCounters
	owners         map[string]owner
	bindings       map[string]string
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
	agent       *Agent
	config      *saved
	ctx         context.Context
	cancel      context.CancelFunc
	ws          *websocket.Conn
	queue       chan outgoing
	epoch       string
	seq         uint64
	pending     map[string]*pendingReceipt
	owners      map[string]owner
	mediaID     string
	mediaCancel context.CancelFunc
	mediaDone   chan struct{}
	wg          sync.WaitGroup
}

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
	a.owners = map[string]owner{}
	a.bindings = map[string]string{}
	delays := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second}
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
		code := a.connect(ctx, cfg)
		a.status(false, "", code)
		var j [1]byte
		_, _ = rand.Read(j[:])
		wait := delays[attempt] + time.Duration(j[0])*delays[attempt]/1275
		if attempt < len(delays)-1 {
			attempt++
		}
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
	if exact(b, "protocol_version,profile,server_id,api_origin,device_origin,media_origin,capabilities", &v) != nil || v.Protocol != 2 || v.Profile != Profile || v.Server != s.Request.ServerID || v.API != s.Request.API || v.Device != s.Request.Device || v.Media != s.Request.Media {
		return errConfig
	}
	var caps struct {
		Test      bool `json:"controlled_test_client"`
		Telephony bool `json:"telephony"`
		Messaging bool `json:"messaging"`
		Audio     bool `json:"experimental_audio"`
		APNS      bool `json:"apns"`
		Login     bool `json:"interactive_login"`
	}
	if exact(v.Capabilities, "controlled_test_client,telephony,messaging,experimental_audio,apns,interactive_login", &caps) != nil || !caps.Test || !caps.Telephony || !caps.Messaging || !caps.Audio || caps.APNS || caps.Login {
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
func (a *Agent) connect(parent context.Context, s *saved) (reason string) {
	cert, err := a.P.validate(s, true)
	if err != nil {
		return "certificate_invalid"
	}
	// TLS only checks validity at handshake. The authenticated connection and
	// every media child must also end at this exact leaf certificate deadline.
	ctx, cancel := context.WithDeadline(parent, cert.NotAfter)
	defer func() {
		cancel()
		if !time.Now().Before(cert.NotAfter) {
			reason = "certificate_expired"
		}
		a.status(false, "", reason)
	}()
	handshake, hcancel := context.WithTimeout(ctx, 5*time.Second)
	defer hcancel()
	if a.discover(handshake, s) != nil {
		return "discovery_failed"
	}
	client, e := a.P.client(s, true)
	if e != nil {
		return "certificate_invalid"
	}
	defer client.CloseIdleConnections()
	ws, resp, e := websocket.Dial(handshake, "wss"+strings.TrimPrefix(s.Request.Device, "https")+"/v2/device/control", &websocket.DialOptions{HTTPClient: client, Subprotocols: []string{"airsim.control.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		return "control_connect"
	}
	defer ws.CloseNow()
	if ws.Subprotocol() != "airsim.control.v2" {
		return "control_protocol"
	}
	ws.SetReadLimit(131072)
	c := &connection{agent: a, config: s, ctx: ctx, cancel: cancel, ws: ws, queue: make(chan outgoing, 32), pending: map[string]*pendingReceipt{}, owners: a.owners}
	defer func() {
		cancel()
		if c.mediaCancel != nil {
			c.mediaCancel()
		}
		c.wg.Wait()
	}()
	status, e := a.controlView(handshake)
	if e != nil {
		return "control_unavailable"
	}
	hello := envelope{Type: "hello", Protocol: 2, Module: a.P.id.ModuleID, Sequence: 1}
	hello.Payload, _ = json.Marshal(map[string]any{"agent_boot_id": a.Boot, "backend_epoch": status.Epoch, "agent_version": a.Version})
	b, _ := json.Marshal(hello)
	if ws.Write(handshake, websocket.MessageText, b) != nil {
		return "control_write"
	}
	typ, b, e := ws.Read(handshake)
	if e != nil || typ != websocket.MessageText {
		return "control_welcome"
	}
	frame, e := parseEnvelope(b, a.P.id.ModuleID, "", 1, true)
	if e != nil || frame.Type != "welcome" {
		return "control_welcome"
	}
	var welcome struct {
		Server    string `json:"server_id"`
		Heartbeat int    `json:"heartbeat_seconds"`
	}
	if exact(frame.Payload, "server_id,heartbeat_seconds", &welcome) != nil || welcome.Server != s.Request.ServerID || welcome.Heartbeat != 5 {
		return "control_welcome"
	}
	c.epoch = frame.Epoch
	c.seq = 1
	a.status(true, c.epoch, "")
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
	receipts := time.NewTicker(250 * time.Millisecond)
	defer receipts.Stop()
	heart := time.NewTicker(5 * time.Second)
	defer heart.Stop()
	var lastSnapshot, lastMessages string
	var sent time.Time
	if !c.sync(&lastSnapshot, &lastMessages, &sent) {
		return "snapshot_failed"
	}
	for {
		select {
		case <-ctx.Done():
			return "control_disconnected"
		case f := <-frames:
			if !c.handle(f) {
				return "control_protocol"
			}
		case <-tick.C:
			if !c.sync(&lastSnapshot, &lastMessages, &sent) {
				return "snapshot_failed"
			}
			if _, e := a.P.validate(s, true); e != nil {
				return "certificate_expired"
			}
		case <-receipts.C:
			for id, p := range c.pending {
				v, code := a.view(ctx, "command", id)
				if !c.receipt(p, v, code) {
					return "control_queue"
				}
			}
		case <-heart.C:
			if !c.send("heartbeat", struct{}{}) {
				return "control_queue"
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
func (c *connection) sync(lastSnap, lastMessages *string, lastSent *time.Time) bool {
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
	payload := map[string]any{"agent_boot_id": second.Boot, "backend_epoch": second.Epoch, "observed_at": "", "control": second, "calls": calls2, "audio": a.Media.View()}
	b, _ := json.Marshal(payload)
	if string(b) != *lastSnap || time.Since(*lastSent) >= 5*time.Second {
		payload["observed_at"] = time.Now().UTC().Format(time.RFC3339Nano)
		if !c.send("snapshot", payload) {
			return false
		}
		*lastSnap = string(b)
		*lastSent = time.Now()
	}
	// Ownership expires on observed disconnect or boot/backend replacement.
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
	raw, code = a.view(c.ctx, "cloud_messages", "")
	messages, ok := raw.(control.MessagesView)
	if code != 200 || !ok {
		return false
	}
	if messages.Boot != second.Boot || messages.Epoch != second.Epoch {
		return true
	}
	mb, _ := json.Marshal(messages)
	if string(mb) == *lastMessages {
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
	*lastMessages = string(mb)
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
		c.owners[state.Call] = owner{state.Call, p.client, p.generation, p.request.BootID, p.request.Epoch}
	}
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
		value, code := c.agent.Control.Submit(ctx, r)
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
		if v.ID == c.mediaID && c.mediaCancel != nil {
			c.mediaCancel()
		}
		return true
	default:
		return false
	}
}
