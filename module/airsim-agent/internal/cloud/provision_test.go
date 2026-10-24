package cloud

import (
	"airsim.local/airsim-agent/internal/identity"
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func uid() string {
	s, e := identity.UUID()
	if e != nil {
		panic(e)
	}
	return s
}

type fixture struct {
	p        *Provisioner
	req      Prepare
	prepared Prepared
	bundle   Bundle
	ca       *x509.Certificate
	key      ed25519.PrivateKey
	caPEM    string
}

func newCA(t *testing.T) (*x509.Certificate, ed25519.PrivateKey, string) {
	t.Helper()
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "isolated-test-ca"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, key)
	if e != nil {
		t.Fatal(e)
	}
	ca, e := x509.ParseCertificate(der)
	if e != nil {
		t.Fatal(e)
	}
	return ca, key, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}
func newFixture(t *testing.T) *fixture {
	t.Helper()
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	id, e := identity.LoadOrCreate(filepath.Join(dir, "identity"))
	if e != nil {
		t.Fatal(e)
	}
	ca, key, caPEM := newCA(t)
	p := NewProvisioner(id, filepath.Join(dir, "cloud.json"))
	r := Prepare{uid(), uid(), "https://api.example.test", "https://device.example.test", "https://media.example.test", caPEM, caPEM, strings.Repeat("ab", 32), time.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339Nano)}
	return &fixture{p: p, req: r, ca: ca, key: key, caPEM: caPEM}
}
func (f *fixture) prepare(t *testing.T) {
	t.Helper()
	r, code := f.p.Prepare(f.req)
	if code != 200 {
		t.Fatal("prepare", code)
	}
	f.prepared = r
}
func (f *fixture) issue(t *testing.T) {
	t.Helper()
	block, _ := pem.Decode([]byte(f.prepared.CSR))
	csr, e := x509.ParseCertificateRequest(block.Bytes)
	if e != nil || csr.CheckSignature() != nil {
		t.Fatal("csr")
	}
	u, _ := url.Parse("urn:airsim:" + f.req.ServerID + ":module:" + f.p.id.ModuleID)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: csr.Subject, URIs: []*url.URL{u}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, KeyUsage: x509.KeyUsageDigitalSignature}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, f.ca, csr.PublicKey, f.key)
	if e != nil {
		t.Fatal(e)
	}
	b := Bundle{f.req.RequestID, f.req.ServerID, f.p.id.ModuleID, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), ""}
	sig, e := f.key.Sign(rand.Reader, receiptBytes(f.req, b, der), crypto.Hash(0))
	if e != nil {
		t.Fatal(e)
	}
	b.Receipt = base64.StdEncoding.EncodeToString(sig)
	f.bundle = b
}
func TestProvisionPersistenceProofAndActivation(t *testing.T) {
	f := newFixture(t)
	f.prepare(t)
	again, code := f.p.Prepare(f.req)
	if code != 200 || again != f.prepared {
		t.Fatal("idempotence")
	}
	other := f.req
	other.RequestID = uid()
	if _, code = f.p.Prepare(other); code != 409 {
		t.Fatal("pending conflict")
	}
	f.issue(t)
	block, _ := pem.Decode([]byte(f.prepared.CSR))
	proof, _ := decode64(f.prepared.Proof)
	if !ed25519.Verify(f.p.id.Signer().Public().(ed25519.PublicKey), proofBytes(f.req, f.p.id.ModuleID, block.Bytes), proof) {
		t.Fatal("proof")
	}
	restarted := NewProvisioner(f.p.id, f.p.path)
	if restarted.View().LastError != "" {
		t.Fatal("pending reload")
	}
	bad := f.bundle
	bad.Receipt = strings.Repeat("A", 88)
	if restarted.Activate(bad) != 400 {
		t.Fatal("forged receipt")
	}
	bad = f.bundle
	bad.ServerID = uid()
	if restarted.Activate(bad) != 400 {
		t.Fatal("server binding")
	}
	if restarted.Activate(f.bundle) != 200 || !restarted.View().Configured {
		t.Fatal("activation")
	}
	if restarted.Activate(f.bundle) != 200 {
		t.Fatal("commit retry")
	}
	fresh := NewProvisioner(f.p.id, f.p.path)
	if !fresh.View().Configured || fresh.Activate(f.bundle) != 200 {
		t.Fatal("restart receipt")
	}
	raw, e := os.ReadFile(f.p.path)
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(raw, []byte("seed_base64")) || bytes.Contains(raw, []byte("PRIVATE KEY")) {
		t.Fatal("private material leaked")
	}
	st, _ := os.Stat(f.p.path)
	if st.Mode().Perm() != 0600 {
		t.Fatal("mode")
	}
	status, _ := json.Marshal(fresh.View())
	if bytes.Contains(status, []byte(f.req.Nonce)) || bytes.Contains(status, []byte("CERTIFICATE")) {
		t.Fatal("status credential")
	}
	os.Chmod(f.p.path, 0644)
	if NewProvisioner(f.p.id, f.p.path).View().LastError != "cloud_config" {
		t.Fatal("permissions fail closed")
	}
}
func TestProvisionRejectsMalformedAndSaveFailures(t *testing.T) {
	f := newFixture(t)
	for _, originValue := range []string{"http://a.test", "https://u:p@a.test", "https://a.test/", "https://a.test?q=1", "https://a.test#f", "https://a.test\n"} {
		r := f.req
		r.API = originValue
		if _, code := f.p.Prepare(r); code != 400 {
			t.Fatal("origin")
		}
	}
	r := f.req
	r.Expires = time.Now().Add(11 * time.Minute).UTC().Format(time.RFC3339Nano)
	if _, code := f.p.Prepare(r); code != 400 {
		t.Fatal("expiry")
	}
	r = f.req
	r.Nonce = strings.Repeat("AB", 32)
	if _, code := f.p.Prepare(r); code != 400 {
		t.Fatal("nonce")
	}
	f.prepare(t)
	f.issue(t)
	target := filepath.Join(filepath.Dir(f.p.path), "unsafe")
	os.WriteFile(target, []byte("untouched"), 0600)
	os.Symlink(target, f.p.path)
	if f.p.Activate(f.bundle) != 503 || f.p.View().Configured {
		t.Fatal("unsafe save")
	}
	b, _ := os.ReadFile(target)
	if string(b) != "untouched" {
		t.Fatal("target changed")
	}
}
func TestStrictLocalJSONAndFrame(t *testing.T) {
	var p Prepare
	b := []byte(`{"request_id":null}`)
	if exact(b, "request_id", &p) == nil {
		t.Fatal("null")
	}
	var empty struct{}
	if exact([]byte(`{}`), "", &empty) != nil || exact([]byte(`{"unknown":1}`), "", &empty) == nil {
		t.Fatal("heartbeat")
	}
	module, epoch := uid(), uid()
	good := envelope{Type: "heartbeat", Protocol: 2, Module: module, Epoch: epoch, Sequence: 2, Payload: json.RawMessage(`{}`)}
	raw, _ := json.Marshal(good)
	if _, e := parseEnvelope(raw, module, epoch, 2, false); e != nil {
		t.Fatal(e)
	}
	for _, v := range []struct {
		module, epoch string
		seq           uint64
	}{{uid(), epoch, 2}, {module, uid(), 2}, {module, epoch, 1}} {
		if _, e := parseEnvelope(raw, v.module, v.epoch, v.seq, false); e == nil {
			t.Fatal("binding")
		}
	}
	raw = bytes.Replace(raw, []byte(`"sequence":2`), []byte(`"sequence":2,"sequence":2`), 1)
	if _, e := parseEnvelope(raw, module, epoch, 2, false); e == nil {
		t.Fatal("duplicate")
	}
}

