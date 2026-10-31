package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"github.com/coder/websocket"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type mediaStart struct {
	Format     json.RawMessage `json:"format"`
	Request    string          `json:"request_id"`
	Session    string          `json:"session_id"`
	Call       string          `json:"call_id"`
	Boot       string          `json:"agent_boot_id"`
	Epoch      string          `json:"backend_epoch"`
	Client     string          `json:"client_installation_id"`
	Generation string          `json:"generation"`
	Ticket     string          `json:"ticket"`
	Expires    string          `json:"expires_at"`
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
	if exact(b, "request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,ticket,expires_at,format", &r) != nil {
		return false
	}
	var negotiated media.Format
	if exact(r.Format, "codec,sample_rate,channels,sample_format,frame_samples,codec_frame_us,codec_frame_bytes", &negotiated) != nil || negotiated != media.LC3Format {
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
	c.agent.ownerMu.Lock()
	o, ok := c.owners[r.Call]
	usbOwned := c.agent.claim != nil && c.agent.claim.route == "usb"
	c.agent.ownerMu.Unlock()
	if usbOwned || !ok || o.client != r.Client || o.generation != r.Generation || o.boot != r.Boot || o.epoch != r.Epoch {
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
	return typ, exact(v.Format, "codec,sample_rate,channels,sample_format,frame_samples,codec_frame_us,codec_frame_bytes", &f) == nil && f == (media.LC3Format)
}
func mediaSetupDeadline(now time.Time, expires string) time.Time {
	deadline := now.Add(20 * time.Second)
	expiry, _ := utc(expires) // startMedia validates the absolute ticket expiry.
	if expiry.Before(deadline) {
		return expiry
	}
	return deadline
}

func (c *connection) bridge(parent context.Context, r mediaStart) (reason string) {
	counts := &bridgeCounters{}
	c.agent.beginBridge(r.Session, counts)
	defer func() { c.agent.endBridge(r.Session, reason) }()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	setup, scancel := context.WithDeadline(ctx, mediaSetupDeadline(time.Now(), r.Expires))
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
		return mediaConnectReason(e, resp)
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
		OK bool `json:"ok"`
		media.Format
	}
	if exact(b, "ok,codec,sample_rate,channels,sample_format,frame_samples,codec_frame_us,codec_frame_bytes", &ack) != nil || !ack.OK || ack.Format != media.LC3Format {
		return "media_local_auth"
	}
	conn.SetDeadline(time.Time{})
	c.agent.bridgeState(r.Session, "streaming", "")
	if !c.send("media_status", map[string]string{"session_id": r.Session, "state": "streaming", "reason": ""}) {
		return "control_disconnected"
	}
	return bridgeFrames(ctx, cancel, ws, conn, local.ID, r.Session, counts)
}
func bridgeFrames(ctx context.Context, cancel context.CancelFunc, ws *websocket.Conn, conn net.Conn, localID, sessionID string, counts *bridgeCounters) string {
	var first sync.Once
	reason := "media_cancelled"
	fail := func(code string) {
		if ctx.Err() != nil {
			return
		}
		first.Do(func() { reason = code; cancel() })
	}
	down := newJitterQueue(counts)
	up := newPlayoutQueue(counts)
	clock := realPlayoutClock{}
	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		defer cancel()
		var sequence uint64
		for {
			// Record timeout before WebSocket cancellation closes the other direction.
			readctx, rcancel := context.WithCancel(ctx)
			timer := time.AfterFunc(2*time.Second, func() { fail("cloud_read_timeout"); rcancel() })
			t, b, e := ws.Read(readctx)
			timer.Stop()
			rcancel()
			if e != nil {
				fail(bridgeIOReason("cloud_read", e))
				return
			}
			if t != websocket.MessageBinary || len(b) != media.FrameSize {
				fail("cloud_invalid_frame")
				return
			}
			f, gap, e := media.ReadFrame(bytes.NewReader(b), sessionID, 1, &sequence)
			if e != nil {
				fail("cloud_invalid_frame")
				return
			}
			counts.cloud.Add(gap)
			down.push(f, clock.Now())
		}
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		var sequences sequenceMapping
		playPCM(ctx, down, clock, true, func(f media.Frame) error {
			out := media.NewFrame(localID, 1, sequences.next(f))
			copy(out[36:], f[36:])
			conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
			e := writeFrame(conn, out[:])
			if e != nil {
				fail(bridgeIOReason("local_write", e))
			}
			return e
		})
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		var seq uint64
		for {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			f, gap, e := media.ReadFrame(conn, localID, 2, &seq)
			if e != nil {
				if errors.Is(e, media.ErrProtocol) {
					fail("local_invalid_frame")
				} else {
					fail(bridgeIOReason("local_read", e))
				}
				return
			}
			counts.local.Add(gap)
			up.push(f, clock.Now())
		}
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		var sequences sequenceMapping
		playPCM(ctx, up, clock, false, func(f media.Frame) error {
			out := media.NewFrame(sessionID, 2, sequences.next(f))
			copy(out[36:], f[36:])
			wctx, wcancel := context.WithCancel(ctx)
			timer := time.AfterFunc(100*time.Millisecond, func() { fail("cloud_write_timeout"); wcancel() })
			defer timer.Stop()
			defer wcancel()
			e := ws.Write(wctx, websocket.MessageBinary, out[:])
			if e != nil {
				fail(bridgeIOReason("cloud_write", e))
			}
			return e
		})
	}()
	<-ctx.Done()
	conn.Close()
	ws.CloseNow()
	wg.Wait()
	return reason
}
func mediaConnectReason(err error, response *http.Response) string {
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var unknownCA x509.UnknownAuthorityError
	var invalidCert x509.CertificateInvalidError
	var hostname x509.HostnameError
	var record tls.RecordHeaderError
	var network net.Error
	var operation *net.OpError
	var stage *mediaDialStageError
	timedOut := errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &network) && network.Timeout())
	if timedOut && errors.As(err, &stage) {
		switch stage.stage {
		case "tcp":
			return "media_connect_tcp_timeout"
		case "tls":
			return "media_connect_tls_timeout"
		case "dns":
			return "media_connect_dns"
		}
	}
	switch {
	case errors.As(err, &dns):
		return "media_connect_dns"
	case errors.As(err, &cert), errors.As(err, &unknownCA), errors.As(err, &invalidCert), errors.As(err, &hostname), errors.As(err, &record):
		return "media_connect_tls"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "media_connect_refused"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &network) && network.Timeout():
		return "media_connect_timeout"
	case errors.Is(err, context.Canceled):
		return "media_cancelled"
	case response != nil:
		return "media_connect_http"
	case errors.As(err, &operation) && operation.Op == "dial":
		return "media_connect_dial"
	default:
		return "media_connect_unknown"
	}
}

func bridgeIOReason(direction string, err error) string {
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout()) {
		return direction + "_timeout"
	}
	if strings.HasPrefix(direction, "cloud_") && websocket.CloseStatus(err) != -1 {
		return "cloud_remote_closed"
	}
	return direction + "_closed"
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
