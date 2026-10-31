package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"bytes"
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"github.com/coder/websocket"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func tlsServer(t *testing.T, f *fixture, h http.Handler) *httptest.Server {
	t.Helper()
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(10), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, cert, f.ca, pub, f.key)
	if e != nil {
		t.Fatal(e)
	}
	pool := x509.NewCertPool()
	pool.AddCert(f.ca)
	s := httptest.NewUnstartedServer(h)
	s.Config.ErrorLog = log.New(io.Discard, "", 0)
	s.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, ClientCAs: pool, ClientAuth: tls.VerifyClientCertIfGiven, MinVersion: tls.VersionTLS12}
	s.StartTLS()
	t.Cleanup(s.Close)
	return s
}
func discovery(f *fixture) any {
	return map[string]any{"protocol_version": 2, "profile": Profile, "server_id": f.req.ServerID, "api_origin": f.req.API, "device_origin": f.req.Device, "media_origin": f.req.Media, "capabilities": map[string]bool{"controlled_test_client": true, "telephony": true, "messaging": true, "experimental_audio": true, "apns": false, "interactive_login": false}}
}

type fakeControl struct {
	boot, epoch, call string
	submitted         atomic.Int32
	mu                sync.Mutex
	commands          map[string]control.Request
}

func (fc *fakeControl) Submit(ctx context.Context, r control.Request) (any, int) {
	fc.submitted.Add(1)
	fc.mu.Lock()
	defer fc.mu.Unlock()
	fc.commands[r.CommandID] = r
	return map[string]any{"command_id": r.CommandID, "state": "prepared"}, 202
}
func (fc *fakeControl) View(ctx context.Context, kind, id string) (any, int) {
	switch kind {
	case "control":
		return control.Status{Boot: fc.boot, Epoch: fc.epoch, Ready: true}, 200
	case "calls":
		return control.CallsView{Boot: fc.boot, Epoch: fc.epoch, Available: true, Calls: []control.Call{{ID: fc.call, State: "active", Ownership: "managed"}}}, 200
	case "cloud_messages":
		return control.MessagesView{Boot: fc.boot, Epoch: fc.epoch, Available: true, Messages: []control.Message{}}, 200
	case "command":
		fc.mu.Lock()
		defer fc.mu.Unlock()
		if _, ok := fc.commands[id]; ok {
			return map[string]any{"command_id": id, "state": "observed", "call_id": fc.call}, 200
		}
		return nil, 404
	}
	return nil, 404
}

type fakeMedia struct {
	socket, id, token string
	stops             atomic.Int32
	creates           atomic.Int32
}

