package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func environmentConfig(t *testing.T) Config {
	t.Helper()
	dir := t.TempDir()
	for _, name := range []string{"sandbox", "production"} {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(dir, name+".p8"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return Config{TeamID: "team", BundleID: "com.example.test", SandboxKeyID: "sandbox-key", SandboxKeyFile: filepath.Join(dir, "sandbox.p8"), ProductionKeyID: "production-key", ProductionKeyFile: filepath.Join(dir, "production.p8")}
}

func TestEnvironmentKeyRouting(t *testing.T) {
	sender, err := LoadConfig(environmentConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	p := sender.(*environmentProvider)
	for _, tc := range []struct {
		environment, host, keyID string
		provider                 *Provider
	}{
		{"sandbox", "api.sandbox.push.apple.com", "sandbox-key", p.sandbox},
		{"production", "api.push.apple.com", "production-key", p.production},
	} {
		calls := 0
		tc.provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Host != tc.host {
				t.Fatal("wrong APNs endpoint")
			}
			parts := strings.Split(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), ".")
			if len(parts) != 3 {
				t.Fatal("invalid JWT")
			}
			header, _ := base64.RawURLEncoding.DecodeString(parts[0])
			var claims struct {
				KeyID string `json:"kid"`
			}
			if json.Unmarshal(header, &claims) != nil || claims.KeyID != tc.keyID {
				t.Fatal("wrong key ID")
			}
			sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
			digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			if len(sig) != 64 || !ecdsa.Verify(&tc.provider.key.PublicKey, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
				t.Fatal("wrong signing key")
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}}, nil
		})
		for _, kind := range []string{"alert", "voip"} {
			_, err = sender.Send(context.Background(), Notification{Environment: tc.environment, Token: "synthetic", Topic: "com.example.test", Kind: kind, Payload: map[string]string{}})
			if err != nil {
				t.Fatal(err)
			}
		}
		if calls != 2 {
			t.Fatal("wrong provider selected")
		}
	}
	for _, environment := range []string{"", "development", "invalid"} {
		if _, err = sender.Send(context.Background(), Notification{Environment: environment}); err == nil {
			t.Fatal("unknown environment accepted")
		}
	}
}

func TestEnvironmentKeyConfiguration(t *testing.T) {
	if sender, err := LoadConfig(Config{}); sender != nil || err != nil {
		t.Fatal("disabled provider")
	}
	valid := environmentConfig(t)
	for _, mutate := range []func(*Config){
		func(c *Config) { c.SandboxKeyID = "" }, func(c *Config) { c.SandboxKeyFile = "" },
		func(c *Config) { c.ProductionKeyID = "" }, func(c *Config) { c.ProductionKeyFile = "" },
		func(c *Config) { c.TeamID = "" }, func(c *Config) { c.BundleID = "" },
		func(c *Config) { c.KeyID = "shared" }, func(c *Config) { c.KeyFile = "shared.p8" },
		func(c *Config) { c.ProductionKeyFile = "missing.p8" },
	} {
		c := valid
		mutate(&c)
		if sender, err := LoadConfig(c); sender != nil || err == nil {
			t.Fatal("invalid configuration accepted")
		}
	}
	legacy := Config{TeamID: valid.TeamID, BundleID: valid.BundleID, KeyID: valid.SandboxKeyID, KeyFile: valid.SandboxKeyFile}
	if sender, err := LoadConfig(legacy); sender == nil || err != nil {
		t.Fatal("existing shared-key configuration rejected")
	}
}
