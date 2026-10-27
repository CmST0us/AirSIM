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
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
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
	var schema int
	if err = db.QueryRow(ctx, "SELECT max(version) FROM schema_version").Scan(&schema); err != nil || schema != 6 {
		t.Fatalf("schema: %d %v", schema, err)
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
	if json.Unmarshal(response, &session) != nil || session.Client != client || session.Module != module || !session.PersistentSession || session.Schema != 3 || session.Expires != nil || session.RefreshExpires != nil {
		t.Fatal("session response")
	}
	var noExpiry bool
	if err = db.QueryRow(ctx, "SELECT expires_at IS NULL AND refresh_expires_at IS NULL FROM clients WHERE id=$1", client).Scan(&noExpiry); err != nil || !noExpiry {
		t.Fatal("paired session retained an expiry")
	}
	_, err = db.Exec(ctx, `INSERT INTO clients(id,user_id,token_hash,expires_at,module_id,refresh_hash,refresh_expires_at,paired_at)
 VALUES($1,$2,$3,NULL,$4,$5,NULL,now())`, wire.ID(), user, wire.Hash(wire.Token()), module, wire.Hash(wire.Token()))
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" || pgErr.ConstraintName != "clients_one_active_per_module" {
		t.Fatalf("second active phone violation: %v", err)
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
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", claimBody, "")
	var retrySession sessionResponse
	if status != http.StatusOK || json.Unmarshal(response, &retrySession) != nil || retrySession.Schema != 3 || retrySession.Expires != nil {
		t.Fatal("idempotent claim")
	}
	otherClaim := map[string]string{
		"code": approved.Code, "claim_id": wire.ID(), "client_installation_id": wire.ID(), "refresh_token": wire.Token(),
	}
	status, _ = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", otherClaim, "")
	if status != http.StatusConflict {
		t.Fatal("second claimant")
	}
	secondChallenge := map[string]string{
		"request_id": wire.ID(), "module_id": module, "poll_token": wire.Token(),
	}
	status, _ = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/challenges", secondChallenge, "")
	if status != http.StatusConflict {
		t.Fatal("paired module accepted another phone")
	}
	if _, err = db.Exec(ctx, "UPDATE clients SET expires_at=now()-interval '1 hour' WHERE id=$1", client); err != nil {
		t.Fatal(err)
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, retrySession.Token)
	if status != http.StatusOK {
		t.Fatal("paired access token depended on expiry")
	}
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/client-sessions/refresh", map[string]string{
		"client_installation_id": client, "refresh_token": refreshToken,
	}, "")
	if status != http.StatusOK {
		t.Fatalf("refresh: %d %s", status, response)
	}
	var refreshed sessionResponse
	if json.Unmarshal(response, &refreshed) != nil || refreshed.Schema != 2 || refreshed.Token == session.Token || !refreshed.PersistentSession || refreshed.Expires == nil || refreshed.RefreshExpires == nil {
		t.Fatal("refresh token rotation")
	}
	if err = db.QueryRow(ctx, "SELECT expires_at IS NULL AND refresh_expires_at IS NULL FROM clients WHERE id=$1", client).Scan(&noExpiry); err != nil || !noExpiry {
		t.Fatal("refresh introduced a server-side expiry")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, retrySession.Token)
	if status != http.StatusUnauthorized {
		t.Fatal("old access token remained valid")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, refreshed.Token)
	if status != http.StatusOK {
		t.Fatal("new access token rejected")
	}
	replaceRequest, replacePoll, replaceRefresh := wire.ID(), wire.Token(), wire.Token()
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/challenges", map[string]any{
		"request_id": replaceRequest, "module_id": module, "poll_token": replacePoll, "replace_existing": true,
	}, "")
	if status != http.StatusCreated {
		t.Fatalf("replacement challenge: %d %s", status, response)
	}
	var replaceChallenge struct {
		Nonce   string `json:"nonce"`
		Expires string `json:"expires_at"`
		Replace bool   `json:"replace_existing"`
	}
	if json.Unmarshal(response, &replaceChallenge) != nil || !replaceChallenge.Replace {
		t.Fatal("replacement challenge response")
	}
	replaceProof := base64.StdEncoding.EncodeToString(ed25519.Sign(private, pairingProofBytes(
		replaceRequest, server, module, replaceChallenge.Nonce, replaceChallenge.Expires, wire.Hash(replacePoll))))
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/"+replaceRequest+"/approve", map[string]string{
		"public_key_base64": base64.StdEncoding.EncodeToString(public), "proof_base64": replaceProof,
	}, replacePoll)
	if status != http.StatusOK {
		t.Fatalf("replacement approve: %d %s", status, response)
	}
	var replaceApproved struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(response, &replaceApproved) != nil || !codePattern.MatchString(replaceApproved.Code) {
		t.Fatal("replacement code")
	}
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/lookup", map[string]string{"code": replaceApproved.Code}, "")
	if status != http.StatusOK {
		t.Fatalf("replacement lookup with active phone: %d %s", status, response)
	}
	replacementClient, replacementClaim := wire.ID(), wire.ID()
	status, response = pairingRequest(t, s.Handler(), "POST", "/v2/pairing/claim", map[string]string{
		"code": replaceApproved.Code, "claim_id": replacementClaim,
		"client_installation_id": replacementClient, "refresh_token": replaceRefresh,
	}, "")
	if status != http.StatusCreated {
		t.Fatalf("replacement claim: %d %s", status, response)
	}
	var replacementSession sessionResponse
	if json.Unmarshal(response, &replacementSession) != nil || replacementSession.Client != replacementClient || replacementSession.Schema != 3 {
		t.Fatal("replacement session")
	}
	var activeClients, revokedOld bool
	if err = db.QueryRow(ctx, `SELECT
 count(*) FILTER (WHERE NOT revoked)=(1)::bigint,
 bool_or(id=$2 AND revoked)
 FROM clients WHERE module_id=$1`, module, client).Scan(&activeClients, &revokedOld); err != nil || !activeClients || !revokedOld {
		t.Fatalf("replacement did not revoke the old phone exclusively: active=%v old=%v err=%v", activeClients, revokedOld, err)
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, refreshed.Token)
	if status != http.StatusUnauthorized {
		t.Fatal("old phone survived replacement")
	}
	status, _ = pairingRequest(t, s.Handler(), "GET", "/v2/modules", nil, replacementSession.Token)
	if status != http.StatusOK {
		t.Fatal("replacement phone rejected")
	}
	client, refreshToken, refreshed = replacementClient, replaceRefresh, replacementSession
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