func (f *fakeMedia) View() media.Status {
	return media.Status{Available: true, Implementation: "implemented", Verification: "unverified"}
}
func (f *fakeMedia) Create(ctx context.Context, r media.Request) (media.Created, int) {
	f.creates.Add(1)
	return media.Created{ID: f.id, Token: f.token, Socket: f.socket, Format: media.LC3Format}, 201
}
func (f *fakeMedia) Stop(id string) int {
	if id == f.id {
		f.stops.Add(1)
	}
	return 204
}
func TestTLSControlDiscoveryCommandsReceiptsAndGeneration(t *testing.T) {
	f := newFixture(t)
	fc := &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}
	epoch := uid()
	seen := make(chan string, 8)
	s := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/.well-known/airsim" {
			json.NewEncoder(w).Encode(discovery(f))
			return
		}
		if r.URL.Path != "/v2/device/control" || len(r.TLS.VerifiedChains) == 0 {
			w.WriteHeader(403)
			return
		}
		ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.control.v2"}, CompressionMode: websocket.CompressionDisabled})
		if e != nil {
			return
		}
		defer ws.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()
		_, b, e := ws.Read(ctx)
		if e != nil {
			return
		}
		var hello envelope
		if json.Unmarshal(b, &hello) != nil || hello.Type != "hello" || hello.Epoch != "" || hello.Sequence != 1 {
			return
		}
		seen <- "mtls_hello"
		send := func(kind string, seq uint64, p any) {
			raw, _ := json.Marshal(p)
			wire, _ := json.Marshal(envelope{kind, 2, f.p.id.ModuleID, epoch, seq, raw})
			ws.Write(ctx, websocket.MessageText, wire)
		}
		send("welcome", 1, map[string]any{"server_id": f.req.ServerID, "heartbeat_seconds": 5})
		req := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Deadline: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano), Action: "call.answer", Args: control.Args{CallID: fc.call}}
		send("command", 2, map[string]any{"client_installation_id": uid(), "generation": uid(), "command": req})
		last := uint64(1)
		for {
			_, b, e = ws.Read(ctx)
			if e != nil {
				return
			}
			frame, e := parseEnvelope(b, f.p.id.ModuleID, epoch, last+1, false)
			if e != nil {
				return
			}
			last++
			if frame.Type == "snapshot" || frame.Type == "messages" {
				seen <- frame.Type
			}
			if frame.Type == "receipt" {
				var body struct {
					Receipt struct {
						State string `json:"state"`
					} `json:"receipt"`
				}
				json.Unmarshal(frame.Payload, &body)
				if body.Receipt.State == "observed" {
					seen <- "observed"
					send("heartbeat", 99, struct{}{})
					_, _, _ = ws.Read(ctx)
					return
				}
			}
		}
	}))
	f.req.API = s.URL
	f.req.Device = s.URL
	f.req.Media = s.URL
	f.prepare(t)
	f.issue(t)
	if f.p.Activate(f.bundle) != 200 {
		t.Fatal("activation")
	}
	a := &Agent{P: f.p, Control: fc, Media: &fakeMedia{}, Boot: fc.boot, Version: "test", owners: map[string]owner{}, bindings: map[string]string{}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := a.connect(ctx, f.p.config)
	if result != "control_disconnected" {
		t.Fatal("generation close", result)
	}
	if fc.submitted.Load() != 1 {
		t.Fatal("submit count")
	}
	close(seen)
	got := map[string]bool{}
	for v := range seen {
		got[v] = true
	}
	for _, v := range []string{"mtls_hello", "snapshot", "messages", "observed"} {
		if !got[v] {
			t.Fatal("missing", v)
		}
	}
	if len(a.owners) != 1 {
		t.Fatal("owner receipt not retained")
	}
	// Valid TLS but altered discovery bindings must never redirect or connect.
	changed := *f.p.config
	changed.Request.ServerID = uid()
	if a.discover(ctx, &changed) == nil {
		t.Fatal("discovery binding accepted")
	}
	wrong := *f.p.config
	_, _, wrongCA := newCA(t)
	wrong.Request.ServerCA = wrongCA
	if a.discover(ctx, &wrong) == nil {
		t.Fatal("wrong TLS root accepted")
	}
}
func TestMediaBridgeTLSUnixMappingAndCleanup(t *testing.T) {
	for _, erasure := range []bool{false, true} {
		t.Run(map[bool]string{false: "lc3", true: "erasure"}[erasure], func(t *testing.T) {
			f := newFixture(t)
			localID, cloudID := uid(), uid()
			dir, e := os.MkdirTemp("/tmp", "r4-bridge-")
			if e != nil {
				t.Fatal(e)
			}
			defer os.RemoveAll(dir)
			socket := filepath.Join(dir, "media.sock")
			listener, e := net.Listen("unix", socket)
			if e != nil {
				t.Fatal(e)
			}
			defer listener.Close()
			fm := &fakeMedia{socket: socket, id: localID, token: strings.Repeat("cd", 32)}
			localSeen := make(chan media.Frame, 1)
			localDone := make(chan struct{})
			go func() {
				defer close(localDone)
				conn, e := listener.Accept()
				if e != nil {
					return
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(4 * time.Second))
				b, e := media.ReadJSON(conn, 1024)
				if e != nil {
					return
				}
				var auth map[string]string
				json.Unmarshal(b, &auth)
				if auth["session_id"] != localID || auth["token"] != fm.token {
					return
				}
				media.WriteJSON(conn, map[string]any{"ok": true, "codec": "lc3", "codec_frame_us": 10000, "codec_frame_bytes": 40, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}, 1024)
				var last uint64
				for {
					in, _, e := media.ReadFrame(conn, localID, 1, &last)
					if e != nil {
						return
					}
					if (!erasure && in[40] != 37) || (erasure && in[36] != 1) {
						continue
					}
					localSeen <- in
					out := media.NewFrame(localID, 2, 3)
					copy(out[36:], in[36:])
					writeFrame(conn, out[:])
					io.Copy(io.Discard, conn)
					return
				}
			}()
			cloudSeen := make(chan media.Frame, 1)
			server := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}})
				if e != nil {
					return
				}
				defer ws.CloseNow()
				ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
				defer cancel()
				_, b, e := ws.Read(ctx)
				if e != nil {
					return
				}
				var auth map[string]string
				json.Unmarshal(b, &auth)
				if auth["role"] != "agent" || auth["session_id"] != cloudID {
					return
				}
				waiting, _ := json.Marshal(map[string]string{"type": "waiting", "session_id": cloudID})
				ws.Write(ctx, websocket.MessageText, waiting)
				paired, _ := json.Marshal(map[string]any{"type": "paired", "session_id": cloudID, "format": media.LC3Format})
				ws.Write(ctx, websocket.MessageText, paired)
				frame := media.NewFrame(cloudID, 1, 4)
				for i := 40; i < len(frame); i++ {
					frame[i] = 37
				}
				if erasure {
					frame.Erase()
				}
				ws.Write(ctx, websocket.MessageBinary, frame[:])
				typ, b, e := ws.Read(ctx)
				if e != nil || typ != websocket.MessageBinary {
					return
				}
				var seq uint64
				out, _, e := media.ReadFrame(bytes.NewReader(b), cloudID, 2, &seq)
				if e == nil {
					cloudSeen <- out
				}
			}))
			f.req.API = server.URL
			f.req.Device = server.URL
			f.req.Media = server.URL
			f.prepare(t)
			f.issue(t)
			f.p.Activate(f.bundle)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			a := &Agent{P: f.p, Media: fm}
			c := &connection{agent: a, config: f.p.config, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 32)}
			reason := c.bridge(ctx, mediaStart{Format: json.RawMessage(`{"codec":"lc3","sample_rate":16000,"channels":1,"sample_format":"s16le","frame_samples":320,"codec_frame_us":10000,"codec_frame_bytes":40}`), Request: uid(), Session: cloudID, Call: uid(), Boot: uid(), Epoch: uid(), Ticket: strings.Repeat("ab", 32), Expires: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano)})
			if reason != "cloud_read_closed" && reason != "cloud_remote_closed" && reason != "local_read_closed" {
				t.Fatal(reason)
			}
			select {
			case in := <-localSeen:
				if (!erasure && in[40] != 37) || (erasure && in[36] != 1) {
					t.Fatal("local payload")
				}
			default:
				t.Fatal("no local frame")
			}
			select {
			case out := <-cloudSeen:
				if erasure && out[36] != 1 {
					t.Fatal("lost erasure flag")
				}
				for _, b := range out[40:] {
					if (!erasure && b != 37) || (erasure && b != 0) {
						t.Fatal("PCM changed")
					}
				}
			default:
				t.Fatal("no cloud frame")
			}
			if fm.stops.Load() != 1 {
				t.Fatal("local cleanup")
			}
			stats := a.LastBridgeStats()
			if stats.CloudInputGaps != 3 || stats.LocalInputGaps != 2 {
				t.Fatal("gap counters", stats)
			}
			select {
			case <-localDone:
			case <-time.After(time.Second):
				t.Fatal("local goroutine leak")
			}
		})
	}
}

