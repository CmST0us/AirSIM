package control

import (
	"airsim.local/server/internal/store"
	"airsim.local/server/internal/wire"
	"airsim.local/server/migrations"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func pairingModule(t *testing.T, user, server string) (string, ed25519.PrivateKey, string) {
	t.Helper()
	module := wire.ID()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri, _ := url.Parse("urn:airsim:" + server + ":module:" + module)
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(now.UnixNano()),
		Subject:      pkix.Name{CommonName: module},
		URIs:         []*url.URL{uri},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	return module, private, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

func pairingRequest(t *testing.T, handler http.Handler, method, path string, body any, bearer string) (int, []byte) {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	request := httptest.NewRequest(method, path, bytes.NewReader(raw))
	request.Header.Set("Content-Type", "application/json")
	request.RemoteAddr = "192.0.2.10:40000"
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response.Code, response.Body.Bytes()
}

func TestPairingDatabaseScopeClaimRefreshAndRevoke(t *testing.T) {
	databaseURL := os.Getenv("AIRSIM_PAIRING_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("isolated PostgreSQL URL required")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	db := &store.Store{Pool: pool}
	var table *string
	_ = db.QueryRow(ctx, "SELECT to_regclass('public.schema_version')::text").Scan(&table)
	if table != nil {
		t.Fatal("test requires empty database")
	}
	if _, err = db.Exec(ctx, migrations.Initial); err != nil {
		t.Fatal(err)
	}
	if err = db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	server, user := wire.ID(), wire.ID()
	if _, err = db.Exec(ctx, "INSERT INTO identity(server_id,user_id) VALUES($1,$2)", server, user); err != nil {
		t.Fatal(err)
	}
	module, private, certificate := pairingModule(t, user, server)
	second, secondPrivate, secondCertificate := pairingModule(t, user, server)
	public := private.Public().(ed25519.PublicKey)
	secondPublic := secondPrivate.Public().(ed25519.PublicKey)
	for id, value := range map[string]struct {
		public []byte
		cert   string
	}{
		module: {public: public, cert: certificate},
		second: {public: secondPublic, cert: secondCertificate},
	} {
		if _, err = db.Exec(ctx, `INSERT INTO modules(id,user_id,server_id,public_key,serial,certificate)
 VALUES($1,$2,$3,$4,$5,$6)`, id, user, server, value.public, wire.ID(), value.cert); err != nil {
			t.Fatal(err)
		}
	}
	s := New(db, Config{
		Server: server, API: "https://api.airsim.test", Device: "https://device.airsim.test",
		Media: "https://api.airsim.test", EdgeToken: wire.Token(), HMAC: wire.Token(),
	})
	requestID, pollToken, refreshToken := wire.ID(), wire.Token(), wire.Token()
	status, response := pairingRequest(t, s.Handler(), "POST", "/v2/pairing/challenges", map[string]string{
		"request_id": requestID, "module_id": module, "poll_token": pollToken,
	}, "")
	if status != http.StatusCreated {
		t.Fatalf("challenge: %d %s", status, response)
	}
	var challenge struct {
		RequestID string `json:"request_id"`
		Module    string `json:"module_id"`
		Server    string `json:"server_id"`
		Nonce     string `json:"nonce"`
		Expires   string `json:"expires_at"`
	}
	if json.Unmarshal(response, &challenge) != nil {
		t.Fatal("challenge response")
	}
	message := pairingProofBytes(requestID, server, module, challenge.Nonce, challenge.Expires, wire.Hash(pollToken))
	proof := base64.StdEncoding.EncodeToString(ed25519.Sign(private, message))
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/"+requestID+"/approve", map[string]string{
		"public_key_base64": base64.StdEncoding.EncodeToString(public), "proof_base64": proof,
	}, pollToken)
	if status != http.StatusOK {
		t.Fatalf("approve: %d %s", status, response)
	}
	var approved struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(response, &approved) != nil || !codePattern.MatchString(approved.Code) {
		t.Fatal("approved code")
	}
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/lookup", map[string]string{"code": approved.Code}, "")
	if status != http.StatusOK {
		t.Fatalf("lookup: %d %s", status, response)
	}
	client, claim := wire.ID(), wire.ID()
	claimBody := map[string]string{
		"code": approved.Code, "claim_id": claim, "client_installation_id": client, "refresh_token": refreshToken,
	}
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", claimBody, "")
	if status != http.StatusCreated {
		t.Fatalf("claim: %d %s", status, response)
	}
	var session sessionResponse
	if json.Unmarshal(response, &session) != nil || session.Client != client || session.Module != module {
		t.Fatal("session response")
	}
	status, response = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, session.Token)
	if status != http.StatusOK {
		t.Fatalf("modules: %d %s", status, response)
	}
	var modules struct {
		Modules []struct {
			Module string `json:"module_id"`
		} `json:"modules"`
	}
	if json.Unmarshal(response, &modules) != nil || len(modules.Modules) != 1 || modules.Modules[0].Module != module {
		t.Fatal("module scope")
	}
	status, _ = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", claimBody, "")
	if status != http.StatusOK {
		t.Fatal("idempotent claim")
	}
	otherClaim := map[string]string{
		"code": approved.Code, "claim_id": wire.ID(), "client_installation_id": wire.ID(), "refresh_token": wire.Token(),
	}
	status, _ = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", otherClaim, "")
	if status != http.StatusConflict {
		t.Fatal("second claimant")
	}
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/client-sessions/refresh", map[string]string{
		"client_installation_id": client, "refresh_token": refreshToken,
	}, "")
	if status != http.StatusOK {
		t.Fatalf("refresh: %d %s", status, response)
	}
	var refreshed sessionResponse
	if json.Unmarshal(response, &refreshed) != nil || refreshed.Token == session.Token {
		t.Fatal("refresh token rotation")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, session.Token)
	if status != http.StatusUnauthorized {
		t.Fatal("old access token remained valid")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, refreshed.Token)
	if status != http.StatusOK {
		t.Fatal("new access token rejected")
	}
	if _, err = db.Exec(ctx, "UPDATE clients SET revoked=true WHERE id=$1", client); err != nil {
		t.Fatal(err)
	}
	status, _ = pairingRequest(t, s.Handler(), "POST", "/v2/client-sessions/refresh", map[string]string{
		"client_installation_id": client, "refresh_token": refreshToken,
	}, "")
	if status != http.StatusUnauthorized {
		t.Fatal("revoked session refreshed")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, refreshed.Token)
	if status != http.StatusUnauthorized {
		t.Fatal("revoked access token remained valid")
	}
	if strings.Contains(string(response), refreshToken) {
		t.Fatal("refresh token leaked")
	}
}
