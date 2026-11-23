package control

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadDeviceCAValidation(t *testing.T) {
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test Device CA"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	pk, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "device-ca-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}), 0600); err != nil {
		t.Fatal(err)
	}

	// Empty keyPath cleanly disables auto-renewal.
	ca, k, err := LoadDeviceCA(certPEM, "")
	if err != nil || ca != nil || k != nil {
		t.Fatalf("empty keyPath: ca=%v key=%v err=%v", ca, k, err)
	}
	// Matching cert + key loads cleanly.
	ca, k, err = LoadDeviceCA(certPEM, keyPath)
	if err != nil || ca == nil || len(k) != ed25519.PrivateKeySize {
		t.Fatalf("valid CA failed: %v", err)
	}
	// Mismatched key must fail closed.
	_, otherKey, _ := ed25519.GenerateKey(rand.Reader)
	otherPK, _ := x509.MarshalPKCS8PrivateKey(otherKey)
	otherPath := filepath.Join(dir, "other-key.pem")
	_ = os.WriteFile(otherPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: otherPK}), 0600)
	if _, _, err := LoadDeviceCA(certPEM, otherPath); err == nil {
		t.Fatal("mismatched CA key accepted")
	}
}
