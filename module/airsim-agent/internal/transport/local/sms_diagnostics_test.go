package local

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSMSDiagnosticsOnlyFixedLocalGet(t *testing.T) {
	calls := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(404) })
	h := WithSMSDiagnostics(next, func() any { calls++; return map[string]int{"schema_version": 1} })
	for _, tc := range []struct {
		method, path string
		status       int
	}{{"GET", "/v2/local/diagnostics/sms", 200}, {"POST", "/v2/local/diagnostics/sms", 405}, {"DELETE", "/v2/local/diagnostics/sms", 405}, {"GET", "/v2/local/diagnostics/sms/AT+CMGD", 404}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.status {
			t.Fatal(w.Code)
		}
		if w.Code == 200 && w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("missing cache protection")
		}
	}
	if calls != 1 {
		t.Fatal("write or arbitrary path invoked provider")
	}
	w := httptest.NewRecorder()
	WithSMSDiagnostics(next, nil).ServeHTTP(w, httptest.NewRequest("GET", "/v2/local/diagnostics/sms", nil))
	if w.Code != 404 {
		t.Fatal("unsupported platform exposed diagnostic")
	}
}
