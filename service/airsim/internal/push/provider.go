// Package push implements the APNs provider used by the control service.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

type Notification struct {
	Token, Environment, Topic, Kind string
	Payload                         any
}
type Result struct{ Retry, InvalidToken bool }
type Sender interface {
	Send(context.Context, Notification) (Result, error)
}
type Provider struct {
	key           *ecdsa.PrivateKey
	keyID, teamID string
	client        *http.Client
	mu            sync.Mutex
	jwt           string
	issued        time.Time
}

func Load(keyID, teamID, bundleID, file string) (*Provider, error) {
	if keyID == "" && teamID == "" && bundleID == "" && file == "" {
		return nil, nil
	}
	if keyID == "" || teamID == "" || bundleID == "" || file == "" {
		return nil, errors.New("apns_config_incomplete")
	}
	info, e := os.Stat(file)
	if e != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("apns_key_permissions")
	}
	b, e := os.ReadFile(file)
	if e != nil {
		return nil, errors.New("apns_key_unreadable")
	}
	block, rest := pem.Decode(b)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("apns_key_invalid")
	}
	key, e := x509.ParsePKCS8PrivateKey(block.Bytes)
	if e != nil {
		return nil, errors.New("apns_key_invalid")
	}
	ec, ok := key.(*ecdsa.PrivateKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, errors.New("apns_key_invalid")
	}
	return &Provider{key: ec, keyID: keyID, teamID: teamID, client: &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{ForceAttemptHTTP2: true, MaxConnsPerHost: 16, MaxIdleConnsPerHost: 16, IdleConnTimeout: time.Minute, TLSHandshakeTimeout: 3 * time.Second}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (p *Provider) token() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jwt != "" && time.Since(p.issued) < 50*time.Minute {
		return p.jwt, nil
	}
	encode := func(v any) string { b, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(b) }
	now := time.Now()
	unsigned := encode(map[string]any{"alg": "ES256", "kid": p.keyID}) + "." + encode(map[string]any{"iss": p.teamID, "iat": now.Unix()})
	digest := sha256.Sum256([]byte(unsigned))
	r, s, e := ecdsa.Sign(rand.Reader, p.key, digest[:])
	if e != nil {
		return "", errors.New("apns_sign_failed")
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	p.jwt = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	p.issued = now
	return p.jwt, nil
}
func (p *Provider) Send(ctx context.Context, n Notification) (Result, error) {
	b, e := json.Marshal(n.Payload)
	if e != nil || len(b) > 4096 {
		return Result{}, errors.New("apns_payload_invalid")
	}
	jwt, e := p.token()
	if e != nil {
		return Result{}, e
	}
	host := "https://api.push.apple.com"
	if n.Environment == "sandbox" {
		host = "https://api.sandbox.push.apple.com"
	}
	req, e := http.NewRequestWithContext(ctx, "POST", host+"/3/device/"+n.Token, bytes.NewReader(b))
	if e != nil {
		return Result{}, errors.New("apns_request_invalid")
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("content-type", "application/json")
	req.Header.Set("apns-topic", n.Topic)
	req.Header.Set("apns-push-type", n.Kind)
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", "0")
	res, e := p.client.Do(req)
	if e != nil {
		return Result{Retry: true}, errors.New("apns_transport_failed")
	}
	defer res.Body.Close()
	if res.StatusCode == 200 {
		return Result{}, nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&failure)
	return Result{Retry: res.StatusCode == 429 || res.StatusCode >= 500, InvalidToken: failure.Reason == "Unregistered" || failure.Reason == "BadDeviceToken" || failure.Reason == "DeviceTokenNotForTopic"}, errors.New("apns_delivery_failed")
}
