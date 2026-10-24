package admin

import (
	"airsim.local/server/internal/store"
	"airsim.local/server/internal/wire"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var invalid = errors.New("provision_invalid")

func Save(path string, data []byte) error {
	f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	defer f.Close()
	if _, e = f.Write(data); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	d, e := os.Open(filepath.Dir(path))
	if e != nil {
		return e
	}
	defer d.Close()
	return d.Sync()
}
func read(path string) ([]byte, error) {
	st, e := os.Stat(path)
	if e != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		return nil, invalid
	}
	return os.ReadFile(path)
}
func Init(ctx context.Context, db *store.Store, dir string) error {
	if e := os.Mkdir(dir, 0700); e != nil {
		return e
	}
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		return e
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "AirSIM R4 Device CA"}, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(5, 0, 0), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, key)
	if e != nil {
		return e
	}
	pk, e := x509.MarshalPKCS8PrivateKey(key)
	if e != nil {
		return e
	}
	files := map[string][]byte{"device-ca.pem": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), "device-ca-key.pem": pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}), "edge-token": []byte(wire.Token()), "media-token": []byte(wire.Token()), "command-hmac": []byte(wire.Token())}
	server, owner := wire.ID(), wire.ID()
	meta, _ := json.Marshal(map[string]string{"server_id": server, "user_id": owner})
	files["identity.json"] = meta
	for name, b := range files {
		if e = Save(filepath.Join(dir, name), b); e != nil {
			return e
		}
	}
	_, e = db.Exec(ctx, "INSERT INTO identity(server_id,user_id) VALUES($1,$2)", server, owner)
	return e
}
func Client(ctx context.Context, db *store.Store, out string) error {
	tx, e := db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var owner string
	if e = tx.QueryRow(ctx, "SELECT user_id FROM identity FOR UPDATE").Scan(&owner); e != nil {
		return e
	}
	var count int
	if e = tx.QueryRow(ctx, "SELECT count(*) FROM clients WHERE user_id=$1 AND NOT revoked AND expires_at>now()", owner).Scan(&count); e != nil {
		return e
	}
	if count >= 16 {
		return errors.New("capacity_exceeded")
	}
	id, token := wire.ID(), wire.Token()
	expires := time.Now().UTC().Add(time.Hour)
	if _, e = tx.Exec(ctx, "INSERT INTO clients(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)", id, owner, wire.Hash(token), expires); e != nil {
		return e
	}
	b, _ := json.Marshal(map[string]any{"client_installation_id": id, "token": token, "expires_at": expires})
	if e = Save(out, b); e != nil {
		return e
	}
	return tx.Commit(ctx)
}

