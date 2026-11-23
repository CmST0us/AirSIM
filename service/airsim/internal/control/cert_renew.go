package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"log"
	"math/big"
	"net/url"
	"os"
	"strings"
	"time"
)

const deviceCertLifetime = 90 * 24 * time.Hour

// LoadDeviceCA parses the Device CA certificate and optional Ed25519 signing
// key used for automatic online device certificate renewal.
func LoadDeviceCA(certPEM []byte, keyPath string) (*x509.Certificate, ed25519.PrivateKey, error) {
	if strings.TrimSpace(keyPath) == "" {
		return nil, nil, nil
	}
	cb, rest := pem.Decode(certPEM)
	if cb == nil || cb.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, nil, errors.New("device_ca_invalid")
	}
	ca, err := x509.ParseCertificate(cb.Bytes)
	if err != nil || !ca.IsCA {
		return nil, nil, errors.New("device_ca_invalid")
	}
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, nil, err
	}
	kb, krest := pem.Decode(keyBytes)
	if kb == nil || len(strings.TrimSpace(string(krest))) != 0 {
		return nil, nil, errors.New("device_ca_key_invalid")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if err != nil {
		return nil, nil, errors.New("device_ca_key_invalid")
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, nil, errors.New("device_ca_key_invalid")
	}
	caPub, ok := ca.PublicKey.(ed25519.PublicKey)
	if !ok || !hmac.Equal(caPub, key.Public().(ed25519.PublicKey)) {
		return nil, nil, errors.New("device_ca_key_mismatch")
	}
	return ca, key, nil
}

func randomSerial() (*big.Int, error) {
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	return n.Add(n, big.NewInt(1)), nil
}

// certRenew handles an authenticated module's online mTLS certificate renewal
// request over its live control WebSocket. Must be called without s.mu held.
func (s *Server) certRenew(p *peer, payload []byte) bool {
	var req struct {
		RequestID string `json:"request_id"`
		Nonce     string `json:"nonce"`
		CSR       string `json:"csr_pem"`
	}
	if wire.Decode(payload, &req, "request_id", "nonce", "csr_pem") != nil ||
		!wire.UUID.MatchString(req.RequestID) || !wire.Hex.MatchString(req.Nonce) {
		return false
	}
	if s.cfg.DeviceCA == nil || s.cfg.DeviceCAKey == nil {
		log.Printf("device_cert_renew_skipped module=%s reason=ca_key_unconfigured", p.module)
		return true
	}
	block, rest := pem.Decode([]byte(req.CSR))
	if block == nil || block.Type != "CERTIFICATE REQUEST" || len(strings.TrimSpace(string(rest))) != 0 {
		log.Printf("device_cert_renew_failed module=%s reason=invalid_csr_pem", p.module)
		return true
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil || csr.CheckSignature() != nil {
		log.Printf("device_cert_renew_failed module=%s reason=invalid_csr_sig", p.module)
		return true
	}
	cp, ok := csr.PublicKey.(ed25519.PublicKey)
	uri := "urn:airsim:" + s.cfg.Server + ":module:" + p.module
	if !ok || csr.Subject.CommonName != p.module || len(csr.URIs) != 1 || csr.URIs[0].String() != uri ||
		len(csr.DNSNames)+len(csr.IPAddresses)+len(csr.EmailAddresses) != 0 {
		log.Printf("device_cert_renew_failed module=%s reason=invalid_csr_claims", p.module)
		return true
	}
	ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
	defer cancel()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=db_begin", p.module)
		return true
	}
	defer tx.Rollback(ctx)
	var registeredPub []byte
	var currentSerial string
	if err = tx.QueryRow(ctx, "SELECT public_key,serial FROM modules WHERE id=$1 AND server_id=$2 AND NOT revoked FOR UPDATE", p.module, s.cfg.Server).Scan(&registeredPub, &currentSerial); err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=module_unavailable", p.module)
		return true
	}
	if !hmac.Equal(registeredPub, cp) {
		log.Printf("device_cert_renew_failed module=%s reason=public_key_mismatch", p.module)
		return true
	}
	sn, err := randomSerial()
	if err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=serial_entropy", p.module)
		return true
	}
	san, _ := url.Parse(uri)
	now := time.Now().UTC()
	notAfter := now.Add(deviceCertLifetime)
	if notAfter.After(s.cfg.DeviceCA.NotAfter) {
		notAfter = s.cfg.DeviceCA.NotAfter
	}
	tmpl := &x509.Certificate{
		SerialNumber: sn,
		Subject:      pkix.Name{CommonName: p.module},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		URIs:         []*url.URL{san},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, s.cfg.DeviceCA, cp, s.cfg.DeviceCAKey)
	if err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=sign_error", p.module)
		return true
	}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	ch := sha256.Sum256(der)
	receiptPayload := strings.Join([]string{"airsim-v2-r4-commit", req.RequestID, s.cfg.Server, p.module, hex.EncodeToString(ch[:]), req.Nonce, ""}, "\n")
	receipt := base64.StdEncoding.EncodeToString(ed25519.Sign(s.cfg.DeviceCAKey, []byte(receiptPayload)))
	if _, err = tx.Exec(ctx, "UPDATE modules SET previous_serial=$1,serial=$2,certificate=$3 WHERE id=$4 AND server_id=$5 AND NOT revoked", currentSerial, sn.String(), certPEM, p.module, s.cfg.Server); err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=db_update", p.module)
		return true
	}
	if err = tx.Commit(ctx); err != nil {
		log.Printf("device_cert_renew_failed module=%s reason=db_commit", p.module)
		return true
	}
	log.Printf("device_cert_renewed module=%s expires=%s", p.module, notAfter.Format(time.RFC3339))
	return s.enqueue(p, "cert_renewed", map[string]string{
		"request_id":      req.RequestID,
		"server_id":       s.cfg.Server,
		"module_id":       p.module,
		"certificate_pem": certPEM,
		"receipt_base64":  receipt,
	})
}
