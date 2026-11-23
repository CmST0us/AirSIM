package control

import (
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func testProvisionServer(t *testing.T, withCA bool) *Server {
	t.Helper()
	cfg := Config{
		Server: "11111111-1111-4111-8111-111111111111",
		API:    "https://api.example.test",
		Device: "https://device.example.test",
		Media:  "https://api.example.test",
		HMAC:   strings.Repeat("ab", 32),
	}
	if withCA {
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		tmpl := &x509.Certificate{
			SerialNumber:          big.NewInt(1),
			Subject:               pkix.Name{CommonName: "test-device-ca"},
			NotBefore:             time.Now().Add(-time.Hour),
			NotAfter:              time.Now().Add(365 * 24 * time.Hour),
			IsCA:                  true,
			BasicConstraintsValid: true,
			KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, key)
		if err != nil {
			t.Fatal(err)
		}
		ca, err := x509.ParseCertificate(der)
		if err != nil {
			t.Fatal(err)
		}
		cfg.DeviceCA = ca
		cfg.DeviceCAKey = key
	}
	return New(nil, cfg)
}

func TestProvisionPrepareAndValidationContract(t *testing.T) {
	noCA := testProvisionServer(t, false)
	req := httptest.NewRequest(http.MethodPost, "/v2/pairing/provision/prepare", bytes.NewBufferString(`{"request_id":"22222222-2222-4222-8222-222222222222"}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	noCA.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 without CA key, got %d", w.Code)
	}

	s := testProvisionServer(t, true)
	req = httptest.NewRequest(http.MethodPost, "/v2/pairing/provision/prepare", bytes.NewBufferString(`{"request_id":"22222222-2222-4222-8222-222222222222"}`))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("prepare status=%d body=%s", w.Code, w.Body.String())
	}
	var prepResp struct {
		Prepare      provisionPrepare `json:"prepare"`
		PrepareToken string           `json:"prepare_token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &prepResp); err != nil {
		t.Fatal(err)
	}
	if prepResp.Prepare.Server != s.cfg.Server || prepResp.Prepare.CA != s.deviceCAPEM() || len(prepResp.PrepareToken) != 64 {
		t.Fatalf("unexpected prepare response: %+v", prepResp)
	}

	modPub, modKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	moduleID := "33333333-3333-4333-8333-333333333333"
	uri, _ := url.Parse("urn:airsim:" + s.cfg.Server + ":module:" + moduleID)
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: moduleID},
		URIs:    []*url.URL{uri},
	}, modKey)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(csrDER)
	proofMsg := strings.Join([]string{
		"airsim-v2-r4-provision", prepResp.Prepare.Request, prepResp.Prepare.Server, moduleID,
		prepResp.Prepare.API, prepResp.Prepare.Device, prepResp.Prepare.Media,
		prepResp.Prepare.Nonce, prepResp.Prepare.Expires, hex.EncodeToString(h[:]), "",
	}, "\n")
	proofSig, err := modKey.Sign(rand.Reader, []byte(proofMsg), crypto.Hash(0))
	if err != nil {
		t.Fatal(err)
	}
	resp := provisionResponse{
		Request: prepResp.Prepare.Request,
		Module:  moduleID,
		Public:  base64.StdEncoding.EncodeToString(modPub),
		CSR:     string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrDER})),
		Proof:   base64.StdEncoding.EncodeToString(proofSig),
	}
	if pub, gotURI, ok := s.validateProvisionRequest(prepResp.Prepare, prepResp.PrepareToken, resp, time.Now().UTC()); !ok || !bytes.Equal(pub, modPub) || gotURI != uri.String() {
		t.Fatalf("valid request rejected: ok=%v reason=%s", ok, gotURI)
	}
	tampered := prepResp.Prepare
	tampered.Nonce = strings.Repeat("ff", 32)
	if _, reason, ok := s.validateProvisionRequest(tampered, prepResp.PrepareToken, resp, time.Now().UTC()); ok || reason != "invalid_prepare_token" {
		t.Fatalf("tampered prepare accepted: ok=%v reason=%s", ok, reason)
	}
	badProof := resp
	badProof.Proof = base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize))
	if _, reason, ok := s.validateProvisionRequest(prepResp.Prepare, prepResp.PrepareToken, badProof, time.Now().UTC()); ok || reason != "invalid_proof" {
		t.Fatalf("bad proof accepted: ok=%v reason=%s", ok, reason)
	}
	if _, reason, ok := s.validateProvisionRequest(prepResp.Prepare, prepResp.PrepareToken, resp, time.Now().UTC().Add(10*time.Minute)); ok || reason != "provision_expired" {
		t.Fatalf("expired prepare accepted: ok=%v reason=%s", ok, reason)
	}
}
