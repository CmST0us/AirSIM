package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/platform/rm500u"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

type pairingStatus struct {
	ModuleID          string     `json:"module_id"`
	Public            string     `json:"public_key_base64"`
	Profile           string     `json:"profile"`
	Configured        bool       `json:"configured"`
	ServerID          string     `json:"server_id"`
	API               string     `json:"api_origin"`
	Media             string     `json:"media_origin"`
	Connected         bool       `json:"connected"`
	CertificateExpiry *time.Time `json:"certificate_expires_at"`
}
type pairingRequest struct {
	RequestID     string `json:"request_id"`
	ServerID      string `json:"server_id"`
	ModuleID      string `json:"module_id"`
	Nonce         string `json:"nonce"`
	Expires       string `json:"expires_at"`
	PollTokenHash string `json:"poll_token_hash"`
}
type pairingProof struct {
	RequestID string `json:"request_id"`
	ModuleID  string `json:"module_id"`
	Public    string `json:"public_key_base64"`
	Proof     string `json:"proof_base64"`
}

var pairingTime = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$`)

func pairingBytes(r pairingRequest) []byte {
	return []byte("airsim-v2-pairing\n" + strings.Join([]string{r.RequestID, r.ServerID, r.ModuleID, r.Nonce, r.Expires, r.PollTokenHash}, "\n") + "\n")
}

// Caller holds p.mu. All service information is gated by the current certificate.
func (p *Provisioner) pairingCertificate(now time.Time) (*x509.Certificate, int, string) {
	if p.status.LastError == "cloud_config" {
		return nil, 503, "pairing_config_invalid"
	}
	if p.config == nil {
		return nil, 409, "pairing_unconfigured"
	}
	if p.config.Activation == nil {
		return nil, 503, "pairing_config_invalid"
	}
	cert, e := certificate(p.config.Activation.Certificate)
	if e != nil {
		return nil, 503, "pairing_config_invalid"
	}
	if !now.Before(cert.NotAfter) {
		return nil, 410, "pairing_certificate_expired"
	}
	cert, e = p.validate(p.config, true)
	if e != nil {
		return nil, 503, "pairing_config_invalid"
	}
	return cert, 200, ""
}
func (p *Provisioner) pairingView(now time.Time) (any, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := pairingStatus{ModuleID: p.id.ModuleID, Public: base64.StdEncoding.EncodeToString(p.id.Signer().Public().(ed25519.PublicKey)), Profile: rm500u.Profile}
	cert, code, reason := p.pairingCertificate(now)
	if reason == "pairing_unconfigured" {
		return out, 200
	}
	if code != 200 {
		return map[string]string{"error": reason}, code
	}
	out.Configured = true
	out.ServerID = p.config.Request.ServerID
	out.API = p.config.Request.API
	out.Media = p.config.Request.Media
	out.Connected = p.status.Connected
	out.CertificateExpiry = &cert.NotAfter
	return out, 200
}
func (p *Provisioner) authorizePairing(r pairingRequest, now time.Time) (any, int) {
	expiry, e := utc(r.Expires)
	if !control.ValidID(r.RequestID) || !control.ValidID(r.ServerID) || !control.ValidID(r.ModuleID) || !hex32(r.Nonce) || !hex32(r.PollTokenHash) || !pairingTime.MatchString(r.Expires) || e != nil {
		return map[string]string{"error": "pairing_request_invalid"}, 400
	}
	remaining := expiry.Sub(now)
	if remaining <= 0 {
		return map[string]string{"error": "pairing_request_expired"}, 410
	}
	if remaining > 305*time.Second {
		return map[string]string{"error": "pairing_request_invalid"}, 400
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, code, reason := p.pairingCertificate(now); code != 200 {
		return map[string]string{"error": reason}, code
	}
	if r.ModuleID != p.id.ModuleID || r.ServerID != p.config.Request.ServerID {
		return map[string]string{"error": "pairing_binding_mismatch"}, 409
	}
	sig, e := p.id.Signer().Sign(rand.Reader, pairingBytes(r), crypto.Hash(0))
	if e != nil {
		return map[string]string{"error": "pairing_sign_failed"}, 503
	}
	return pairingProof{r.RequestID, p.id.ModuleID, base64.StdEncoding.EncodeToString(p.id.Signer().Public().(ed25519.PublicKey)), base64.StdEncoding.EncodeToString(sig)}, 200
}
func (p *Provisioner) pairingRoute(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/v2/local/pairing" && r.URL.Path != "/v2/local/pairing/authorize" {
		return false
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	var out any = map[string]string{"error": "pairing_request_invalid"}
	code := 400
	if (r.URL.Path == "/v2/local/pairing" && r.Method != "GET") || (r.URL.Path == "/v2/local/pairing/authorize" && r.Method != "POST") {
		code = 405
		out = map[string]string{"error": "pairing_method_not_allowed"}
	} else if r.URL.RawQuery != "" || r.URL.ForceQuery {
		// Pairing input belongs only in the fixed JSON body, never the URL.
	} else if r.Method == "GET" {
		out, code = p.pairingView(time.Now())
	} else if r.Header.Get("Content-Type") == "application/json" {
		b, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 16*1024))
		var request pairingRequest
		if e == nil && exact(b, "request_id,server_id,module_id,nonce,expires_at,poll_token_hash", &request) == nil {
			out, code = p.authorizePairing(request, time.Now())
		}
	}
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(out)
	return true
}
