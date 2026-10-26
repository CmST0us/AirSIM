package cloud

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pairingFixture(t *testing.T) (*fixture, pairingRequest, time.Time) {
	t.Helper()
	f := newFixture(t)
	f.prepare(t)
	f.issue(t)
	if f.p.Activate(f.bundle) != 200 {
		t.Fatal("activate")
	}
	now := time.Now().UTC()
	r := pairingRequest{uid(), f.req.ServerID, f.p.id.ModuleID, strings.Repeat("ab", 32), now.Add(300 * time.Second).Format(time.RFC3339Nano), strings.Repeat("cd", 32)}
	return f, r, now
}
func pairingHTTP(p *Provisioner, method, path string, b []byte) *httptest.ResponseRecorder {
	h := WithLocal(http.NotFoundHandler(), p, &Agent{})
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestPairingProofBindingsDomainAndNoPrivateMaterial(t *testing.T) {
	f, r, now := pairingFixture(t)
	before, e := os.ReadFile(f.p.path)
	if e != nil {
		t.Fatal(e)
	}
	out, code := f.p.authorizePairing(r, now)
	if code != 200 {
		t.Fatal("authorize", code)
	}
	proof := out.(pairingProof)
	encoded, _ := json.Marshal(proof)
	var wire pairingProof
	if exact(encoded, "request_id,module_id,public_key_base64,proof_base64", &wire) != nil {
		t.Fatal("proof fields")
	}
	pub, _ := decode64(proof.Public)
	sig, _ := decode64(proof.Proof)
	// Independent wire specification, including raw expiry and the trailing LF.
	message := "airsim-v2-r8-pairing\n" + r.RequestID + "\n" + r.ServerID + "\n" + r.ModuleID + "\n" + r.Nonce + "\n" + r.Expires + "\n" + r.PollTokenHash + "\n"
	if proof.RequestID != r.RequestID || proof.ModuleID != r.ModuleID || !ed25519.Verify(ed25519.PublicKey(pub), []byte(message), sig) {
		t.Fatal("signature binding")
	}
	for _, bad := range []string{strings.Replace(message, "r8-pairing", "r4-provision", 1), strings.TrimSuffix(message, "\n"), strings.Replace(message, r.PollTokenHash, strings.Repeat("ef", 32), 1), strings.Replace(message, r.Nonce, strings.Repeat("aa", 32), 1), strings.Replace(message, r.ServerID, uid(), 1), strings.Replace(message, r.ModuleID, uid(), 1), strings.Replace(message, r.RequestID, uid(), 1), strings.Replace(message, r.Expires, now.Add(time.Minute).Format(time.RFC3339Nano), 1)} {
		if ed25519.Verify(ed25519.PublicKey(pub), []byte(bad), sig) {
			t.Fatal("unbound proof field or domain")
		}
	}
	again, c := f.p.authorizePairing(r, now)
	if c != 200 || again.(pairingProof) != proof {
		t.Fatal("exact proof retry")
	}
	b, _ := json.Marshal(r)
	w := pairingHTTP(f.p, "POST", "/v2/local/pairing/authorize", b)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("authorize route")
	}
	raw, e := os.ReadFile(filepath.Join(filepath.Dir(f.p.path), "identity", "identity.json"))
	if e != nil {
		t.Fatal(e)
	}
	var id struct {
		Seed string `json:"seed_base64"`
	}
	if json.Unmarshal(raw, &id) != nil || id.Seed == "" {
		t.Fatal("fixture identity")
	}
	for _, body := range [][]byte{w.Body.Bytes(), pairingHTTP(f.p, "GET", "/v2/local/pairing", nil).Body.Bytes()} {
		for _, secret := range []string{id.Seed, "seed_base64", "PRIVATE KEY", f.prepared.Proof, f.bundle.Receipt} {
			if bytes.Contains(body, []byte(secret)) {
				t.Fatal("private or historical material exposed")
			}
		}
	}
	after, _ := os.ReadFile(f.p.path)
	if !bytes.Equal(before, after) {
		t.Fatal("pairing changed cloud enrollment")
	}
}
func TestPairingExpiryAndBindingBoundaries(t *testing.T) {
	f, r, now := pairingFixture(t)
	for _, tt := range []struct {
		delta time.Duration
		code  int
	}{{time.Nanosecond, 200}, {305 * time.Second, 200}, {305*time.Second + time.Nanosecond, 400}, {0, 410}, {-time.Second, 410}} {
		r.Expires = now.Add(tt.delta).Format(time.RFC3339Nano)
		if _, code := f.p.authorizePairing(r, now); code != tt.code {
			t.Fatal("expiry boundary", tt.delta, code)
		}
	}
	r.Expires = now.Add(time.Minute).Format(time.RFC3339Nano)
	for _, field := range []string{"request", "server", "module", "nonce", "hash", "utc"} {
		bad := r
		switch field {
		case "request":
			bad.RequestID = "arbitrary bytes"
		case "server":
			bad.ServerID = uid()
		case "module":
			bad.ModuleID = uid()
		case "nonce":
			bad.Nonce = strings.Repeat("AB", 32)
		case "hash":
			bad.PollTokenHash = "bad"
		case "utc":
			bad.Expires = strings.TrimSuffix(r.Expires, "Z") + "+00:00"
		}
		out, code := f.p.authorizePairing(bad, now)
		expected := 400
		if field == "server" || field == "module" {
			expected = 409
		}
		if code != expected || out.(map[string]string)["error"] == "" {
			t.Fatal("bad binding accepted", field, code)
		}
	}
}
func TestPairingAvailabilityAndStatusFields(t *testing.T) {
	f, r, now := pairingFixture(t)
	f.p.status.Connected = true
	w := pairingHTTP(f.p, "GET", "/v2/local/pairing", nil)
	var status pairingStatus
	if w.Code != 200 || exact(w.Body.Bytes(), "module_id,public_key_base64,profile,configured,server_id,api_origin,media_origin,connected,certificate_expires_at", &status) != nil || !status.Configured || !status.Connected || status.Profile != "rm500u-embedded" || status.ServerID != r.ServerID || status.ModuleID != r.ModuleID || status.API != f.req.API || status.Media != f.req.Media || status.CertificateExpiry == nil {
		t.Fatal("status")
	}
	for _, state := range []string{"unconfigured", "invalid", "expired", "bad_certificate"} {
		t.Run(state, func(t *testing.T) {
			g := newFixture(t)
			checkTime := now
			want := 409
			switch state {
			case "invalid":
				g.p.status.LastError = "cloud_config"
				want = 503
			case "expired", "bad_certificate":
				g.prepare(t)
				g.issue(t)
				g.p.Activate(g.bundle)
				want = 410
				checkTime = now.Add(2 * time.Hour)
				if state == "bad_certificate" {
					g.p.config.Response.Public = "invalid"
					checkTime = now
					want = 503
				}
			}
			out, code := g.p.pairingView(checkTime)
			if state == "unconfigured" {
				s, ok := out.(pairingStatus)
				if code != 200 || !ok || s.Configured || s.Connected || s.ServerID != "" || s.API != "" || s.Media != "" || s.CertificateExpiry != nil {
					t.Fatal("unconfigured status")
				}
			} else if code != want || len(out.(map[string]string)) != 1 {
				t.Fatal("unavailable status", code)
			}
			request := r
			request.Expires = checkTime.Add(time.Minute).Format(time.RFC3339Nano)
			if _, code = g.p.authorizePairing(request, checkTime); code != want {
				t.Fatal("unavailable authorization", code)
			}
		})
	}
}
func TestPairingHTTPStrictInputAndMethods(t *testing.T) {
	f, r, _ := pairingFixture(t)
	b, _ := json.Marshal(r)
	var object map[string]any
	json.Unmarshal(b, &object)
	invalid := [][]byte{append(append([]byte{}, b...), []byte(` {}`)...), []byte(`{"message":"sign these bytes"}`), bytes.Replace(b, []byte(`"request_id":`), []byte(`"unknown":1,"request_id":`), 1), bytes.Replace(b, []byte(`"request_id":`), []byte(`"request_id":"duplicate","request_id":`), 1), []byte(strings.Repeat(" ", 16385))}
	for key := range object {
		for _, mode := range []string{"missing", "null", "type"} {
			var copy map[string]any
			json.Unmarshal(b, &copy)
			switch mode {
			case "missing":
				delete(copy, key)
			case "null":
				copy[key] = nil
			case "type":
				copy[key] = 17
			}
			raw, _ := json.Marshal(copy)
			invalid = append(invalid, raw)
		}
	}
	for _, bad := range invalid {
		w := pairingHTTP(f.p, "POST", "/v2/local/pairing/authorize", bad)
		if w.Code != 400 || w.Body.String() != "{\"error\":\"pairing_request_invalid\"}\n" {
			t.Fatal("strict request accepted or echoed", w.Code)
		}
	}
	for _, tt := range []struct {
		method, path string
		code         int
	}{{"POST", "/v2/local/pairing", 405}, {"GET", "/v2/local/pairing/authorize", 405}, {"POST", "/v2/local/pairing/authorize?nonce=x", 400}, {"GET", "/v2/local/pairing/unknown", 404}} {
		if w := pairingHTTP(f.p, tt.method, tt.path, b); w.Code != tt.code {
			t.Fatal("route boundary", w.Code)
		}
	}
	w := httptest.NewRecorder()
	request := httptest.NewRequest("POST", "/v2/local/pairing/authorize", bytes.NewReader(b))
	WithLocal(http.NotFoundHandler(), f.p, &Agent{}).ServeHTTP(w, request)
	if w.Code != 400 {
		t.Fatal("content type")
	}
}