func TestCertificateBindingsAndFailClosed(t *testing.T) {
	f := newFixture(t)
	f.prepare(t)
	f.issue(t)
	block, _ := pem.Decode([]byte(f.bundle.Certificate))
	original, e := x509.ParseCertificate(block.Bytes)
	if e != nil {
		t.Fatal(e)
	}
	for _, kind := range []string{"public_key", "san", "extra_san", "eku", "expired"} {
		cert := *original
		pub := original.PublicKey
		switch kind {
		case "public_key":
			pub, _, _ = ed25519.GenerateKey(rand.Reader)
		case "san":
			u, _ := url.Parse("urn:airsim:" + f.req.ServerID + ":module:" + uid())
			cert.URIs = []*url.URL{u}
		case "extra_san":
			cert.DNSNames = []string{"unexpected.test"}
		case "eku":
			cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		case "expired":
			cert.NotBefore = time.Now().Add(-2 * time.Hour)
			cert.NotAfter = time.Now().Add(-time.Hour)
		}
		cert.ExtraExtensions = nil
		der, e := x509.CreateCertificate(rand.Reader, &cert, f.ca, pub, f.key)
		if e != nil {
			t.Fatal(e)
		}
		b := f.bundle
		b.Certificate = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
		sig, _ := f.key.Sign(rand.Reader, receiptBytes(f.req, b, der), crypto.Hash(0))
		b.Receipt = base64.StdEncoding.EncodeToString(sig)
		if code := f.p.Activate(b); code != 400 || f.p.View().Configured {
			t.Fatal("certificate accepted", kind, code)
		}
	}
	if f.p.Activate(f.bundle) != 200 {
		t.Fatal("valid activation after rejected bundles")
	}
	client, e := f.p.client(f.p.config, true)
	if e != nil {
		t.Fatal(e)
	}
	defer client.CloseIdleConnections()
	tr := client.Transport.(*http.Transport)
	if tr.Proxy != nil || tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.MinVersion < tls.VersionTLS12 || len(tr.TLSClientConfig.Certificates) != 1 {
		t.Fatal("TLS restrictions")
	}
	if client.CheckRedirect(nil, nil) == nil {
		t.Fatal("redirect allowed")
	}
}
