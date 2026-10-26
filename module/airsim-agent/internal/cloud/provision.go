package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/strictjson"
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var errConfig = errors.New("cloud_config")

const Profile = "airsim-v2-r4.1"

type Prepare struct {
	RequestID string `json:"request_id"`
	ServerID  string `json:"server_id"`
	API       string `json:"api_origin"`
	Device    string `json:"device_origin"`
	Media     string `json:"media_origin"`
	DeviceCA  string `json:"device_ca_pem"`
	ServerCA  string `json:"server_ca_pem"`
	Nonce     string `json:"nonce"`
	Expires   string `json:"expires_at"`
}
type Prepared struct {
	RequestID string `json:"request_id"`
	ModuleID  string `json:"module_id"`
	Public    string `json:"public_key_base64"`
	CSR       string `json:"csr_pem"`
	Proof     string `json:"proof_base64"`
}
type Bundle struct {
	RequestID   string `json:"request_id"`
	ServerID    string `json:"server_id"`
	ModuleID    string `json:"module_id"`
	Certificate string `json:"certificate_pem"`
	Receipt     string `json:"receipt_base64"`
}
type saved struct {
	Schema     int      `json:"schema_version"`
	Request    Prepare  `json:"request"`
	Response   Prepared `json:"response"`
	Activation *Bundle  `json:"activation,omitempty"`
}
type Status struct {
	Configured        bool       `json:"configured"`
	Connected         bool       `json:"connected"`
	ServerID          string     `json:"server_id"`
	ModuleID          string     `json:"module_id"`
	Epoch             string     `json:"connection_epoch"`
	LastConnected     *time.Time `json:"last_connected_at"`
	LastError         string     `json:"last_error"`
	CertificateExpiry *time.Time `json:"certificate_expires_at"`
}
type Provisioner struct {
	mu              sync.Mutex
	id              identity.Identity
	path            string
	config, pending *saved
	status          Status
	changed         chan struct{}
}