func TestTLSControlConnectionEndsAtCertificateExpiry(t *testing.T) {
	f := newFixture(t)
	fc := &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}
	welcomed := make(chan struct{}, 1)
	closed := make(chan time.Time, 1)
	server := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/.well-known/airsim" {
			json.NewEncoder(w).Encode(discovery(f))
			return
		}
		if len(r.TLS.VerifiedChains) == 0 {
			w.WriteHeader(403)
			return
		}
		ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.control.v2"}})
		if e != nil {
			return
		}
		defer ws.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 7*time.Second)
		defer cancel()
		_, b, e := ws.Read(ctx)
		if e != nil {
			return
		}
		var hello envelope
		if json.Unmarshal(b, &hello) != nil || hello.Type != "hello" {
			return
		}
		payload, _ := json.Marshal(map[string]any{"server_id": f.req.ServerID, "heartbeat_seconds": 5})
		welcome, _ := json.Marshal(envelope{Type: "welcome", Protocol: 2, Module: f.p.id.ModuleID, Epoch: uid(), Sequence: 1, Payload: payload})
		if ws.Write(ctx, websocket.MessageText, welcome) != nil {
			return
		}
		welcomed <- struct{}{}
		for {
			if _, _, e := ws.Read(ctx); e != nil {
				closed <- time.Now()
				return
			}
		}
	}))
	f.req.API = server.URL
	f.req.Device = server.URL
	f.req.Media = server.URL
	f.prepare(t)
	f.issue(t)
	block, _ := pem.Decode([]byte(f.bundle.Certificate))
	cert, e := x509.ParseCertificate(block.Bytes)
	if e != nil {
		t.Fatal(e)
	}
	cert.NotAfter = time.Now().Add(3 * time.Second).Truncate(time.Second)
	der, e := x509.CreateCertificate(rand.Reader, cert, f.ca, cert.PublicKey, f.key)
	if e != nil {
		t.Fatal(e)
	}
	f.bundle.Certificate = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	sig, e := f.key.Sign(rand.Reader, receiptBytes(f.req, f.bundle, der), crypto.Hash(0))
	if e != nil {
		t.Fatal(e)
	}
	f.bundle.Receipt = base64.StdEncoding.EncodeToString(sig)
	if f.p.Activate(f.bundle) != 200 {
		t.Fatal("short certificate activation")
	}
	a := &Agent{P: f.p, Control: fc, Media: &fakeMedia{}, Boot: fc.boot, Version: "test", owners: map[string]owner{}, bindings: map[string]string{}}
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
	defer cancel()
	result := make(chan string, 1)
	go func() { result <- a.connect(ctx, f.p.config) }()
	select {
	case <-welcomed:
	case <-ctx.Done():
		t.Fatal("no live mTLS welcome")
	}
	select {
	case code := <-result:
		if code != "certificate_expired" {
			t.Fatal("expiry reason", code)
		}
		if time.Now().Before(cert.NotAfter) || time.Since(cert.NotAfter) > 500*time.Millisecond {
			t.Fatal("not bounded by certificate deadline")
		}
	case <-ctx.Done():
		t.Fatal("connection outlived certificate")
	}
	select {
	case at := <-closed:
		if at.Before(cert.NotAfter) || at.Sub(cert.NotAfter) > 500*time.Millisecond {
			t.Fatal("TLS socket lifetime")
		}
	case <-ctx.Done():
		t.Fatal("TLS peer still open")
	}
	status := a.P.View()
	if status.Connected || status.Epoch != "" || status.LastError != "certificate_expired" {
		t.Fatal("expiry status", status.LastError)
	}
	if code := a.connect(ctx, f.p.config); code != "certificate_invalid" {
		t.Fatal("expired certificate reused", code)
	}
	if fc.submitted.Load() != 0 {
		t.Fatal("unexpected command side effect")
	}
}

