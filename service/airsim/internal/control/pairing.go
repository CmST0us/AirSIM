package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"github.com/jackc/pgx/v5"
	"math/big"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

const pairingLifetime = 5 * time.Minute

var codePattern = regexp.MustCompile(`^[0-9]{8}$`)

type rateWindow struct {
	count int
	reset time.Time
}

// pairingLimiter is process-local. Its fixed per-source windows are backed by
// database limits for operations that must survive a restart.
type pairingLimiter struct {
	mu        sync.Mutex
	windows   map[string]rateWindow
	lastSweep time.Time
}

func (l *pairingLimiter) allow(key string, limit int, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.windows == nil {
		l.windows = map[string]rateWindow{}
	}
	if l.lastSweep.IsZero() || now.Sub(l.lastSweep) >= time.Minute {
		for k, v := range l.windows {
			if !now.Before(v.reset) {
				delete(l.windows, k)
			}
		}
		l.lastSweep = now
	}
	v, found := l.windows[key]
	if !found && len(l.windows) >= 1024 {
		return false
	}
	if !found || !now.Before(v.reset) {
		v = rateWindow{reset: now.Add(time.Minute)}
	}
	if v.count >= limit {
		l.windows[key] = v
		return false
	}
	v.count++
	l.windows[key] = v
	return true
}

func (s *Server) pairingSource(r *http.Request) string {
	if candidate := r.Header.Get("X-AirSIM-Remote-IP"); net.ParseIP(candidate) != nil &&
		subtle.ConstantTimeCompare([]byte(r.Header.Get("X-AirSIM-Edge-Token")), []byte(s.cfg.EdgeToken)) == 1 {
		return candidate
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && net.ParseIP(host) != nil {
		return host
	}
	if net.ParseIP(r.RemoteAddr) != nil {
		return r.RemoteAddr
	}
	return "unknown"
}

func (s *Server) pairingKey(domain string) []byte {
	outer := hmac.New(sha256.New, []byte(s.cfg.HMAC))
	_, _ = outer.Write([]byte("airsim-v2-pairing-" + domain))

	inner := hmac.New(sha256.New, outer.Sum(nil))
	_, _ = inner.Write([]byte("airsim-v2-pairing-" + domain))
	return inner.Sum(nil)
}

func (s *Server) pairingCodeHash(code string) string {
	h := hmac.New(sha256.New, s.pairingKey("code-hash"))
	_, _ = h.Write([]byte(code))
	return hex.EncodeToString(h.Sum(nil))
}

func (s *Server) sealPairingCode(code string) ([]byte, error) {
	block, err := aes.NewCipher(s.pairingKey("code-cipher"))
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, err
	}
	return append(nonce, gcm.Seal(nil, nonce, []byte(code), nil)...), nil
}

func (s *Server) openPairingCode(sealed []byte) (string, error) {
	block, err := aes.NewCipher(s.pairingKey("code-cipher"))
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil || len(sealed) < gcm.NonceSize() {
		return "", errors.New("pairing_code_invalid")
	}
	nonce, data := sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():]
	plain, err := gcm.Open(nil, nonce, data, nil)
	if err != nil || !codePattern.Match(plain) {
		return "", errors.New("pairing_code_invalid")
	}
	return string(plain), nil
}

func randomPairingCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(100000000))
	if err != nil {
		return "", err
	}
	return leftPadDecimal(n.Int64(), 8), nil
}

func leftPadDecimal(n int64, width int) string {
	value := []byte{}
	for n > 0 {
		value = append([]byte{byte(n%10) + '0'}, value...)
		n /= 10
	}
	for len(value) < width {
		value = append([]byte{'0'}, value...)
	}
	return string(value)
}

func pairingProofBytes(requestID, serverID, moduleID, nonce, expires, pollHash string) []byte {
	return []byte("airsim-v2-pairing\n" + strings.Join(
		[]string{requestID, serverID, moduleID, nonce, expires, pollHash}, "\n") + "\n")
}

