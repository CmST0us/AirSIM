package integration

import (
	"airsim.local/server/internal/admin"
	"airsim.local/server/internal/control"
	"airsim.local/server/internal/media"
	"airsim.local/server/internal/wire"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"github.com/coder/websocket"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixture struct {
	t                             *testing.T
	dir, port, api, device, media string
	http                          *http.Client
	tokens                        [2]string
	clients                       [2]string
	modules                       [2]string
	tls                           [2]*tls.Config
	server                        string
}

func setup(t *testing.T) *fixture {
	t.Helper()
	dir := os.Getenv("AIRSIM_INTEGRATION_DIR")
	if dir == "" {
		t.Skip("explicit isolated Compose directory required")
	}
	port := os.Getenv("AIRSIM_EDGE_PORT")
	if port == "" {
		port = "18443"
	}
	f := &fixture{t: t, dir: dir, port: port, api: "https://api.airsim.test:" + port, device: "wss://device.airsim.test:" + port, media: "wss://media.airsim.test:" + port}
	root, e := os.ReadFile(filepath.Join(dir, "tls/root.pem"))
	if e != nil {
		t.Fatal("test_root_missing")
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(root)
	base := &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	f.http = f.client(base)
	for i := range 2 {
		var client struct {
			ID      string    `json:"client_installation_id"`
			Token   string    `json:"token"`
			Expires time.Time `json:"expires_at"`
		}
		f.file(fmt.Sprintf("client%d.json", i+1), &client)
		f.tokens[i] = client.Token
		f.clients[i] = client.ID
		var b admin.Bundle
		f.file(fmt.Sprintf("module%d-bundle.json", i+1), &b)
		f.modules[i] = b.Module
		f.server = b.Server
		key, e := os.ReadFile(filepath.Join(dir, fmt.Sprintf("module%d-key.pem", i+1)))
		if e != nil {
			t.Fatal("test_key_missing")
		}
		cert, e := tls.X509KeyPair([]byte(b.Certificate), key)
		if e != nil {
			t.Fatal("test_certificate_invalid")
		}
		cfg := base.Clone()
		cfg.Certificates = []tls.Certificate{cert}
		f.tls[i] = cfg
	}
	return f
}
func (f *fixture) file(name string, v any) {
	b, e := os.ReadFile(filepath.Join(f.dir, name))
	if e != nil || json.Unmarshal(b, v) != nil {
		f.t.Fatal("test_fixture_invalid")
	}
}
func (f *fixture) client(cfg *tls.Config) *http.Client {
	return &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil, TLSClientConfig: cfg, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, "127.0.0.1:"+f.port)
	}}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func (f *fixture) request(method, path string, client int, body any) (int, []byte) {
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(method, f.api+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if client >= 0 {
		req.Header.Set("Authorization", "Bearer "+f.tokens[client])
	}
	resp, e := f.http.Do(req)
	if e != nil {
		f.t.Fatal("api_transport_failed")
	}
	defer resp.Body.Close()
	b, e = io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if e != nil {
		f.t.Fatal("api_read_failed")
	}
	return resp.StatusCode, b
}
func (f *fixture) status(want int, method, path string, client int, body any) []byte {
	f.t.Helper()
	status, b := f.request(method, path, client, body)
	if status != want {
		var v map[string]any
		json.Unmarshal(b, &v)
		code, _ := v["error"].(string)
		f.t.Fatalf("%s expected %d got %d code=%s", method, want, status, code)
	}
	return b
}

type fake struct {
	f                    *fixture
	i                    int
	conn                 *websocket.Conn
	mu                   sync.Mutex
	sequence             uint64
	boot, backend, epoch string
	commands             chan control.Envelope
	done                 chan struct{}
	cancel               context.CancelFunc
	calls                []control.Call
}

func (f *fixture) connect(i int) *fake {
	ctx, cancel := context.WithCancel(context.Background())
	c, _, e := websocket.Dial(ctx, f.device+"/v2/device/control", &websocket.DialOptions{HTTPClient: f.client(f.tls[i]), Subprotocols: []string{"airsim.control.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		cancel()
		f.t.Fatal("device_tls_dial_failed")
	}
	p := &fake{f: f, i: i, conn: c, boot: wire.ID(), backend: wire.ID(), commands: make(chan control.Envelope, 32), done: make(chan struct{}), cancel: cancel, calls: []control.Call{}}
	p.send("hello", map[string]string{"agent_boot_id": p.boot, "backend_epoch": p.backend, "agent_version": "r4-test", "media_codec": "lc3"})
	rc, cc := context.WithTimeout(ctx, 5*time.Second)
	typ, b, e := c.Read(rc)
	cc()
	var env control.Envelope
	if e != nil || typ != websocket.MessageText || json.Unmarshal(b, &env) != nil || env.Type != "welcome" {
		f.t.Fatal("device_welcome_failed")
	}
	p.epoch = env.Epoch
	p.snapshot()
	go func() {
		defer close(p.done)
		for {
			typ, b, e := c.Read(ctx)
			if e != nil {
				return
			}
			if typ != websocket.MessageText || json.Unmarshal(b, &env) != nil {
				return
			}
			switch env.Type {
			case "heartbeat":
				p.send("heartbeat", struct{}{})
			default:
				select {
				case p.commands <- env:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return p
}
func (p *fake) send(kind string, v any) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sequence++
	payload, _ := json.Marshal(v)
	env := control.Envelope{Type: kind, Version: 2, Module: p.f.modules[p.i], Epoch: p.epoch, Sequence: p.sequence, Payload: payload}
	b, _ := json.Marshal(env)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = p.conn.Write(ctx, websocket.MessageText, b)
}
func (p *fake) snapshot() {
	p.send("snapshot", control.Snapshot{Boot: p.boot, Backend: p.backend, Observed: time.Now().UTC(), Control: control.Status{Schema: 1, Boot: p.boot, Backend: p.backend, Ready: true, Scope: "local_control", Telephony: true, Messaging: true, Remaining: 1024}, Calls: control.Calls{Boot: p.boot, Backend: p.backend, Available: true, Calls: p.calls}, Audio: json.RawMessage(`{"available":true,"implementation":"test","verification":"unverified","voice_ready":false,"reason":""}`)})
}
func (p *fake) close() { p.cancel(); p.conn.CloseNow(); <-p.done }
func (p *fake) next(kind string) control.Envelope {
	p.f.t.Helper()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case env := <-p.commands:
			if env.Type == kind {
				return env
			}
		case <-deadline.C:
			p.f.t.Fatalf("missing %s", kind)
		}
	}
}
func (p *fake) body(action string, args any) map[string]any {
	return map[string]any{"connection_epoch": p.epoch, "command": map[string]any{"command_id": wire.ID(), "agent_boot_id": p.boot, "backend_epoch": p.backend, "deadline": time.Now().UTC().Add(45 * time.Second).Format(time.RFC3339Nano), "action": action, "args": args}}
}
func (f *fixture) awaitOnline(module string, want bool) {
	f.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		_, b := f.request("GET", "/v2/modules/"+module+"/snapshot", 0, nil)
		var v struct {
			Online   bool              `json:"online"`
			Snapshot *control.Snapshot `json:"snapshot"`
		}
		json.Unmarshal(b, &v)
		if v.Online == want && (!want || v.Snapshot != nil) {
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	f.t.Fatal("online_state_timeout")
}
func TestComposeControlAndMedia(t *testing.T) {
	f := setup(t)
	f.status(401, "GET", "/v2/modules", -1, nil)
	f.status(200, "GET", "/.well-known/airsim", -1, nil)
	// Missing mTLS and forged identity headers must not reach a trusted device session.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, f.device+"/v2/device/control", &websocket.DialOptions{HTTPClient: f.http, Subprotocols: []string{"airsim.control.v2"}, HTTPHeader: http.Header{"X-AirSIM-Client-Cert": []string{"forged"}, "X-AirSIM-Edge-Token": []string{"forged"}}})
	if e == nil {
		c.CloseNow()
		t.Fatal("missing_certificate_accepted")
	}
	p := f.connect(0)
	defer p.close()
	q := f.connect(1)
	defer q.close()
	f.awaitOnline(f.modules[0], true)
	f.awaitOnline(f.modules[1], true)
	path := "/v2/modules/" + f.modules[0] + "/commands"
	sms := p.body("sms.send", map[string]string{"number": "+12025550123", "text": "synthetic fixture"})
	b := f.status(202, "POST", path, 0, sms)
	var first control.Record
	json.Unmarshal(b, &first)
	p.next("command")
	p.send("receipt", map[string]any{"command_id": first.ID, "status_code": 200, "receipt": control.Receipt{ID: first.ID, Action: "sms.send", State: "accepted", Code: "", Message: wire.ID(), Updated: time.Now().UTC()}})
	f.awaitReceipt(path+"/"+first.ID, "accepted")
	f.awaitOnline(f.modules[0], true)
	f.status(200, "POST", path, 0, sms)
	f.status(409, "POST", path, 1, sms)
	f.status(409, "POST", "/v2/modules/"+f.modules[1]+"/commands", 0, sms)
	select {
	case env := <-q.commands:
		if env.Type == "command" {
			t.Fatal("cross_module_delivery")
		}
	default:
	}
	old := p.body("sms.send", map[string]string{"number": "+12025550123", "text": "synthetic fixture"})
	old["connection_epoch"] = wire.ID()
	f.status(409, "POST", path, 0, old)
	dial := p.body("call.dial", map[string]string{"number": "+12025550123"})
	b = f.status(202, "POST", path, 0, dial)
	var rec control.Record
	json.Unmarshal(b, &rec)
	p.next("command")
	f.status(409, "POST", path, 1, p.body("call.dial", map[string]string{"number": "+12025550123"}))
	call := wire.ID()
	p.send("receipt", map[string]any{"command_id": rec.ID, "status_code": 200, "receipt": control.Receipt{ID: rec.ID, Action: "call.dial", State: "accepted", Code: "", Call: call, Updated: time.Now().UTC()}})
	p.calls = []control.Call{{ID: call, State: "active", Ownership: "managed", Direction: "outgoing", Observed: time.Now().UTC()}}
	p.snapshot()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b = f.status(200, "GET", path+"/"+rec.ID, 0, nil)
		var got control.Record
		json.Unmarshal(b, &got)
		if got.State == "completed" {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	f.awaitCall(f.modules[0], call, "active")
	f.status(409, "POST", path, 1, p.body("call.hangup", map[string]string{"call_id": call}))
	mp := "/v2/modules/" + f.modules[0] + "/calls/" + call + "/media-sessions"
	mb := map[string]string{"request_id": wire.ID(), "connection_epoch": p.epoch, "generation": rec.Generation, "codec": "lc3"}
	f.status(409, "POST", mp, 1, mb)
	b = f.status(201, "POST", mp, 0, mb)
	var result struct {
		Session string            `json:"session_id"`
		Format  media.AudioFormat `json:"format"`
		Ticket  string            `json:"ticket"`
	}
	json.Unmarshal(b, &result)
	f.status(200, "POST", mp, 0, mb)
	env := p.next("media_start")
	var start struct {
		Format media.AudioFormat `json:"format"`
		Ticket string            `json:"ticket"`
	}
	json.Unmarshal(env.Payload, &start)
	if start.Format != media.Format || result.Format != media.Format {
		t.Fatal("media_format_mismatch")
	}
	agent := f.mediaConnect(result.Session, "agent", start.Ticket)
	defer agent.CloseNow()
	client := f.mediaConnect(result.Session, "client", result.Ticket)
	defer client.CloseNow()
	f.mediaText(agent, "paired")
	f.mediaText(client, "paired")
	for i := uint64(1); i <= 10; i++ {
		f.frame(client, result.Session, 1, i)
		f.readFrame(agent, result.Session, 1, i)
		f.frame(agent, result.Session, 2, i)
		f.readFrame(client, result.Session, 2, i)
	}
	oldSession, oldTicket := result.Session, result.Ticket
	if _, err := exec.Command("docker", "restart", "--time", "1", "airsim-r4-test-media-1").CombinedOutput(); err != nil {
		t.Fatal("isolated_media_restart_failed")
	}
	faultCtx, faultCancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, _, faultErr := agent.Read(faultCtx)
	faultCancel()
	if faultErr == nil {
		t.Fatal("media_restart_did_not_close_peer")
	}
	reclaimed := false
	faultDeadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(faultDeadline) {
		status, _ := f.request("POST", mp, 0, mb)
		if status == 410 {
			reclaimed = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !reclaimed {
		t.Fatal("media_restart_not_reclaimed")
	}
	mb = map[string]string{"request_id": wire.ID(), "connection_epoch": p.epoch, "generation": rec.Generation, "codec": "lc3"}
	b = f.status(201, "POST", mp, 0, mb)
	json.Unmarshal(b, &result)
	env = p.next("media_start")
	json.Unmarshal(env.Payload, &start)
	if start.Format != media.Format || result.Format != media.Format {
		t.Fatal("media_format_mismatch")
	}
	agent = f.mediaConnect(result.Session, "agent", start.Ticket)
	defer agent.CloseNow()
	client = f.mediaConnect(result.Session, "client", result.Ticket)
	defer client.CloseNow()
	f.mediaText(agent, "paired")
	f.mediaText(client, "paired")
	replayCtx, replayCancel := context.WithTimeout(context.Background(), time.Second)
	replay, _, replayErr := websocket.Dial(replayCtx, f.media+"/v2/media", &websocket.DialOptions{HTTPClient: f.http, Subprotocols: []string{"airsim.media.v2"}})
	if replayErr != nil {
		t.Fatal("replay_transport_failed")
	}
	auth, _ := json.Marshal(map[string]string{"session_id": oldSession, "role": "client", "ticket": oldTicket})
	_ = replay.Write(replayCtx, websocket.MessageText, auth)
	_, _, replayErr = replay.Read(replayCtx)
	replay.CloseNow()
	replayCancel()
	if replayErr == nil {
		t.Fatal("old_media_ticket_survived_restart")
	}
	f.frame(client, result.Session, 1, 1)
	f.readFrame(agent, result.Session, 1, 1)
	f.frame(agent, result.Session, 2, 1)
	f.readFrame(client, result.Session, 2, 1)
	f.status(204, "DELETE", mp+"/"+result.Session, 0, nil)
	f.status(410, "POST", mp, 0, mb)
	ctx2, cc := context.WithTimeout(context.Background(), 2*time.Second)
	defer cc()
	if _, _, e = agent.Read(ctx2); e == nil {
		t.Fatal("revoked_media_still_open")
	}
	q.cancel()
	q.conn.CloseNow()
	f.awaitOnline(f.modules[1], false)
	f.status(503, "POST", "/v2/modules/"+f.modules[1]+"/commands", 0, q.body("sms.send", map[string]string{"number": "+12025550123", "text": "synthetic fixture"}))
	p.calls[0].State = "disconnected"
	p.snapshot()
	f.awaitCall(f.modules[0], call, "disconnected")
	incoming := wire.ID()
	p.calls = []control.Call{{ID: incoming, State: "incoming", Ownership: "incoming", Direction: "incoming", Observed: time.Now().UTC()}}
	p.snapshot()
	f.awaitCall(f.modules[0], incoming, "incoming")
	answer := p.body("call.answer", map[string]string{"call_id": incoming})
	answerBytes := f.status(202, "POST", path, 0, answer)
	var answerRec control.Record
	json.Unmarshal(answerBytes, &answerRec)
	p.next("command")
	p.send("receipt", map[string]any{"command_id": answerRec.ID, "status_code": 200, "receipt": control.Receipt{ID: answerRec.ID, Action: "call.answer", State: "accepted", Code: "", Call: incoming, Updated: time.Now().UTC()}})
	f.awaitReceipt(path+"/"+answerRec.ID, "accepted")
	p.calls[0].State = "active"
	p.calls[0].Ownership = "managed"
	p.snapshot()
	p.send("receipt", map[string]any{"command_id": answerRec.ID, "status_code": 200, "receipt": control.Receipt{ID: answerRec.ID, Action: "call.answer", State: "observed", Code: "", Call: incoming, Updated: time.Now().UTC()}})
	f.awaitReceipt(path+"/"+answerRec.ID, "observed")
	p.calls[0].State = "disconnected"
	p.snapshot()
	f.awaitCall(f.modules[0], incoming, "disconnected")

	f.status(200, "GET", "/v2/modules/"+f.modules[0]+"/snapshot", 0, nil)
	t.Log("TLS/mTLS, two-module routing, two-client ownership, persistent idempotency, old epoch, offline rejection, media pairing/duplex/revocation passed")
}
func (f *fixture) mediaConnect(id, role, ticket string) *websocket.Conn {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, f.media+"/v2/media", &websocket.DialOptions{HTTPClient: f.http, Subprotocols: []string{"airsim.media.v2"}})
	if e != nil {
		f.t.Fatal("media_dial_failed")
	}
	b, _ := json.Marshal(map[string]string{"session_id": id, "role": role, "ticket": ticket})
	if c.Write(ctx, websocket.MessageText, b) != nil {
		f.t.Fatal("media_auth_write_failed")
	}
	f.mediaText(c, "waiting")
	return c
}
func (f *fixture) mediaText(c *websocket.Conn, want string) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	typ, b, e := c.Read(ctx)
	var v struct {
		Type   string            `json:"type"`
		Format media.AudioFormat `json:"format"`
	}
	if e != nil || typ != websocket.MessageText || json.Unmarshal(b, &v) != nil || v.Type != want || (want == "paired" && v.Format != media.Format) {
		f.t.Fatal("media_handshake_failed")
	}
}
func (f *fixture) frame(c *websocket.Conn, id string, d byte, seq uint64) {
	b := make([]byte, 120)
	copy(b, "ASMP")
	b[4] = 2
	b[5] = d
	binary.LittleEndian.PutUint16(b[6:8], 40)
	sid, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	copy(b[8:24], sid)
	binary.LittleEndian.PutUint64(b[24:32], seq)
	binary.LittleEndian.PutUint32(b[32:36], 80)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if c.Write(ctx, websocket.MessageBinary, b) != nil {
		f.t.Fatal("media_frame_write_failed")
	}
}
func (f *fixture) readFrame(c *websocket.Conn, id string, d byte, seq uint64) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	typ, b, e := c.Read(ctx)
	if e != nil || typ != websocket.MessageBinary || !validReceivedFrame(b, id, d, seq) {
		f.t.Fatal("media_frame_read_failed")
	}
}
func TestRejectUnregisteredDeviceAndForgedAPIHeaders(t *testing.T) {
	f := setup(t)
	root, e := os.ReadFile(filepath.Join(f.dir, "identity/device-ca.pem"))
	if e != nil {
		t.Fatal("fixture_ca_missing")
	}
	keyPEM, e := os.ReadFile(filepath.Join(f.dir, "identity/device-ca-key.pem"))
	if e != nil {
		t.Fatal("fixture_ca_key_missing")
	}
	cb, _ := pem.Decode(root)
	kb, _ := pem.Decode(keyPEM)
	ca, e := x509.ParseCertificate(cb.Bytes)
	if e != nil {
		t.Fatal("fixture_ca_invalid")
	}
	key, e := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if e != nil {
		t.Fatal("fixture_key_invalid")
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	module := wire.ID()
	uri, _ := url.Parse("urn:airsim:" + f.server + ":module:" + module)
	cert := &x509.Certificate{SerialNumber: big.NewInt(12345), Subject: pkix.Name{CommonName: module}, URIs: []*url.URL{uri}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, KeyUsage: x509.KeyUsageDigitalSignature}
	der, e := x509.CreateCertificate(rand.Reader, cert, ca, pub, key)
	if e != nil {
		t.Fatal("fixture_cert_failed")
	}
	cfg := f.tls[0].Clone()
	cfg.Certificates = []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: priv}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, res, e := websocket.Dial(ctx, f.device+"/v2/device/control", &websocket.DialOptions{HTTPClient: f.client(cfg), Subprotocols: []string{"airsim.control.v2"}})
	if e == nil {
		c.CloseNow()
		t.Fatal("unknown_module_accepted")
	}
	if res == nil || res.StatusCode != 401 {
		t.Fatal("unknown_module_not_denied_by_control")
	}
	req, _ := http.NewRequest("GET", f.api+"/v2/modules", nil)
	req.Header.Set("Authorization", f.tokens[0])
	resp, e := f.http.Do(req)
	if e != nil {
		t.Fatal("api_transport_failed")
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatal("bare_token_accepted")
	}
	req, _ = http.NewRequest("GET", f.api+"/v2/device/control", nil)
	req.Header.Set("X-AirSIM-Client-Cert", "forged")
	req.Header.Set("X-AirSIM-Edge-Token", "forged")
	resp, e = f.http.Do(req)
	if e != nil {
		t.Fatal("api_transport_failed")
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatal("forged_identity_accepted")
	}
}
func TestReconnectAndControlRestartNeverRedispatch(t *testing.T) {
	f := setup(t)
	p := f.connect(1)
	f.awaitOnline(f.modules[1], true)
	path := "/v2/modules/" + f.modules[1] + "/commands"
	body := p.body("sms.send", map[string]string{"number": "+12025550123", "text": "synthetic fixture"})
	b := f.status(202, "POST", path, 0, body)
	var rec control.Record
	json.Unmarshal(b, &rec)
	p.next("command")
	p.close()
	f.awaitOnline(f.modules[1], false)
	f.status(200, "POST", path, 0, body)
	// Explicitly isolated container only; no project-wide operations or unrelated service access.
	cmd := exec.Command("docker", "restart", "--time", "1", "airsim-r4-test-control-1")
	if out, e := cmd.CombinedOutput(); e != nil {
		_ = out
		t.Fatal("isolated_control_restart_failed")
	}
	deadline := time.Now().Add(10 * time.Second)
	ready := false
	for time.Now().Before(deadline) {
		resp, e := f.http.Get(f.api + "/readyz")
		if e == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				ready = true
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("control_restart_not_ready")
	}
	b = f.status(200, "GET", path+"/"+rec.ID, 0, nil)
	var restored control.Record
	json.Unmarshal(b, &restored)
	if restored.State != "outcome_unknown" {
		t.Fatal("restart_receipt_not_unknown")
	}
	f.status(200, "POST", path, 0, body)
	q := f.connect(1)
	defer q.close()
	found := false
	timeout := time.After(3 * time.Second)
	for !found {
		select {
		case env := <-q.commands:
			if env.Type == "command" {
				t.Fatal("command_redispatched")
			}
			if env.Type == "receipt_query" {
				var query struct {
					ID string `json:"command_id"`
				}
				json.Unmarshal(env.Payload, &query)
				found = query.ID == rec.ID
			}
		case <-timeout:
			t.Fatal("missing_recovery_receipt_query")
		}
	}
	q.send("receipt", map[string]any{"command_id": rec.ID, "status_code": 200, "receipt": control.Receipt{ID: rec.ID, Action: "sms.send", State: "accepted", Code: "", Updated: time.Now().UTC()}})
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b = f.status(200, "GET", path+"/"+rec.ID, 0, nil)
		json.Unmarshal(b, &restored)
		if restored.State == "completed" {
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatal("recovered_receipt_not_applied")
}
func TestConnectedDeviceCertificateExpiry(t *testing.T) {
	f := setup(t)
	root, _ := os.ReadFile(filepath.Join(f.dir, "identity/device-ca.pem"))
	keyPEM, _ := os.ReadFile(filepath.Join(f.dir, "identity/device-ca-key.pem"))
	cb, _ := pem.Decode(root)
	kb, _ := pem.Decode(keyPEM)
	ca, e := x509.ParseCertificate(cb.Bytes)
	if e != nil {
		t.Fatal("fixture_ca_invalid")
	}
	key, e := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if e != nil {
		t.Fatal("fixture_key_invalid")
	}
	original, e := x509.ParseCertificate(f.tls[0].Certificates[0].Certificate[0])
	if e != nil {
		t.Fatal("fixture_leaf_invalid")
	}
	leaf := *original
	leaf.NotBefore = time.Now().Add(-time.Minute)
	leaf.NotAfter = time.Now().Add(3 * time.Second)
	der, e := x509.CreateCertificate(rand.Reader, &leaf, ca, original.PublicKey, key)
	if e != nil {
		t.Fatal("fixture_leaf_sign_failed")
	}
	f.tls[0] = f.tls[0].Clone()
	f.tls[0].Certificates = []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: f.tls[0].Certificates[0].PrivateKey}}
	p := f.connect(0)
	defer p.close()
	f.awaitOnline(f.modules[0], true)
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		t.Fatal("expired_device_connection_survived")
	}
	f.awaitOnline(f.modules[0], false)
}
func (f *fixture) awaitReceipt(path, state string) {
	f.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b := f.status(200, "GET", path, 0, nil)
		var record control.Record
		json.Unmarshal(b, &record)
		var receipt control.Receipt
		json.Unmarshal(record.Receipt, &receipt)
		if record.State == "completed" && receipt.State == state {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	f.t.Fatal("receipt_state_timeout")
}
func (f *fixture) awaitCall(module, call, state string) {
	f.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b := f.status(200, "GET", "/v2/modules/"+module+"/snapshot", 0, nil)
		var body struct {
			Snapshot *control.Snapshot `json:"snapshot"`
		}
		json.Unmarshal(b, &body)
		if body.Snapshot != nil {
			for _, c := range body.Snapshot.Calls.Calls {
				if c.ID == call && c.State == state {
					return
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	f.t.Fatal("call_state_timeout")
}
func TestFailedReservationsAndUnknownOwnership(t *testing.T) {
	f := setup(t)
	p := f.connect(0)
	defer p.close()
	f.awaitOnline(f.modules[0], true)
	path := "/v2/modules/" + f.modules[0] + "/commands"
	submit := func(client int, action string, args any) control.Record {
		b := f.status(202, "POST", path, client, p.body(action, args))
		var rec control.Record
		json.Unmarshal(b, &rec)
		p.next("command")
		return rec
	}
	send := func(rec control.Record, action, state, call string) {
		p.send("receipt", map[string]any{"command_id": rec.ID, "status_code": 200, "receipt": control.Receipt{ID: rec.ID, Action: action, State: state, Code: "", Call: call, Updated: time.Now().UTC()}})
	}
	dialArgs := map[string]string{"number": "+12025550123"}
	one := submit(0, "call.dial", dialArgs)
	send(one, "call.dial", "failed", "")
	f.awaitReceipt(path+"/"+one.ID, "failed")
	two := submit(1, "call.dial", dialArgs)
	send(two, "call.dial", "expired", "")
	f.awaitReceipt(path+"/"+two.ID, "expired")
	three := submit(0, "call.dial", dialArgs)
	send(three, "call.dial", "outcome_unknown", "")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		b := f.status(200, "GET", path+"/"+three.ID, 0, nil)
		var rec control.Record
		json.Unmarshal(b, &rec)
		if rec.State == "outcome_unknown" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	f.status(409, "POST", path, 1, p.body("call.dial", dialArgs))
	call := wire.ID()
	send(three, "call.dial", "accepted", call)
	p.calls = []control.Call{{ID: call, State: "active", Ownership: "managed", Direction: "outgoing", Observed: time.Now().UTC()}}
	p.snapshot()
	f.awaitReceipt(path+"/"+three.ID, "accepted")
	f.awaitCall(f.modules[0], call, "active")
	hangup := submit(0, "call.hangup", map[string]string{"call_id": call})
	send(hangup, "call.hangup", "failed", call)
	f.awaitReceipt(path+"/"+hangup.ID, "failed")
	f.status(409, "POST", path, 1, p.body("call.hangup", map[string]string{"call_id": call}))
	p.calls[0].State = "disconnected"
	p.snapshot()
	f.awaitCall(f.modules[0], call, "disconnected")
}

func validReceivedFrame(b []byte, id string, direction byte, sequence uint64) bool {
	got, ok := media.ValidateFrame(b, id, direction, sequence-1)
	return ok && got == sequence
}
