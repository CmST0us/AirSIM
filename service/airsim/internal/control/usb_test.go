package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestUSBAuthorizationLifecycle(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"success", "client", "server", "module", "expiry", "origin", "certificate", "token", "legacy", "disconnect", "cancel", "timeout", "unavailable", "replacement"} {
		t.Run(mode, func(t *testing.T) {
			s := New(nil, Config{Server: wire.ID()})
			pctx, pcancel := context.WithCancel(context.Background())
			defer pcancel()
			p := &peer{module: wire.ID(), epoch: wire.ID(), usbLocal: mode != "legacy", ctx: pctx, cancel: pcancel, queue: make(chan Envelope, 32)}
			s.peers[p.module] = p
			client := wire.ID()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			r := httptest.NewRequest("POST", "/", strings.NewReader(`{}`)).WithContext(ctx)
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			done := make(chan struct{})
			go func() { defer close(done); s.usbAuthorization(w, r, client, p.module) }()
			if mode != "legacy" {
				var env Envelope
				select {
				case env = <-p.queue:
				case <-time.After(time.Second):
					t.Fatal("missing request")
				}
				var req struct {
					Request string    `json:"request_id"`
					Client  string    `json:"client_installation_id"`
					Expires time.Time `json:"expires_at"`
				}
				if env.Type != "usb_authorize" || json.Unmarshal(env.Payload, &req) != nil || req.Client != client {
					t.Fatal("invalid request")
				}
				if mode == "disconnect" {
					pcancel()
				} else if mode == "cancel" {
					cancel()
				} else if mode == "replacement" {
					s.mu.Lock()
					s.peers[p.module] = &peer{}
					s.mu.Unlock()
					pcancel()
				} else if mode != "timeout" {
					a := &usbAuthorization{Server: s.cfg.Server, Module: p.module, Client: client, Origin: "https://192.168.225.1:8577", Certificate: base64.StdEncoding.EncodeToString(der), Token: wire.Token(), Expires: req.Expires}
					status := 200
					switch mode {
					case "client":
						a.Client = wire.ID()
					case "server":
						a.Server = wire.ID()
					case "module":
						a.Module = wire.ID()
					case "expiry":
						a.Expires = a.Expires.Add(time.Second)
					case "origin":
						a.Origin = "https://8.8.8.8:8577"
					case "certificate":
						a.Certificate = "AQ=="
					case "token":
						a.Token = "invalid"
					case "unavailable":
						status = 503
						a = nil
					}
					payload, _ := json.Marshal(map[string]any{"request_id": req.Request, "status_code": status, "authorization": a})
					s.mu.Lock()
					valid := s.consume(p, Envelope{Type: "usb_authorization", Payload: payload})
					s.mu.Unlock()
					if valid != (mode == "success" || mode == "unavailable") {
						t.Fatal("wrong response validation")
					}
					if !valid {
						cancel()
					}
				}
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("request did not finish")
			}
			want := 503
			if mode == "success" {
				want = 200
			}
			if w.Code != want || len(p.usbRequests) != 0 || len(p.queue) != 0 {
				t.Fatal("response or cleanup mismatch")
			}
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("missing no-store")
			}
		})
	}
}

func TestUSBResponseConnectionBinding(t *testing.T) {
	s := New(nil, Config{Server: wire.ID()})
	p := &peer{module: wire.ID(), usbLocal: true, usbRequests: map[string]*usbRequest{}}
	s.peers[p.module] = p
	id := wire.ID()
	pending := &usbRequest{client: wire.ID(), result: make(chan *usbAuthorization, 1)}
	p.usbRequests[id] = pending
	payload, _ := json.Marshal(map[string]any{"request_id": wire.ID(), "status_code": 503, "authorization": nil})
	if !s.usbResponse(p, payload) || len(pending.result) != 0 {
		t.Fatal("unknown request affected waiter")
	}
	payload, _ = json.Marshal(map[string]any{"request_id": id, "status_code": 503, "authorization": nil})
	s.peers[p.module] = &peer{}
	if s.usbResponse(p, payload) || len(pending.result) != 0 {
		t.Fatal("old connection accepted")
	}
}

func TestUSBRevokeCancelsWaiterAndDeduplicates(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := wire.ID()
	pending := &usbRequest{client: client, result: make(chan *usbAuthorization, 1)}
	other := &usbRequest{client: wire.ID(), result: make(chan *usbAuthorization, 1)}
	p := &peer{usbLocal: true, ctx: ctx, cancel: cancel, queue: make(chan Envelope, 32), usbRequests: map[string]*usbRequest{"old": pending, "other": other}}
	s := New(nil, Config{})
	s.revokeUSB(p, client)
	s.revokeUSB(p, client)
	if len(p.queue) != 1 || len(pending.result) != 1 || len(other.result) != 0 || len(p.usbRequests) != 1 {
		t.Fatal("revocation did not isolate and clear matching waiter")
	}
	if (<-p.queue).Type != "usb_revoke" {
		t.Fatal("wrong revoke frame")
	}
	p.usbLocal = false
	s.revokeUSB(p, wire.ID())
	if len(p.queue) != 0 {
		t.Fatal("legacy peer received revoke")
	}
}