// Keep one input flowing while the other stops after its first real frame.
// Neither playout ticks nor downlink silence may renew either read deadline.
func TestMediaBridgeRealInputDeadlineDespitePlayout(t *testing.T) {
	for _, name := range []string{"cloud_stalls", "local_stalls", "sustained_bidirectional"} {
		stallLocal := name == "local_stalls"
		sustained := name == "sustained_bidirectional"
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			localID, cloudID := uid(), uid()
			dir, e := os.MkdirTemp("/tmp", "r4-deadline-")
			if e != nil {
				t.Fatal(e)
			}
			defer os.RemoveAll(dir)
			socket := filepath.Join(dir, "media.sock")
			listener, e := net.Listen("unix", socket)
			if e != nil {
				t.Fatal(e)
			}
			defer listener.Close()
			fm := &fakeMedia{socket: socket, id: localID, token: strings.Repeat("cd", 32)}
			var localReceived, cloudReceived atomic.Int64
			localDone := make(chan struct{})
			go func() {
				defer close(localDone)
				conn, e := listener.Accept()
				if e != nil {
					return
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(12 * time.Second))
				if _, e = media.ReadJSON(conn, 1024); e != nil {
					return
				}
				if media.WriteJSON(conn, map[string]any{"ok": true, "codec": "lc3", "codec_frame_us": 10000, "codec_frame_bytes": 40, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}, 1024) != nil {
					return
				}
				sendCtx, stop := context.WithCancel(context.Background())
				writerDone := make(chan struct{})
				go func() {
					defer close(writerDone)
					tick := time.NewTicker(20 * time.Millisecond)
					defer tick.Stop()
					for seq := uint64(1); ; seq++ {
						out := media.NewFrame(localID, 2, seq)
						if writeFrame(conn, out[:]) != nil {
							return
						}
						if stallLocal && !sustained {
							return
						}
						select {
						case <-sendCtx.Done():
							return
						case <-tick.C:
						}
					}
				}()
				n, _ := io.Copy(io.Discard, conn)
				localReceived.Store(n / media.FrameSize)
				stop()
				conn.Close()
				<-writerDone
			}()
			cloudDone := make(chan struct{})
			server := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(cloudDone)
				ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}})
				if e != nil {
					return
				}
				defer ws.CloseNow()
				peerCtx, stop := context.WithTimeout(r.Context(), 12*time.Second)
				defer stop()
				if _, _, e = ws.Read(peerCtx); e != nil {
					return
				}
				paired, _ := json.Marshal(map[string]any{"type": "paired", "session_id": cloudID, "format": media.LC3Format})
				if ws.Write(peerCtx, websocket.MessageText, paired) != nil {
					return
				}
				writerDone := make(chan struct{})
				go func() {
					defer close(writerDone)
					tick := time.NewTicker(20 * time.Millisecond)
					defer tick.Stop()
					for seq := uint64(1); ; seq++ {
						out := media.NewFrame(cloudID, 1, seq)
						if ws.Write(peerCtx, websocket.MessageBinary, out[:]) != nil {
							return
						}
						if !stallLocal && !sustained {
							return
						}
						select {
						case <-peerCtx.Done():
							return
						case <-tick.C:
						}
					}
				}()
				for {
					if _, _, e = ws.Read(peerCtx); e != nil {
						break
					}
					cloudReceived.Add(1)
				}
				stop()
				ws.CloseNow()
				<-writerDone
			}))
			f.req.API = server.URL
			f.req.Device = server.URL
			f.req.Media = server.URL
			f.prepare(t)
			f.issue(t)
			f.p.Activate(f.bundle)
			duration := 5 * time.Second
			if sustained {
				duration = 9 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), duration)
			defer cancel()
			a := &Agent{P: f.p, Media: fm}
			c := &connection{agent: a, config: f.p.config, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 32)}
			start := time.Now()
			reason := c.bridge(ctx, mediaStart{Format: json.RawMessage(`{"codec":"lc3","sample_rate":16000,"channels":1,"sample_format":"s16le","frame_samples":320,"codec_frame_us":10000,"codec_frame_bytes":40}`), Request: uid(), Session: cloudID, Call: uid(), Boot: uid(), Epoch: uid(), Ticket: strings.Repeat("ab", 32), Expires: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339Nano)})
			elapsed := time.Since(start)
			want := "cloud_read_timeout"
			if stallLocal && !sustained {
				want = "local_read_timeout"
			}
			minElapsed, maxElapsed := 1900*time.Millisecond, 3*time.Second
			if sustained {
				want = "media_cancelled"
				minElapsed = 8 * time.Second
				maxElapsed = 10 * time.Second
			}
			if reason != want || elapsed < minElapsed || elapsed > maxElapsed {
				t.Fatalf("read deadline: %s %v", reason, elapsed)
			}
			if !sustained && !stallLocal && a.LastBridgeStats().ZeroFrames < 50 {
				t.Fatal("downlink silence did not exercise read deadline")
			}
			if fm.stops.Load() != 1 {
				t.Fatal("cleanup")
			}
			for _, done := range []chan struct{}{localDone, cloudDone} {
				select {
				case <-done:
				case <-time.After(time.Second):
					t.Fatal("peer goroutine leak")
				}
			}
			if sustained {
				if localReceived.Load() < 350 || cloudReceived.Load() < 350 {
					t.Fatalf("sustained frames local=%d cloud=%d", localReceived.Load(), cloudReceived.Load())
				}
				t.Logf("sustained %s: local=%d cloud=%d", elapsed, localReceived.Load(), cloudReceived.Load())
			}
		})
	}
}