func (s *Server) pairing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.URL.Path {
	case "/v2/pairing/challenges":
		if r.Method != http.MethodPost {
			wire.Error(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		s.pairingChallenge(w, r)
	case "/v2/pairing/lookup":
		if r.Method != http.MethodPost {
			wire.Error(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		s.pairingLookup(w, r)
	case "/v2/pairing/claim":
		if r.Method != http.MethodPost {
			wire.Error(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		s.pairingClaim(w, r)
	default:
		s.pairingRequest(w, r)
	}
}

func (s *Server) pairingChallenge(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RequestID       string `json:"request_id"`
		Module          string `json:"module_id"`
		PollToken       string `json:"poll_token"`
		ReplaceExisting bool   `json:"replace_existing,omitempty"`
	}
	if wire.Body(w, r, &body, 16*1024, "request_id", "module_id", "poll_token") != nil ||
		!wire.UUID.MatchString(body.RequestID) || !wire.UUID.MatchString(body.Module) || !wire.Hex.MatchString(body.PollToken) {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	if !s.pairingRates.allow("challenge:"+s.pairingSource(r), 8, time.Now()) {
		wire.Error(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	pollHash := wire.Hash(body.PollToken)
	nonce, expires := wire.Token(), time.Now().UTC().Add(pairingLifetime).Truncate(time.Microsecond)
	tx, err := s.db.Begin(ctx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(41742003)"); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	var server, module string
	var certificate string
	err = tx.QueryRow(ctx, `SELECT m.server_id,m.id,m.certificate
 FROM modules m JOIN identity i ON i.server_id=m.server_id
 WHERE m.id=$1 AND m.server_id=$2 AND NOT m.revoked`, body.Module, s.cfg.Server).Scan(&server, &module, &certificate)
	if err == pgx.ErrNoRows || (err == nil && !validModuleCertificate(certificate, s.cfg.Server, module, time.Now())) {
		wire.Error(w, http.StatusNotFound, "module_unavailable")
		return
	}
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	var existingModule, existingPoll, existingNonce, existingState string
	var existingExpiry time.Time
	var existingReplace bool
	err = tx.QueryRow(ctx, `SELECT module_id,poll_hash,nonce,state,expires_at,replace_existing
 FROM pairing_requests WHERE id=$1 FOR UPDATE`, body.RequestID).Scan(
		&existingModule, &existingPoll, &existingNonce, &existingState, &existingExpiry, &existingReplace)
	if err == nil {
		if existingModule != body.Module || existingPoll != pollHash || existingReplace != body.ReplaceExisting {
			wire.Error(w, http.StatusConflict, "pairing_conflict")
			return
		}
		wire.JSON(w, http.StatusOK, map[string]any{
			"request_id": body.RequestID, "module_id": body.Module, "server_id": server,
			"nonce": existingNonce, "expires_at": existingExpiry, "replace_existing": existingReplace,
		})
		return
	}
	if err != pgx.ErrNoRows {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	var alreadyPaired bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(
 SELECT 1 FROM clients WHERE module_id=$1 AND NOT revoked
)`, body.Module).Scan(&alreadyPaired); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if alreadyPaired && !body.ReplaceExisting {
		wire.Error(w, http.StatusConflict, "module_already_paired")
		return
	}
	var modulePending, globalPending int
	if err = tx.QueryRow(ctx, `SELECT
 count(*) FILTER (WHERE module_id=$1),
 count(*)
 FROM pairing_requests
 WHERE expires_at>now() AND state IN ('awaiting_device','awaiting_phone')`, body.Module).Scan(&modulePending, &globalPending); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if modulePending >= 8 || globalPending >= 128 {
		wire.Error(w, http.StatusTooManyRequests, "capacity_exceeded")
		return
	}
	if _, err = tx.Exec(ctx, `INSERT INTO pairing_requests
 (id,module_id,server_id,poll_hash,nonce,expires_at,state,replace_existing)
 VALUES($1,$2,$3,$4,$5,$6,'awaiting_device',$7)`,
		body.RequestID, body.Module, server, pollHash, nonce, expires, body.ReplaceExisting); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	wire.JSON(w, http.StatusCreated, map[string]any{
		"request_id": body.RequestID, "module_id": body.Module, "server_id": server,
		"nonce": nonce, "expires_at": expires, "replace_existing": body.ReplaceExisting,
	})
}

func validModuleCertificate(raw, server, module string, now time.Time) bool {
	if len(raw) == 0 {
		return false
	}
	block, _ := decodePEMCertificate(raw)
	if block == nil || !now.Before(block.NotAfter) || len(block.URIs) != 1 {
		return false
	}
	return block.URIs[0].String() == "urn:airsim:"+server+":module:"+module
}

func decodePEMCertificate(raw string) (*x509.Certificate, error) {
	block, rest := pem.Decode([]byte(raw))
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, wire.ErrInvalid
	}
	return x509.ParseCertificate(block.Bytes)
}

func (s *Server) pairingRequest(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/v2/pairing/"), "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || !wire.UUID.MatchString(parts[0]) {
		wire.Error(w, http.StatusNotFound, "not_found")
		return
	}
	pollToken, ok := pairingBearer(r)
	if !ok {
		wire.Error(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		s.pairingStatus(w, r, parts[0], pollToken)
	case len(parts) == 1 && r.Method == http.MethodDelete:
		s.pairingCancel(w, r, parts[0], pollToken)
	case len(parts) == 2 && parts[1] == "approve" && r.Method == http.MethodPost:
		s.pairingApprove(w, r, parts[0], pollToken)
	default:
		wire.Error(w, http.StatusNotFound, "not_found")
	}
}

func pairingBearer(r *http.Request) (string, bool) {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return "", false
	}
	token := strings.TrimPrefix(header, "Bearer ")
	return token, wire.Hex.MatchString(token)
}

type pairingSnapshot struct {
	RequestID       string    `json:"request_id"`
	Module          string    `json:"module_id"`
	State           string    `json:"state"`
	Expires         time.Time `json:"expires_at"`
	Code            string    `json:"code"`
	Online          bool      `json:"online"`
	ReplaceExisting bool      `json:"replace_existing"`
}

func (s *Server) pairingApprove(w http.ResponseWriter, r *http.Request, requestID, pollToken string) {
	var body struct {
		Public string `json:"public_key_base64"`
		Proof  string `json:"proof_base64"`
	}
	if wire.Body(w, r, &body, 16*1024, "public_key_base64", "proof_base64") != nil {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	public, err := base64.StdEncoding.Strict().DecodeString(body.Public)
	if err != nil || len(public) != ed25519.PublicKeySize {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	proof, err := base64.StdEncoding.Strict().DecodeString(body.Proof)
	if err != nil || len(proof) != ed25519.SignatureSize {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	var server, module, storedPollHash, nonce, state string
	var expires time.Time
	var replaceExisting bool
	err = tx.QueryRow(ctx, `SELECT server_id,module_id,poll_hash,nonce,expires_at,state,replace_existing
 FROM pairing_requests WHERE id=$1 FOR UPDATE`, requestID).Scan(
		&server, &module, &storedPollHash, &nonce, &expires, &state, &replaceExisting)
	if err != nil || storedPollHash != wire.Hash(pollToken) || !time.Now().Before(expires) || state != "awaiting_device" {
		wire.Error(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var registeredPublic []byte
	var certificate string
	err = tx.QueryRow(ctx, `SELECT public_key,certificate FROM modules
 WHERE id=$1 AND server_id=$2 AND NOT revoked`, module, s.cfg.Server).Scan(&registeredPublic, &certificate)
	if err != nil || !hmac.Equal(registeredPublic, public) ||
		!validModuleCertificate(certificate, server, module, time.Now()) {
		wire.Error(w, http.StatusConflict, "pairing_proof_invalid")
		return
	}
	expiryText := expires.UTC().Format(time.RFC3339Nano)
	if !ed25519.Verify(ed25519.PublicKey(public), pairingProofBytes(
		requestID, server, module, nonce, expiryText, wire.Hash(pollToken)), proof) {
		wire.Error(w, http.StatusConflict, "pairing_proof_invalid")
		return
	}
	code, sealed, codeHash, err := s.newPairingCode(ctx, tx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if _, err = tx.Exec(ctx, `UPDATE pairing_requests
 SET state='awaiting_phone',code_hash=$2,code_cipher=$3,proof=$4
 WHERE id=$1 AND state='awaiting_device'`, requestID, codeHash, sealed, proof); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	wire.JSON(w, http.StatusOK, pairingSnapshot{
		RequestID: requestID, Module: module, State: "awaiting_phone",
		Expires: expires, Code: code, Online: s.moduleOnline(module),
		ReplaceExisting: replaceExisting,
	})
}

func (s *Server) newPairingCode(ctx context.Context, tx pgx.Tx) (string, []byte, string, error) {
	for i := 0; i < 16; i++ {
		code, err := randomPairingCode()
		if err != nil {
			return "", nil, "", err
		}
		hash := s.pairingCodeHash(code)
		var exists bool
		if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pairing_requests WHERE code_hash=$1)", hash).Scan(&exists); err != nil {
			return "", nil, "", err
		}
		if exists {
			continue
		}
		sealed, err := s.sealPairingCode(code)
		if err != nil {
			return "", nil, "", err
		}
		return code, sealed, hash, nil
	}
	return "", nil, "", errors.New("pairing_code_collision")
}

func (s *Server) moduleOnline(module string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.peers[module]
	return p != nil && p.snapshot != nil
}

func (s *Server) moduleName(module string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p := s.last[module]; p != nil {
		switch p.platform {
		case "rm500u-embedded":
			return "RM500U"
		case "eg25-qdc507":
			return "EG25 QDC507"
		}
	}
	return "AirSIM"
}

func (s *Server) pairingStatus(w http.ResponseWriter, r *http.Request, requestID, pollToken string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var module, state string
	var expires time.Time
	var sealed []byte
	var replaceExisting bool
	err := s.db.QueryRow(ctx, `SELECT module_id,state,expires_at,code_cipher,replace_existing
 FROM pairing_requests WHERE id=$1 AND poll_hash=$2`, requestID, wire.Hash(pollToken)).Scan(
		&module, &state, &expires, &sealed, &replaceExisting)
	if err != nil {
		wire.Error(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	status := http.StatusOK
	if !time.Now().Before(expires) && state != "connected" {
		state, status = "expired", http.StatusGone
	}
	code := ""
	if state == "awaiting_phone" {
		var err error
		if code, err = s.openPairingCode(sealed); err != nil {
			wire.Error(w, http.StatusServiceUnavailable, "pairing_unavailable")
			return
		}
	}
	wire.JSON(w, status, pairingSnapshot{
		RequestID: requestID, Module: module, State: state,
		Expires: expires, Code: code, Online: s.moduleOnline(module),
		ReplaceExisting: replaceExisting,
	})
}

func (s *Server) pairingCancel(w http.ResponseWriter, r *http.Request, requestID, pollToken string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	var module, state string
	var expires time.Time
	var replaceExisting bool
	err = tx.QueryRow(ctx, `SELECT module_id,state,expires_at,replace_existing FROM pairing_requests
 WHERE id=$1 AND poll_hash=$2 FOR UPDATE`, requestID, wire.Hash(pollToken)).Scan(
		&module, &state, &expires, &replaceExisting)
	if err != nil {
		wire.Error(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	status := http.StatusOK
	if !time.Now().Before(expires) && state != "connected" {
		state, status = "expired", http.StatusGone
	} else if state == "awaiting_device" || state == "awaiting_phone" {
		if _, err = tx.Exec(ctx, "UPDATE pairing_requests SET state='cancelled' WHERE id=$1", requestID); err != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
		state = "cancelled"
	}
	if err = tx.Commit(ctx); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	wire.JSON(w, status, pairingSnapshot{
		RequestID: requestID, Module: module, State: state,
		Expires: expires, Code: "", Online: s.moduleOnline(module),
		ReplaceExisting: replaceExisting,
	})
}

func (s *Server) pairingLookup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if wire.Body(w, r, &body, 1024, "code") != nil || !codePattern.MatchString(body.Code) {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	if !s.pairingRates.allow("lookup:"+s.pairingSource(r), 10, time.Now()) {
		wire.Error(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var requestID, module string
	var expires time.Time
	var sealed []byte
	err := s.db.QueryRow(ctx, `SELECT p.id,p.module_id,p.expires_at,p.code_cipher
 FROM pairing_requests p JOIN modules m ON m.id=p.module_id
 WHERE p.code_hash=$1 AND p.server_id=$2 AND p.state='awaiting_phone'
 AND p.expires_at>now() AND NOT m.revoked
 AND (p.replace_existing OR NOT EXISTS(
   SELECT 1 FROM clients c WHERE c.module_id=p.module_id AND NOT c.revoked
 ))`,
		s.pairingCodeHash(body.Code), s.cfg.Server).Scan(
		&requestID, &module, &expires, &sealed)
	if err != nil {
		wire.Error(w, http.StatusNotFound, "pairing_code_unavailable")
		return
	}
	decoded, err := s.openPairingCode(sealed)
	if err != nil || subtle.ConstantTimeCompare([]byte(decoded), []byte(body.Code)) != 1 {
		wire.Error(w, http.StatusNotFound, "pairing_code_unavailable")
		return
	}
	wire.JSON(w, http.StatusOK, map[string]any{
		"request_id": requestID, "server_id": s.cfg.Server, "module_id": module,
		"name": s.moduleName(module), "short_id": module[len(module)-8:],
		"online": s.moduleOnline(module), "expires_at": expires,
	})
}

func (s *Server) pairingClaim(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code         string `json:"code"`
		Claim        string `json:"claim_id"`
		Client       string `json:"client_installation_id"`
		RefreshToken string `json:"refresh_token"`
	}
	if wire.Body(w, r, &body, 16*1024, "code", "claim_id", "client_installation_id", "refresh_token") != nil ||
		!codePattern.MatchString(body.Code) || !wire.UUID.MatchString(body.Claim) ||
		!wire.UUID.MatchString(body.Client) || !wire.Hex.MatchString(body.RefreshToken) {
		wire.Error(w, http.StatusBadRequest, "invalid_parameters")
		return
	}
	if !s.pairingRates.allow("lookup:"+s.pairingSource(r), 10, time.Now()) {
		wire.Error(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	var requestID, module, state string
	var expires time.Time
	var sealed []byte
	var claimID, clientID, refreshHash *string
	var replaceExisting bool
	err = tx.QueryRow(ctx, `SELECT p.id,p.module_id,p.state,p.expires_at,p.code_cipher,p.claim_id,c.id,c.refresh_hash,p.replace_existing
 FROM pairing_requests p
 JOIN modules m ON m.id=p.module_id
 LEFT JOIN clients c ON c.id=p.client_id
 WHERE p.code_hash=$1 AND p.server_id=$2 AND NOT m.revoked
 FOR UPDATE OF p`, s.pairingCodeHash(body.Code), s.cfg.Server).Scan(
		&requestID, &module, &state, &expires, &sealed, &claimID, &clientID, &refreshHash, &replaceExisting)
	if err != nil {
		wire.Error(w, http.StatusNotFound, "pairing_code_unavailable")
		return
	}
	decoded, err := s.openPairingCode(sealed)
	if err != nil || subtle.ConstantTimeCompare([]byte(decoded), []byte(body.Code)) != 1 {
		wire.Error(w, http.StatusNotFound, "pairing_code_unavailable")
		return
	}
	if state == "connected" {
		if claimID == nil || clientID == nil || *claimID != body.Claim || *clientID != body.Client ||
			refreshHash == nil || *refreshHash != wire.Hash(body.RefreshToken) {
			wire.Error(w, http.StatusConflict, "pairing_claimed")
			return
		}
		response, err := s.issueAccess(ctx, tx, body.Client, module)
		if err != nil || tx.Commit(ctx) != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
		wire.JSON(w, http.StatusOK, response)
		return
	}
	if state != "awaiting_phone" || !time.Now().Before(expires) {
		wire.Error(w, http.StatusGone, "pairing_code_expired")
		return
	}
	if _, err = tx.Exec(ctx, "SELECT id FROM modules WHERE id=$1 FOR UPDATE", module); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	var alreadyPaired bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(
 SELECT 1 FROM clients WHERE module_id=$1 AND NOT revoked
)`, module).Scan(&alreadyPaired); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if alreadyPaired && !replaceExisting {
		wire.Error(w, http.StatusConflict, "module_already_paired")
		return
	}
	if alreadyPaired {
		if _, err = tx.Exec(ctx, "UPDATE clients SET revoked=true WHERE module_id=$1 AND NOT revoked", module); err != nil {
			wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
			return
		}
	}
	user := ""
	if err = tx.QueryRow(ctx, "SELECT user_id FROM modules WHERE id=$1 AND server_id=$2", module, s.cfg.Server).Scan(&user); err != nil {
		wire.Error(w, http.StatusNotFound, "module_unavailable")
		return
	}
	if _, err = tx.Exec(ctx, `INSERT INTO clients
 (id,user_id,token_hash,expires_at,module_id,refresh_hash,refresh_expires_at,paired_at)
 VALUES($1,$2,$3,NULL,$4,$5,NULL,now())`,
		body.Client, user, wire.Token(), module, wire.Hash(body.RefreshToken)); err != nil {
		wire.Error(w, http.StatusConflict, "pairing_claimed")
		return
	}
	if _, err = tx.Exec(ctx, `UPDATE pairing_requests
 SET state='connected',claim_id=$2,client_id=$3 WHERE id=$1`, requestID, body.Claim, body.Client); err != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	response, err := s.issueAccess(ctx, tx, body.Client, module)
	if err != nil || tx.Commit(ctx) != nil {
		wire.Error(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	if alreadyPaired {
		s.syncUSBRevocations(ctx)
	}
	wire.JSON(w, http.StatusCreated, response)
}
