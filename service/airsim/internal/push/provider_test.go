package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func testProvider(t *testing.T) *Provider {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(t.TempDir(), "test.p8")
	if e := os.WriteFile(file, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600); e != nil {
		t.Fatal(e)
	}
	p, e := Load("test-key", "test-team", "com.example.test", file)
	if e != nil {
		t.Fatal(e)
	}
	return p
}
func TestConfig(t *testing.T) {
	p, e := Load("", "", "", "")
	if p != nil || e != nil {
		t.Fatal("disabled")
	}
	if _, e = Load("key", "", "", ""); e == nil {
		t.Fatal("partial configuration accepted")
	}
	file := filepath.Join(t.TempDir(), "bad.p8")
	_ = os.WriteFile(file, []byte("invalid"), 0600)
	if _, e = Load("key", "team", "bundle", file); e == nil {
		t.Fatal("invalid key accepted")
	}
	_ = os.Chmod(file, 0644)
	if _, e = Load("key", "team", "bundle", file); e == nil {
		t.Fatal("unrestricted key accepted")
	}
}
func TestAPNsContractAndJWT(t *testing.T) {
	p := testProvider(t)
	calls := 0
	p.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "api.sandbox.push.apple.com" || r.Header.Get("apns-expiration") != "0" || r.Header.Get("apns-priority") != "10" || r.Header.Get("apns-push-type") != "voip" || r.Header.Get("apns-topic") != "com.example.test.voip" {
			t.Fatal("APNs headers")
		}
		parts := strings.Split(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), ".")
		if len(parts) != 3 {
			t.Fatal("JWT")
		}
		raw, _ := base64.RawURLEncoding.DecodeString(parts[2])
		if len(raw) != 64 {
			t.Fatal("signature format")
		}
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if !ecdsa.Verify(&p.key.PublicKey, digest[:], new(big.Int).SetBytes(raw[:32]), new(big.Int).SetBytes(raw[32:])) {
			t.Fatal("signature")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}}, nil
	})
	_, e := p.Send(context.Background(), Notification{Token: strings.Repeat("a", 64), Environment: "sandbox", Topic: "com.example.test.voip", Kind: "voip", Payload: map[string]string{"event": "incoming_call"}})
	if e != nil || calls != 1 {
		t.Fatal("send")
	}
}
func TestAPNsFailureClassification(t *testing.T) {
	p := testProvider(t)
	for _, v := range []struct {
		code           int
		reason         string
		retry, invalid bool
	}{{410, "Unregistered", false, true}, {400, "BadDeviceToken", false, true}, {400, "DeviceTokenNotForTopic", false, true}, {429, "TooManyRequests", true, false}, {503, "ServiceUnavailable", true, false}, {403, "InvalidProviderToken", false, false}} {
		p.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: v.code, Body: io.NopCloser(strings.NewReader(`{"reason":"` + v.reason + `"}`)), Header: http.Header{}}, nil
		})
		result, e := p.Send(context.Background(), Notification{Token: "synthetic", Payload: map[string]string{}})
		if e == nil || result.Retry != v.retry || result.InvalidToken != v.invalid {
			t.Fatalf("classification %d", v.code)
		}
	}
}

func TestHTTP2Transport(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("APNs transport is not HTTP/2")
		}
		if r.Header.Get("apns-push-type") != "alert" || r.Header.Get("apns-topic") != "com.example.test" {
			t.Error("alert headers")
		}
		w.WriteHeader(200)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	p := testProvider(t)
	transport := p.client.Transport.(*http.Transport)
	transport.TLSClientConfig = server.Client().Transport.(*http.Transport).TLSClientConfig
	defer transport.CloseIdleConnections()
	p.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.push.apple.com" {
			t.Error("production endpoint")
		}
		r.URL.Host = server.Listener.Addr().String()
		return transport.RoundTrip(r)
	})
	if _, e := p.Send(context.Background(), Notification{Token: "synthetic", Environment: "production", Topic: "com.example.test", Kind: "alert", Payload: map[string]string{"event": "incoming_sms"}}); e != nil {
		t.Fatal(e)
	}
}
