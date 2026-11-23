package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"github.com/jackc/pgx/v5"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	provisionLifetime  = 5 * time.Minute
	maxUserModules     = 64
	provisionMaxBody   = 32 * 1024
)

type provisionPrepare struct {
	Request  string `json:"request_id"`
	Server   string `json:"server_id"`
	API      string `json:"api_origin"`
	Device   string `json:"device_origin"`
	Media    string `json:"media_origin"`
	CA       string `json:"device_ca_pem"`
	ServerCA string `json:"server_ca_pem"`
	Nonce    string `json:"nonce"`
	Expires  string `json:"expires_at"`
}

type provisionResponse struct {
	Request string `json:"request_id"`
	Module  string `json:"module_id"`
	Public  string `json:"public_key_base64"`
	CSR     string `json:"csr_pem"`
	Proof   string `json:"proof_base64"`
}

type provisionBundle struct {
	Request     string `json:"request_id"`
	Server      string `json:"server_id"`
	Module      string `json:"module_id"`
	Certificate string `json:"certificate_pem"`
	Receipt     string `json:"receipt_base64"`
}

func (s *Server) deviceCAPEM() string {
	if s.cfg.DeviceCA == nil {
		return ""
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: s.cfg.DeviceCA.Raw}))
}

func (s *Server) signProvisionPrepare(p provisionPrepare) string {
	canonical, _ := json.Marshal(p)
	mac := hmac.New(sha256.New, s.pairingKey("provision-prepare"))
	_, _ = mac.Write(canonical)
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *Server) provisionPrepareHandler(w http.ResponseWriter, r *http.Request) {
	if s.cfg.DeviceCA == nil || len(s.cfg.DeviceCAKey) == 0 {
		wire.Error(w, http.StatusServiceUnavailable, "provisioning_unavailable")
		return
	}
	var body struct {
		RequestID string `json:"request_id"`
	}
	if wire.Body(w, r, &body, 4*1024, "request_id") != nil || !wire.UUID.MatchString(body.RequestID) {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	if !s.pairingRates.allow("provision:"+s.pairingSource(r), 8, time.Now()) {
		wire.Error(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	p := provisionPrepare{
		Request:  body.RequestID,
		Server:   s.cfg.Server,
		API:      s.cfg.API,
		Device:   s.cfg.Device,
		Media:    s.cfg.Media,
		CA:       s.deviceCAPEM(),
		ServerCA: "",
		Nonce:    wire.Token(),
		Expires:  time.Now().UTC().Add(provisionLifetime).Truncate(time.Microsecond).Format(time.RFC3339Nano),
	}
	wire.JSON(w, http.StatusOK, map[string]any{
		"prepare":       p,
		"prepare_token": s.signProvisionPrepare(p),
	})
}

func (s *Server) validateProvisionRequest(p provisionPrepare, token string, resp provisionResponse, now time.Time) (ed25519.PublicKey, string, bool) {
	if !wire.Hex.MatchString(token) || subtle.ConstantTimeCompare([]byte(token), []byte(s.signProvisionPrepare(p))) != 1 {
		return nil, "invalid_prepare_token", false
	}
	if p.Server != s.cfg.Server || p.API != s.cfg.API || p.Device != s.cfg.Device || p.Media != s.cfg.Media ||
		p.CA != s.deviceCAPEM() || p.ServerCA != "" {
		return nil, "invalid_parameters", false
	}
	if p.Request != resp.Request || !wire.UUID.MatchString(p.Request) || !wire.UUID.MatchString(p.Server) ||
		!wire.UUID.MatchString(resp.Module) || !wire.Hex.MatchString(p.Nonce) {
		return nil, "invalid_parameters", false
	}
	exp, err := time.Parse(time.RFC3339Nano, p.Expires)
	if err != nil || !strings.HasSuffix(p.Expires, "Z") || !exp.After(now) || exp.Sub(now) > 10*time.Minute {
		return nil, "provision_expired", false
	}
	block, rest := pem.Decode([]byte(resp.CSR))
	if block == nil || block.Type != "CERTIFICATE REQUEST" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, "invalid_csr", false
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil || csr.CheckSignature() != nil {
		return nil, "invalid_csr", false
	}
	pub, err := base64.StdEncoding.Strict().DecodeString(resp.Public)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, "invalid_public_key", false
	}
	cp, ok := csr.PublicKey.(ed25519.PublicKey)
	uri := "urn:airsim:" + p.Server + ":module:" + resp.Module
	if !ok || !hmac.Equal(cp, pub) || csr.Subject.CommonName != resp.Module || len(csr.URIs) != 1 ||
		csr.URIs[0].String() != uri || len(csr.DNSNames)+len(csr.IPAddresses)+len(csr.EmailAddresses) != 0 {
		return nil, "invalid_csr", false
	}
	h := sha256.Sum256(csr.Raw)
	proofPayload := strings.Join([]string{
		"airsim-v2-r4-provision", p.Request, p.Server, resp.Module,
		p.API, p.Device, p.Media, p.Nonce, p.Expires, hex.EncodeToString(h[:]), "",
	}, "\n")
	sig, err := base64.StdEncoding.Strict().DecodeString(resp.Proof)
	if err != nil || !ed25519.Verify(cp, []byte(proofPayload), sig) {
		return nil, "invalid_proof", false
	}
	return cp, uri, true
}

func (s *Server) provisionIssueHandler(w http.ResponseWriter, r *http.Request) {
	if s.cfg.DeviceCA == nil || len(s.cfg.DeviceCAKey) == 0 {
		wire.Error(w, http.StatusServiceUnavailable, "provisioning_unavailable")
		return
	}
	var outer struct {
		Prepare      json.RawMessage `json:"prepare"`
		PrepareToken string          `json:"prepare_token"`
		Response     json.RawMessage `json:"response"`
	}
	if wire.Body(w, r, &outer, provisionMaxBody, "prepare", "prepare_token", "response") != nil {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	var p provisionPrepare
	var resp provisionResponse
	if wire.Decode(outer.Prepare, &p, "request_id", "server_id", "api_origin", "device_origin", "media_origin", "device_ca_pem", "server_ca_pem", "nonce", "expires_at") != nil ||
		wire.Decode(outer.Response, &resp, "request_id", "module_id", "public_key_base64", "csr_pem", "proof_base64") != nil {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	if !s.pairingRates.allow("provision-issue:"+s.pairingSource(r), 8, time.Now()) {
		wire.Error(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	now := time.Now().UTC()
	pub, reason, ok := s.validateProvisionRequest(p, outer.PrepareToken, resp, now)
	if !ok {
		status := http.StatusBadRequest
		if reason == "provision_expired" {
			status = http.StatusGone
		} else if reason == "invalid_prepare_token" || reason == "invalid_proof" {
			status = http.StatusForbidden
		}
		log.Printf("device_provision_rejected module=%s reason=%s", resp.Module, reason)
		wire.Error(w, status, reason)
		return
	}
	canonicalPrepare, _ := json.Marshal(p)
	canonicalResponse, _ := json.Marshal(resp)
	digest := wire.Hash(string(canonicalPrepare) + string(canonicalResponse))

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	var server, owner string
	if err = tx.QueryRow(ctx, "SELECT server_id,user_id FROM identity FOR UPDATE").Scan(&server, &owner); err != nil || server != p.Server {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	var existingDigest string
	var existingBundle []byte
	err = tx.QueryRow(ctx, "SELECT request_digest,bundle FROM provisions WHERE request_id=$1", p.Request).Scan(&existingDigest, &existingBundle)
	if err == nil {
		if digest != existingDigest {
			wire.Error(w, http.StatusConflict, "provision_conflict")
			return
		}
		var cached provisionBundle
		if json.Unmarshal(existingBundle, &cached) != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
		wire.JSON(w, http.StatusOK, cached)
		return
	}
	if err != pgx.ErrNoRows {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}

	var existingPub []byte
	var currentSerial string
	var existingRevoked bool
	modErr := tx.QueryRow(ctx, "SELECT public_key,serial,revoked FROM modules WHERE id=$1 FOR UPDATE", resp.Module).Scan(&existingPub, &currentSerial, &existingRevoked)
	moduleExists := modErr == nil
	if modErr != nil && modErr != pgx.ErrNoRows {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if moduleExists {
		if existingRevoked {
			log.Printf("device_provision_rejected module=%s reason=module_revoked", resp.Module)
			wire.Error(w, http.StatusForbidden, "module_revoked")
			return
		}
		if !hmac.Equal(existingPub, pub) {
			log.Printf("device_provision_rejected module=%s reason=module_conflict", resp.Module)
			wire.Error(w, http.StatusConflict, "module_conflict")
			return
		}
	} else {
		var count int
		if err = tx.QueryRow(ctx, "SELECT count(*) FROM modules WHERE user_id=$1", owner).Scan(&count); err != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
		if count >= maxUserModules {
			wire.Error(w, http.StatusTooManyRequests, "capacity_exceeded")
			return
		}
	}

	sn, err := randomSerial()
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "provisioning_unavailable")
		return
	}
	uri := "urn:airsim:" + p.Server + ":module:" + resp.Module
	san, _ := url.Parse(uri)
	notAfter := now.Add(deviceCertLifetime)
	if notAfter.After(s.cfg.DeviceCA.NotAfter) {
		notAfter = s.cfg.DeviceCA.NotAfter
	}
	tmpl := &x509.Certificate{
		SerialNumber: sn,
		Subject:      pkix.Name{CommonName: resp.Module},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		URIs:         []*url.URL{san},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, s.cfg.DeviceCA, pub, s.cfg.DeviceCAKey)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "provisioning_unavailable")
		return
	}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	ch := sha256.Sum256(der)
	receiptPayload := strings.Join([]string{"airsim-v2-r4-commit", p.Request, p.Server, resp.Module, hex.EncodeToString(ch[:]), p.Nonce, ""}, "\n")
	bundle := provisionBundle{
		Request:     p.Request,
		Server:      p.Server,
		Module:      resp.Module,
		Certificate: certPEM,
		Receipt:     base64.StdEncoding.EncodeToString(ed25519.Sign(s.cfg.DeviceCAKey, []byte(receiptPayload))),
	}
	encoded, _ := json.Marshal(bundle)

	if moduleExists {
		if _, err = tx.Exec(ctx, "UPDATE modules SET previous_serial=$1,serial=$2,certificate=$3 WHERE id=$4 AND server_id=$5 AND NOT revoked", currentSerial, sn.String(), certPEM, resp.Module, p.Server); err != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
	} else {
		if _, err = tx.Exec(ctx, "INSERT INTO modules(id,user_id,server_id,public_key,serial,certificate) VALUES($1,$2,$3,$4,$5,$6)", resp.Module, owner, p.Server, []byte(pub), sn.String(), certPEM); err != nil {
			wire.Error(w, http.StatusConflict, "provision_conflict")
			return
		}
	}
	if _, err = tx.Exec(ctx, "INSERT INTO provisions(request_id,module_id,request_digest,bundle) VALUES($1,$2,$3,$4)", p.Request, resp.Module, digest, encoded); err != nil {
		wire.Error(w, http.StatusConflict, "provision_conflict")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	log.Printf("device_provisioned module=%s reprovision=%v expires=%s", resp.Module, moduleExists, notAfter.Format(time.RFC3339))
	status := http.StatusCreated
	if moduleExists {
		status = http.StatusOK
	}
	wire.JSON(w, status, bundle)
}
