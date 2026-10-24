package local

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/journal"
	"airsim.local/airsim-agent/internal/state"
	"context"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlHTTPValidation(t *testing.T) {
	store, e := journal.Open(filepath.Join(t.TempDir(), "state"))
	if e != nil {
		t.Fatal(e)
	}
	c := control.New("boot", func([]byte) string { return "" }, func() bool { return false }, store, nil)
	ctx, cancel := context.WithCancel(context.Background())
	go c.Run(ctx)
	defer func() { cancel(); <-c.Done() }()
	h := Handler(state.New("module", "boot"), "r2", "boot", c)
	for _, tc := range []struct {
		method, path, body, content string
		code                        int
	}{{"GET", "/v2/local/control", "", "", 200}, {"POST", "/v2/local/calls", "", "", 405}, {"GET", "/v2/local/commands", "", "", 405}, {"GET", "/v2/local/commands/not-a-uuid", "", "", 404}, {"POST", "/v2/local/commands", "{}", "text/plain", 400}, {"POST", "/v2/local/commands", strings.Repeat(" ", 4097), "application/json", 400}, {"POST", "/v2/local/commands", "{}", "application/json", 400}, {"GET", "/v2/local/capabilities", "", "", 200}} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		r.Header.Set("Content-Type", tc.content)
		h.ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s %s: %d", tc.method, tc.path, w.Code)
		}
		if tc.path == "/v2/local/capabilities" && !strings.Contains(w.Body.String(), `"messaging":{"support":"supported","readiness":"unavailable"`) {
			t.Fatal("messaging capability")
		}
	}
}
