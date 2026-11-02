package local

import (
	"encoding/json"
	"net/http"
)

// WithSMSDiagnostics is installed only on the protected local Unix socket.
// It is not a cloud command or a USB HTTPS business API.
func WithSMSDiagnostics(next http.Handler, view func() any) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v2/local/diagnostics/sms" || view == nil {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != "GET" {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		_ = json.NewEncoder(w).Encode(view())
	})
}