func TestDiscoveryAPNsProfiles(t *testing.T) {
	for _, tc := range []struct {
		name, profile  string
		apns, accepted bool
	}{
		{"r4_without_push", Profile, false, true},
		{"r4_with_push", Profile, true, false},
		{"callkit_without_push", "airsim-v2-callkit", false, true},
		{"callkit_with_push", "airsim-v2-callkit", true, true},
		{"unknown", "unknown", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			server := tlsServer(t, f, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				d := discovery(f).(map[string]any)
				d["profile"] = tc.profile
				d["capabilities"].(map[string]bool)["apns"] = tc.apns
				json.NewEncoder(w).Encode(d)
			}))
			f.req.API, f.req.Device, f.req.Media = server.URL, server.URL, server.URL
			f.prepare(t)
			f.issue(t)
			if f.p.Activate(f.bundle) != 200 {
				t.Fatal("activation")
			}
			a := &Agent{P: f.p}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := a.discover(ctx, f.p.config); (err == nil) != tc.accepted {
				t.Fatalf("accepted=%v, error=%v", tc.accepted, err)
			}
		})
	}
}

type snapshotControl struct {
	fakeControl
	state string
}

func (f *snapshotControl) View(ctx context.Context, kind, id string) (any, int) {
	if kind == "calls" {
		return control.CallsView{Boot: f.boot, Epoch: f.epoch, Available: true, Calls: []control.Call{{ID: f.call, State: f.state}}}, 200
	}
	return f.fakeControl.View(ctx, kind, id)
}
func TestSnapshotRefreshDuringCalls(t *testing.T) {
	for _, state := range []string{"incoming", "dialing", "active", "disconnected"} {
		t.Run(state, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			fc := &snapshotControl{fakeControl: fakeControl{boot: uid(), epoch: uid(), call: uid()}, state: state}
			c := &connection{agent: &Agent{Control: fc, Media: &fakeMedia{}}, ctx: ctx, cancel: cancel, queue: make(chan outgoing, 8)}
			var snap, messages string
			var sent time.Time
			if !c.sync(&snap, &messages, &sent) {
				t.Fatal("initial snapshot")
			}
			for len(c.queue) > 0 {
				<-c.queue
			}
			sent = time.Now().Add(-2 * time.Second)
			if !c.sync(&snap, &messages, &sent) {
				t.Fatal("refresh")
			}
			got := false
			for len(c.queue) > 0 {
				if (<-c.queue).kind == "snapshot" {
					got = true
				}
			}
			if got != (state != "disconnected") {
				t.Fatalf("snapshot refresh=%v", got)
			}
		})
	}
}
