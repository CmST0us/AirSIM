package local

import (
	"airsim.local/airsim-agent/internal/media"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAudioRoutesStrictWithoutHelper(t *testing.T) {
	m := media.New(nil, "", "/unused/media.sock")
	h := WithAudio(http.NotFoundHandler(), m)
	for _, tc := range []struct {
		method, path, body, content string
		code                        int
	}{{"GET", "/v2/local/audio", "", "", 200}, {"POST", "/v2/local/audio", "", "", 405}, {"GET", "/v2/local/audio/sessions", "", "", 405}, {"POST", "/v2/local/audio/sessions", "{}", "text/plain", 400}, {"POST", "/v2/local/audio/sessions", strings.Repeat(" ", 1025), "application/json", 400}, {"POST", "/v2/local/audio/sessions", "{}", "application/json", 400}, {"DELETE", "/v2/local/audio/sessions/not-a-uuid", "", "", 404}, {"GET", "/v2/local/audio/unknown", "", "", 404}} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		r.Header.Set("Content-Type", tc.content)
		h.ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s %s: %d", tc.method, tc.path, w.Code)
		}
		if tc.path == "/v2/local/audio" && tc.method == "GET" {
			for _, s := range []string{`"implementation":"implemented"`, `"verification":"unverified"`, `"voice_ready":false`, `"available":false`} {
				if !strings.Contains(w.Body.String(), s) {
					t.Fatal(w.Body.String())
				}
			}
		}
	}
}