func exact(b []byte, keys string, out any) error {
	var required []string
	if keys != "" {
		required = strings.Split(keys, ",")
	}
	return strictjson.Decode(b, required, nil, out)
}
func exactOptional(b []byte, keys, optional string, out any) error {
	var required, allowed []string
	if keys != "" {
		required = strings.Split(keys, ",")
	}
	if optional != "" {
		allowed = strings.Split(optional, ",")
	}
	return strictjson.Decode(b, required, allowed, out)
}
func origin(s string) bool {
	u, e := url.Parse(s)
	return e == nil && u.Scheme == "https" && u.Host != "" && u.Hostname() != "" && u.User == nil && u.Path == "" && u.RawQuery == "" && !u.ForceQuery && u.Fragment == "" && u.Opaque == "" && !strings.ContainsAny(s, "\r\n") && u.String() == s
}
func hex32(s string) bool {
	b, e := hex.DecodeString(s)
	return e == nil && len(b) == 32 && hex.EncodeToString(b) == s
}
func utc(s string) (time.Time, error) {
	t, e := time.Parse(time.RFC3339Nano, s)
	if e != nil || !strings.HasSuffix(s, "Z") {
		return time.Time{}, errConfig
	}
	return t, nil
}
func hash(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func decode64(s string) ([]byte, error) {
	b, e := base64.StdEncoding.Strict().DecodeString(s)
	if e != nil || base64.StdEncoding.EncodeToString(b) != s {
		return nil, errConfig
	}
	return b, nil
}
func certificate(s string) (*x509.Certificate, error) {
	b, rest := pem.Decode([]byte(s))
	if b == nil || b.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errConfig
	}
	return x509.ParseCertificate(b.Bytes)
}
func roots(s string) (*x509.CertPool, error) {
	if s == "" {
		return nil, nil
	}
	pool := x509.NewCertPool()
	rest := []byte(s)
	count := 0
	for len(bytes.TrimSpace(rest)) > 0 {
		b, r := pem.Decode(rest)
		if b == nil || b.Type != "CERTIFICATE" {
			return nil, errConfig
		}
		c, e := x509.ParseCertificate(b.Bytes)
		if e != nil || !c.IsCA {
			return nil, errConfig
		}
		pool.AddCert(c)
		rest = r
		count++
	}
	if count == 0 {
		return nil, errConfig
	}
	return pool, nil
}
func validPrepare(r Prepare, fresh bool) error {
	if !control.ValidID(r.RequestID) || !control.ValidID(r.ServerID) || !origin(r.API) || !origin(r.Device) || !origin(r.Media) || !hex32(r.Nonce) {
		return errConfig
	}
	t, e := utc(r.Expires)
	if e != nil {
		return e
	}
	if fresh && (time.Until(t) <= 0 || time.Until(t) > 10*time.Minute) {
		return errConfig
	}
	ca, e := certificate(r.DeviceCA)
	if e != nil || !ca.IsCA || ca.KeyUsage&x509.KeyUsageCertSign == 0 {
		return errConfig
	}
	if _, ok := ca.PublicKey.(ed25519.PublicKey); !ok {
		return errConfig
	}
	if _, e = roots(r.ServerCA); e != nil {
		return e
	}
	return nil
}
func proofBytes(r Prepare, module string, der []byte) []byte {
	return []byte("airsim-v2-r4-provision\n" + strings.Join([]string{r.RequestID, r.ServerID, module, r.API, r.Device, r.Media, r.Nonce, r.Expires, hash(der)}, "\n") + "\n")
}
func receiptBytes(r Prepare, b Bundle, der []byte) []byte {
	return []byte("airsim-v2-r4-commit\n" + strings.Join([]string{b.RequestID, b.ServerID, b.ModuleID, hash(der), r.Nonce}, "\n") + "\n")
}
func uniqueSAN(cert *x509.Certificate, uri string) bool {
	expected, e := asn1.Marshal([]asn1.RawValue{{Class: 2, Tag: 6, Bytes: []byte(uri)}})
	if e != nil {
		return false
	}
	found := 0
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(asn1.ObjectIdentifier{2, 5, 29, 17}) {
			found++
			if !bytes.Equal(ext.Value, expected) {
				return false
			}
		}
	}
	return found == 1
}
func (p *Provisioner) validate(s *saved, activated bool) (*x509.Certificate, error) {
	if s.Schema != 1 || validPrepare(s.Request, false) != nil || s.Response.RequestID != s.Request.RequestID || s.Response.ModuleID != p.id.ModuleID {
		return nil, errConfig
	}
	pub := p.id.Signer().Public().(ed25519.PublicKey)
	pb, e := decode64(s.Response.Public)
	if e != nil || !bytes.Equal(pb, pub) {
		return nil, errConfig
	}
	block, rest := pem.Decode([]byte(s.Response.CSR))
	if block == nil || block.Type != "CERTIFICATE REQUEST" || len(bytes.TrimSpace(rest)) > 0 {
		return nil, errConfig
	}
	csr, e := x509.ParseCertificateRequest(block.Bytes)
	if e != nil || csr.CheckSignature() != nil {
		return nil, errConfig
	}
	cp, ok := csr.PublicKey.(ed25519.PublicKey)
	uri := "urn:airsim:" + s.Request.ServerID + ":module:" + p.id.ModuleID
	if !ok || !bytes.Equal(cp, pub) || csr.Subject.CommonName != p.id.ModuleID || len(csr.URIs) != 1 || csr.URIs[0].String() != uri || len(csr.DNSNames)+len(csr.IPAddresses)+len(csr.EmailAddresses) != 0 {
		return nil, errConfig
	}
	proof, e := decode64(s.Response.Proof)
	if e != nil || !ed25519.Verify(pub, proofBytes(s.Request, p.id.ModuleID, block.Bytes), proof) {
		return nil, errConfig
	}
	if !activated {
		if s.Activation != nil {
			return nil, errConfig
		}
		return nil, nil
	}
	b := s.Activation
	if b == nil || b.RequestID != s.Request.RequestID || b.ServerID != s.Request.ServerID || b.ModuleID != p.id.ModuleID {
		return nil, errConfig
	}
	cert, e := certificate(b.Certificate)
	if e != nil {
		return nil, errConfig
	}
	ca, e := certificate(s.Request.DeviceCA)
	if e != nil {
		return nil, errConfig
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	if _, e = cert.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); e != nil {
		return nil, errConfig
	}
	key, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok || !bytes.Equal(key, pub) || !uniqueSAN(cert, uri) || cert.IsCA || len(cert.ExtKeyUsage) != 1 || cert.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth || len(cert.UnknownExtKeyUsage) != 0 || len(cert.URIs) != 1 || cert.URIs[0].String() != uri || len(cert.DNSNames)+len(cert.EmailAddresses)+len(cert.IPAddresses) != 0 {
		return nil, errConfig
	}
	receipt, e := decode64(b.Receipt)
	if e != nil || !ed25519.Verify(ca.PublicKey.(ed25519.PublicKey), receiptBytes(s.Request, *b, cert.Raw), receipt) {
		return nil, errConfig
	}
	return cert, nil
}
func readSaved(path string) (*saved, error) {
	fi, e := os.Lstat(path)
	if os.IsNotExist(e) {
		return nil, nil
	}
	if e != nil || !fi.Mode().IsRegular() || fi.Mode().Perm() != 0600 || fi.Size() > 65536 {
		return nil, errConfig
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, errConfig
	}
	fields, e := strictjson.Object(b, []string{"schema_version", "request", "response"}, []string{"activation"})
	if e != nil {
		return nil, errConfig
	}
	var s saved
	if json.Unmarshal(b, &s) != nil {
		return nil, errConfig
	}
	if exact(fields["request"], "request_id,server_id,api_origin,device_origin,media_origin,device_ca_pem,server_ca_pem,nonce,expires_at", &s.Request) != nil || exact(fields["response"], "request_id,module_id,public_key_base64,csr_pem,proof_base64", &s.Response) != nil {
		return nil, errConfig
	}
	if raw, ok := fields["activation"]; ok {
		if s.Activation == nil || exact(raw, "request_id,server_id,module_id,certificate_pem,receipt_base64", s.Activation) != nil {
			return nil, errConfig
		}
	}
	return &s, nil
}
func secureDir(path string) error {
	d := filepath.Dir(path)
	f, e := os.Lstat(d)
	if e != nil || !f.IsDir() || f.Mode()&os.ModeSymlink != 0 || f.Mode().Perm() != 0700 {
		return errConfig
	}
	return nil
}
func persist(path string, v any) error {
	if secureDir(path) != nil {
		return errConfig
	}
	if f, e := os.Lstat(path); e == nil && (!f.Mode().IsRegular() || f.Mode().Perm() != 0600) {
		return errConfig
	} else if e != nil && !os.IsNotExist(e) {
		return errConfig
	}
	b, e := json.Marshal(v)
	if e != nil {
		return errConfig
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".cloud-*")
	if e != nil {
		return errConfig
	}
	name := f.Name()
	defer os.Remove(name)
	defer f.Close()
	if f.Chmod(0600) != nil {
		return errConfig
	}
	if _, e = f.Write(b); e != nil {
		return errConfig
	}
	if f.Sync() != nil || f.Close() != nil {
		return errConfig
	}
	if os.Rename(name, path) != nil {
		return errConfig
	}
	d, e := os.Open(filepath.Dir(path))
	if e != nil {
		return errConfig
	}
	defer d.Close()
	return d.Sync()
}
func NewProvisioner(id identity.Identity, path string) *Provisioner {
	p := &Provisioner{id: id, path: path, changed: make(chan struct{}, 1), status: Status{ModuleID: id.ModuleID}}
	if secureDir(path) != nil {
		p.status.LastError = "cloud_config"
		return p
	}
	var e error
	p.config, e = readSaved(path)
	if e == nil && p.config != nil {
		var c *x509.Certificate
		c, e = p.validate(p.config, true)
		if e == nil {
			p.status.Configured = true
			p.status.ServerID = p.config.Request.ServerID
			p.status.CertificateExpiry = &c.NotAfter
		}
	}
	if e != nil {
		p.config = nil
		p.status.LastError = "cloud_config"
		return p
	}
	p.pending, e = readSaved(path + ".pending")
	if e == nil && p.pending != nil {
		_, e = p.validate(p.pending, false)
	}
	if e != nil {
		p.pending = nil
		p.status.LastError = "cloud_config"
	}
	return p
}
func (p *Provisioner) View() Status { p.mu.Lock(); defer p.mu.Unlock(); return p.status }
func (p *Provisioner) Prepare(r Prepare) (Prepared, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.status.LastError == "cloud_config" {
		return Prepared{}, 503
	}
	if p.config != nil {
		if p.config.Request == r {
			return p.config.Response, 200
		}
		return Prepared{}, 409
	}
	if p.pending != nil {
		if p.pending.Request == r {
			return p.pending.Response, 200
		}
		return Prepared{}, 409
	}
	if validPrepare(r, true) != nil {
		return Prepared{}, 400
	}
	uri, _ := url.Parse("urn:airsim:" + r.ServerID + ":module:" + p.id.ModuleID)
	der, e := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{Subject: pkix.Name{CommonName: p.id.ModuleID}, URIs: []*url.URL{uri}}, p.id.Signer())
	if e != nil {
		return Prepared{}, 503
	}
	sig, e := p.id.Signer().Sign(rand.Reader, proofBytes(r, p.id.ModuleID, der), crypto.Hash(0))
	if e != nil {
		return Prepared{}, 503
	}
	response := Prepared{r.RequestID, p.id.ModuleID, base64.StdEncoding.EncodeToString(p.id.Signer().Public().(ed25519.PublicKey)), string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der})), base64.StdEncoding.EncodeToString(sig)}
	s := &saved{1, r, response, nil}
	if persist(p.path+".pending", s) != nil {
		return Prepared{}, 503
	}
	p.pending = s
	return response, 200
}
func (p *Provisioner) Activate(b Bundle) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.status.LastError == "cloud_config" {
		return 503
	}
	if p.config != nil {
		if *p.config.Activation == b {
			return 200
		}
		return 409
	}
	if p.pending == nil {
		return 409
	}
	s := *p.pending
	s.Activation = &b
	expiry, e := utc(s.Request.Expires)
	if e != nil || !time.Now().Before(expiry) {
		return 400
	}
	cert, e := p.validate(&s, true)
	if e != nil {
		return 400
	}
	if persist(p.path, &s) != nil {
		return 503
	}
	p.config = &s
	p.pending = nil
	p.status.Configured = true
	p.status.ServerID = s.Request.ServerID
	p.status.CertificateExpiry = &cert.NotAfter
	p.status.LastError = ""
	// Keeping a stale pending after a crash is safe: committed config wins.
	_ = os.Remove(p.path + ".pending")
	select {
	case p.changed <- struct{}{}:
	default:
	}
	return 200
}
func (p *Provisioner) client(s *saved, mtls bool) (*http.Client, error) {
	pool, e := roots(s.Request.ServerCA)
	if e != nil {
		return nil, e
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}
	if mtls {
		c, e := p.validate(s, true)
		if e != nil {
			return nil, e
		}
		cfg.Certificates = []tls.Certificate{{Certificate: [][]byte{c.Raw}, PrivateKey: p.id.Signer(), Leaf: c}}
	}
	return &http.Client{Transport: &http.Transport{Proxy: nil, TLSClientConfig: cfg, ForceAttemptHTTP2: false}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect_rejected") }}, nil
}
func WithLocal(next http.Handler, p *Provisioner, a *Agent) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p.pairingRoute(w, r) {
			return
		}
		if r.URL.Path != "/v2/local/cloud" && r.URL.Path != "/v2/local/cloud/prepare" && r.URL.Path != "/v2/local/cloud/activate" && r.URL.Path != "/v2/local/cloud/media-stats" {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		code := 200
		var out any
		if r.URL.Path == "/v2/local/cloud/media-stats" {
			if r.Method != "GET" {
				code = 405
			} else {
				out = a.LastBridgeStats()
			}
		} else if r.URL.Path == "/v2/local/cloud" {
			if r.Method != "GET" {
				code = 405
			} else {
				out = p.View()
			}
		} else if r.Method != "POST" {
			code = 405
		} else if r.Header.Get("Content-Type") != "application/json" {
			code = 400
		} else {
			b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 32768))
			if e != nil {
				code = 400
			} else if strings.HasSuffix(r.URL.Path, "/prepare") {
				var v Prepare
				if exact(b, "request_id,server_id,api_origin,device_origin,media_origin,device_ca_pem,server_ca_pem,nonce,expires_at", &v) != nil {
					code = 400
				} else {
					out, code = p.Prepare(v)
				}
			} else {
				var v Bundle
				if exact(b, "request_id,server_id,module_id,certificate_pem,receipt_base64", &v) != nil {
					code = 400
				} else {
					code = p.Activate(v)
					out = p.View()
				}
			}
		}
		if code >= 400 {
			out = map[string]string{"error": "cloud_request_rejected"}
		}
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(out)
	})
}
