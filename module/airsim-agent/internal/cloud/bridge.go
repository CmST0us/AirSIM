package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"bytes"
	"context"
	"encoding/json"
	"github.com/coder/websocket"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type mediaStart struct {
	Request    string `json:"request_id"`
	Session    string `json:"session_id"`
	Call       string `json:"call_id"`
	Boot       string `json:"agent_boot_id"`
	Epoch      string `json:"backend_epoch"`
	Client     string `json:"client_installation_id"`
	Generation string `json:"generation"`
	Ticket     string `json:"ticket"`
	Expires    string `json:"expires_at"`
}
type BridgeStats struct {
	SessionID      string `json:"session_id"`
	State          string `json:"state"`
	Reason         string `json:"reason"`
	CloudInputGaps uint64 `json:"cloud_input_gaps"`
	LocalInputGaps uint64 `json:"local_input_gaps"`
	QueueDrops     uint64 `json:"queue_drops"`
	ZeroFrames     uint64 `json:"zero_frames"`
}
type bridgeCounters struct{ cloud, local, drops, zeros atomic.Uint64 }

// Only the future plausibility bound tolerates five seconds of clock skew.
// The server remains authoritative for its unchanged absolute ticket expiry.
func validMediaExpiry(expires string, now time.Time) bool {
	expiry, err := utc(expires)
	if err != nil {
		return false
	}
	remaining := expiry.Sub(now)
	return remaining > 0 && remaining <= 35*time.Second
}
func (c *connection) startMedia(b []byte) bool {
	return c.startMediaAt(b, time.Now())
}
func (c *connection) startMediaAt(b []byte, now time.Time) bool {
	var r mediaStart
	if exact(b, "request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,ticket,expires_at", &r) != nil {
		return false
	}
	for _, id := range []string{r.Request, r.Session, r.Call, r.Boot, r.Epoch, r.Client, r.Generation} {
		if !control.ValidID(id) {
			return false
		}
	}
	if !hex32(r.Ticket) || !validMediaExpiry(r.Expires, now) {
		return false
	}
	o, ok := c.owners[r.Call]
	if !ok || o.client != r.Client || o.generation != r.Generation || o.boot != r.Boot || o.epoch != r.Epoch {
		return c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": "media_owner"})
	}
	if c.mediaCancel != nil {
		select {
		case <-c.mediaDone:
			c.mediaCancel = nil
		default:
			return c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": "media_busy"})
		}
	}
	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Minute)
	c.mediaCancel = cancel
	c.mediaID = r.Session
	c.mediaDone = make(chan struct{})
	done := c.mediaDone
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer close(done)
		defer cancel()
		c.send("media_status", map[string]string{"session_id": r.Session, "state": "starting", "reason": ""})
		reason := c.bridge(ctx, r)
		c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": reason})
	}()
	return true
}
func paired(b []byte, id string) (string, bool) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(b, &raw) != nil {
		return "", false
	}
	var typ string
	if json.Unmarshal(raw["type"], &typ) != nil {
		return "", false
	}
	if typ == "waiting" {
		var v struct {
			Type string `json:"type"`
			ID   string `json:"session_id"`
		}
		return typ, exact(b, "type,session_id", &v) == nil && v.ID == id
	}
	var v struct {
		Type   string          `json:"type"`
		ID     string          `json:"session_id"`
		Format json.RawMessage `json:"format"`
	}
	if typ != "paired" || exact(b, "type,session_id,format", &v) != nil || v.ID != id {
		return "", false
	}
	var f media.Format
	return typ, exact(v.Format, "sample_rate,channels,sample_format,frame_samples", &f) == nil && f == (media.Format{SampleRate: 8000, Channels: 1, SampleFormat: "s16le", FrameSamples: 160})
}
func (c *connection) bridge(parent context.Context, r mediaStart) (reason string) {
	counts := &bridgeCounters{}
	c.agent.beginBridge(r.Session, counts)
	defer func() { c.agent.endBridge(r.Session, reason) }()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	setup, scancel := context.WithTimeout(ctx, 5*time.Second)
	defer scancel()
	client, e := c.agent.P.client(c.config, false)
	if e != nil {
		return "media_tls"
	}
	defer client.CloseIdleConnections()
	ws, resp, e := websocket.Dial(setup, "wss"+strings.TrimPrefix(c.config.Request.Media, "https")+"/v2/media", &websocket.DialOptions{HTTPClient: client, Subprotocols: []string{"airsim.media.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		return "media_connect"
	}
	defer ws.CloseNow()
	if ws.Subprotocol() != "airsim.media.v2" {
		return "media_protocol"
	}
	ws.SetReadLimit(2048)
	auth, _ := json.Marshal(map[string]string{"session_id": r.Session, "role": "agent", "ticket": r.Ticket})
	authctx, acancel := context.WithTimeout(setup, 3*time.Second)
	e = ws.Write(authctx, websocket.MessageText, auth)
	if e != nil {
		acancel()
		return "media_auth"
	}
	typ, b, e := ws.Read(authctx)
	acancel()
	if e != nil || typ != websocket.MessageText {
		return "media_auth"
	}
	phase, ok := paired(b, r.Session)
	if !ok {
		return "media_protocol"
	}
	if phase == "waiting" {
		typ, b, e = ws.Read(setup)
		phase, ok = paired(b, r.Session)
		if e != nil || typ != websocket.MessageText || !ok || phase != "paired" {
			return "media_pair"
		}
	}
	local, code := c.agent.Media.Create(setup, media.Request{RequestID: r.Request, Boot: r.Boot, Epoch: r.Epoch, CallID: r.Call})
	if code != 201 && code != 200 {
		return "media_local_busy"
	}
	defer c.agent.Media.Stop(local.ID)
	conn, e := (&net.Dialer{}).DialContext(setup, "unix", local.Socket)
	if e != nil {
		return "media_local_connect"
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close(); ws.CloseNow() })
	defer stop()
	deadline, _ := setup.Deadline()
	conn.SetDeadline(deadline)
	if media.WriteJSON(conn, map[string]string{"session_id": local.ID, "token": local.Token}, 1024) != nil {
		return "media_local_auth"
	}
	b, e = media.ReadJSON(conn, 1024)
	if e != nil {
		return "media_local_auth"
	}
	var ack struct {
		OK       bool   `json:"ok"`
		Rate     int    `json:"sample_rate"`
		Channels int    `json:"channels"`
		Format   string `json:"sample_format"`
		Frames   int    `json:"frame_samples"`
	}
	if exact(b, "ok,sample_rate,channels,sample_format,frame_samples", &ack) != nil || !ack.OK || ack.Rate != 8000 || ack.Channels != 1 || ack.Format != "s16le" || ack.Frames != 160 {
		return "media_local_auth"
	}
	conn.SetDeadline(time.Time{})
	c.agent.bridgeState(r.Session, "streaming", "")
	if !c.send("media_status", map[string]string{"session_id": r.Session, "state": "streaming", "reason": ""}) {
		return "control_disconnected"
	}
	queue := make(chan media.Frame, 5)
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		defer cancel()
		var sequence uint64
		for {
			readctx, rcancel := context.WithTimeout(ctx, 2*time.Second)
			t, b, e := ws.Read(readctx)
			rcancel()
			if e != nil || t != websocket.MessageBinary || len(b) != media.FrameSize {
				return
			}
			f, gap, e := media.ReadFrame(bytes.NewReader(b), r.Session, 1, &sequence)
			if e != nil {
				return
			}
			counts.cloud.Add(gap)
			select {
			case queue <- f:
			default:
				select {
				case <-queue:
					counts.drops.Add(1)
				default:
				}
				select {
				case queue <- f:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		var seq uint64
		initial := time.NewTicker(20 * time.Millisecond)
		defer initial.Stop()
		zeros := 0
		received := false
		for {
			var f media.Frame
			select {
			case <-ctx.Done():
				return
			case f = <-queue:
				received = true
			case <-initial.C:
				if received || zeros >= 5 {
					continue
				}
				zeros++
				counts.zeros.Add(1)
			}
			seq++
			out := media.NewFrame(local.ID, 1, seq)
			copy(out[40:], f[40:])
			conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
			if writeFrame(conn, out[:]) != nil {
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		var seq, outseq uint64
		for {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			f, gap, e := media.ReadFrame(conn, local.ID, 2, &seq)
			if e != nil {
				return
			}
			counts.local.Add(gap)
			outseq++
			out := media.NewFrame(r.Session, 2, outseq)
			copy(out[40:], f[40:])
			wctx, wcancel := context.WithTimeout(ctx, 100*time.Millisecond)
			e = ws.Write(wctx, websocket.MessageBinary, out[:])
			wcancel()
			if e != nil {
				return
			}
		}
	}()
	<-ctx.Done()
	conn.Close()
	ws.CloseNow()
	wg.Wait()
	return "media_closed"
}
func writeFrame(c net.Conn, b []byte) error {
	for len(b) > 0 {
		n, e := c.Write(b)
		if e != nil {
			return e
		}
		if n == 0 {
			return errConfig
		}
		b = b[n:]
	}
	return nil
}
func countersInto(s BridgeStats, c *bridgeCounters) BridgeStats {
	if c != nil {
		s.CloudInputGaps = c.cloud.Load()
		s.LocalInputGaps = c.local.Load()
		s.QueueDrops = c.drops.Load()
		s.ZeroFrames = c.zeros.Load()
	}
	return s
}
func (a *Agent) beginBridge(id string, c *bridgeCounters) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	a.lastBridge = BridgeStats{SessionID: id, State: "starting"}
	a.activeCounters = c
}
func (a *Agent) bridgeState(id, state, reason string) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	if a.lastBridge.SessionID == id {
		a.lastBridge.State = state
		a.lastBridge.Reason = reason
	}
}
func (a *Agent) endBridge(id, reason string) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	if a.lastBridge.SessionID == id {
		a.lastBridge = countersInto(a.lastBridge, a.activeCounters)
		a.lastBridge.State = "closed"
		a.lastBridge.Reason = reason
		a.activeCounters = nil
	}
}
func (a *Agent) LastBridgeStats() BridgeStats {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	s := countersInto(a.lastBridge, a.activeCounters)
	if s.State == "" {
		s.State = "idle"
	}
	return s
}