type Prepare struct {
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
type Response struct {
	Request string `json:"request_id"`
	Module  string `json:"module_id"`
	Public  string `json:"public_key_base64"`
	CSR     string `json:"csr_pem"`
	Proof   string `json:"proof_base64"`
}
type Bundle struct {
	Request     string `json:"request_id"`
	Server      string `json:"server_id"`
	Module      string `json:"module_id"`
	Certificate string `json:"certificate_pem"`
	Receipt     string `json:"receipt_base64"`
}

func Issue(ctx context.Context, db *store.Store, dir, request, response, out string) error {
	a, e := read(request)
	if e != nil {
		return e
	}
	b, e := read(response)
	if e != nil {
		return e
	}
	var p Prepare
	var r Response
	if wire.Decode(a, &p, "request_id", "server_id", "api_origin", "device_origin", "media_origin", "device_ca_pem", "server_ca_pem", "nonce", "expires_at") != nil || wire.Decode(b, &r, "request_id", "module_id", "public_key_base64", "csr_pem", "proof_base64") != nil {
		return invalid
	}
	if p.Server != os.Getenv("AIRSIM_SERVER_ID") || p.API != os.Getenv("AIRSIM_API_ORIGIN") || p.Device != os.Getenv("AIRSIM_DEVICE_ORIGIN") || p.Media != os.Getenv("AIRSIM_MEDIA_ORIGIN") {
		return invalid
	}
	if p.Request != r.Request || !wire.UUID.MatchString(p.Request) || !wire.UUID.MatchString(p.Server) || !wire.UUID.MatchString(r.Module) || !wire.Hex.MatchString(p.Nonce) {
		return invalid
	}
	exp, e := time.Parse(time.RFC3339Nano, p.Expires)
	if e != nil || !strings.HasSuffix(p.Expires, "Z") || !exp.After(time.Now()) || time.Until(exp) > 10*time.Minute {
		return invalid
	}
	for _, s := range []string{p.API, p.Device, p.Media} {
		u, e := url.Parse(s)
		if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || strings.ContainsAny(s, "\r\n") {
			return invalid
		}
	}
	block, rest := pem.Decode([]byte(r.CSR))
	if block == nil || block.Type != "CERTIFICATE REQUEST" || len(strings.TrimSpace(string(rest))) != 0 {
		return invalid
	}
	csr, e := x509.ParseCertificateRequest(block.Bytes)
	if e != nil || csr.CheckSignature() != nil {
		return invalid
	}
	pub, e := base64.StdEncoding.Strict().DecodeString(r.Public)
	if e != nil || len(pub) != 32 {
		return invalid
	}
	cp, ok := csr.PublicKey.(ed25519.PublicKey)
	uri := "urn:airsim:" + p.Server + ":module:" + r.Module
	if !ok || string(cp) != string(pub) || csr.Subject.CommonName != r.Module || len(csr.URIs) != 1 || csr.URIs[0].String() != uri || len(csr.DNSNames) != 0 || len(csr.IPAddresses) != 0 || len(csr.EmailAddresses) != 0 {
		return invalid
	}
	h := sha256.Sum256(csr.Raw)
	proof := strings.Join([]string{"airsim-v2-r4-provision", p.Request, p.Server, r.Module, p.API, p.Device, p.Media, p.Nonce, p.Expires, hex.EncodeToString(h[:]), ""}, "\n")
	sig, e := base64.StdEncoding.Strict().DecodeString(r.Proof)
	if e != nil || !ed25519.Verify(cp, []byte(proof), sig) {
		return invalid
	}
	caBytes, e := read(filepath.Join(dir, "device-ca.pem"))
	if e != nil || string(caBytes) != p.CA {
		return invalid
	}
	cb, _ := pem.Decode(caBytes)
	if cb == nil {
		return invalid
	}
	ca, e := x509.ParseCertificate(cb.Bytes)
	if e != nil {
		return invalid
	}
	keyBytes, e := read(filepath.Join(dir, "device-ca-key.pem"))
	if e != nil {
		return e
	}
	kb, _ := pem.Decode(keyBytes)
	if kb == nil {
		return invalid
	}
	keyAny, e := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if e != nil {
		return invalid
	}
	key, ok := keyAny.(ed25519.PrivateKey)
	if !ok {
		return invalid
	}
	canonical, _ := json.Marshal(p)
	responseCanonical, _ := json.Marshal(r)
	digest := wire.Hash(string(canonical) + string(responseCanonical))
	tx, e := db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var server, owner string
	if e = tx.QueryRow(ctx, "SELECT server_id,user_id FROM identity FOR UPDATE").Scan(&server, &owner); e != nil || server != p.Server {
		return invalid
	}
	var existingDigest string
	var existing []byte
	e = tx.QueryRow(ctx, "SELECT request_digest,bundle FROM provisions WHERE request_id=$1", p.Request).Scan(&existingDigest, &existing)
	if e == nil {
		if digest != existingDigest {
			return errors.New("provision_conflict")
		}
		return Save(out, existing)
	}
	var count int
	if e = tx.QueryRow(ctx, "SELECT count(*) FROM modules WHERE user_id=$1", owner).Scan(&count); e != nil {
		return e
	}
	if count >= 16 {
		return errors.New("capacity_exceeded")
	}
	sn := serial()
	san, _ := url.Parse(uri)
	tmpl := &x509.Certificate{SerialNumber: sn, Subject: pkix.Name{CommonName: r.Module}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().AddDate(0, 0, 30), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, URIs: []*url.URL{san}}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, ca, cp, key)
	if e != nil {
		return e
	}
	cert := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	ch := sha256.Sum256(der)
	receipt := strings.Join([]string{"airsim-v2-r4-commit", p.Request, p.Server, r.Module, hex.EncodeToString(ch[:]), p.Nonce, ""}, "\n")
	bundle := Bundle{p.Request, p.Server, r.Module, cert, base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(receipt)))}
	encoded, _ := json.Marshal(bundle)
	if _, e = tx.Exec(ctx, "INSERT INTO modules(id,user_id,server_id,public_key,serial,certificate) VALUES($1,$2,$3,$4,$5,$6)", r.Module, owner, p.Server, pub, sn.String(), cert); e != nil {
		return errors.New("provision_conflict")
	}
	if _, e = tx.Exec(ctx, "INSERT INTO provisions(request_id,module_id,request_digest,bundle) VALUES($1,$2,$3,$4)", p.Request, r.Module, digest, encoded); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	return Save(out, encoded)
}
func serial() *big.Int {
	n, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if e != nil {
		panic(e)
	}
	return n.Add(n, big.NewInt(1))
}
