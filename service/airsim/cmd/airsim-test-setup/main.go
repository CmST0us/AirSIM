// airsim-test-setup creates only synthetic identities in an explicitly supplied external directory.
package main

import (
	"airsim.local/server/internal/admin"
	"airsim.local/server/internal/wire"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func save(dir, name string, b []byte) {
	if e := admin.Save(filepath.Join(dir, name), b); e != nil {
		panic("test_setup_write_failed")
	}
}
func main() {
	dir := flag.String("dir", "", "external test directory")
	op := flag.String("operation", "tls", "tls or modules")
	port := flag.String("port", "18443", "loopback high port")
	flag.Parse()
	if *dir == "" {
		panic("directory_required")
	}
	if *op == "tls" {
		if e := os.Mkdir(*dir, 0700); e != nil {
			panic("test_setup_directory")
		}
		save(*dir, "database-password", []byte(wire.Token()))
		os.Mkdir(filepath.Join(*dir, "tls"), 0700)
		pub, key, _ := ed25519.GenerateKey(rand.Reader)
		now := time.Now()
		ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "AirSIM isolated test root"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
		der, e := x509.CreateCertificate(rand.Reader, ca, ca, pub, key)
		if e != nil {
			panic("test_tls_failed")
		}
		save(*dir, "tls/root.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
		leaf := &x509.Certificate{SerialNumber: big.NewInt(2), DNSNames: []string{"api.airsim.test", "device.airsim.test", "media.airsim.test"}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, e = x509.CreateCertificate(rand.Reader, leaf, ca, pub, key)
		if e != nil {
			panic("test_tls_failed")
		}
		save(*dir, "tls/server.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
		pk, _ := x509.MarshalPKCS8PrivateKey(key)
		save(*dir, "tls/server-key.pem", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}))
		return
	}
	b, e := os.ReadFile(filepath.Join(*dir, "identity/identity.json"))
	if e != nil {
		panic("test_identity_missing")
	}
	var identity map[string]string
	json.Unmarshal(b, &identity)
	ca, e := os.ReadFile(filepath.Join(*dir, "identity/device-ca.pem"))
	if e != nil {
		panic("test_ca_missing")
	}
	for i := 1; i <= 2; i++ {
		pub, key, _ := ed25519.GenerateKey(rand.Reader)
		module := wire.ID()
		request := wire.ID()
		uri, _ := url.Parse("urn:airsim:" + identity["server_id"] + ":module:" + module)
		der, e := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{Subject: pkix.Name{CommonName: module}, URIs: []*url.URL{uri}}, key)
		if e != nil {
			panic("test_csr_failed")
		}
		p := admin.Prepare{Request: request, Server: identity["server_id"], API: "https://api.airsim.test:" + *port, Device: "https://device.airsim.test:" + *port, Media: "https://media.airsim.test:" + *port, CA: string(ca), Nonce: wire.Token(), Expires: time.Now().UTC().Add(9 * time.Minute).Format(time.RFC3339Nano)}
		root, _ := os.ReadFile(filepath.Join(*dir, "tls/root.pem"))
		p.ServerCA = string(root)
		hash := sha256.Sum256(der)
		proof := strings.Join([]string{"airsim-v2-r4-provision", request, p.Server, module, p.API, p.Device, p.Media, p.Nonce, p.Expires, hex.EncodeToString(hash[:]), ""}, "\n")
		r := admin.Response{Request: request, Module: module, Public: base64.StdEncoding.EncodeToString(pub), CSR: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der})), Proof: base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(proof)))}
		a, _ := json.Marshal(p)
		b, _ := json.Marshal(r)
		save(*dir, fmt.Sprintf("module%d-request.json", i), a)
		save(*dir, fmt.Sprintf("module%d-response.json", i), b)
		pk, _ := x509.MarshalPKCS8PrivateKey(key)
		save(*dir, fmt.Sprintf("module%d-key.pem", i), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}))
	}
}
