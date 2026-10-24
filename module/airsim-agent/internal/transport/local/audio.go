package local

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
)

func WithAudio(next http.Handler, m *media.Manager) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/v2/local/audio") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		switch r.URL.Path {
		case "/v2/local/audio":
			if r.Method != "GET" {
				w.WriteHeader(405)
				return
			}
			json.NewEncoder(w).Encode(m.View())
		case "/v2/local/audio/sessions":
			if r.Method != "POST" {
				w.WriteHeader(405)
				return
			}
			typ, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if e != nil || typ != "application/json" {
				w.WriteHeader(400)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 1024)
			b, e := io.ReadAll(r.Body)
			if e != nil {
				w.WriteHeader(400)
				return
			}
			request, e := media.ParseRequest(b)
			if e != nil {
				w.WriteHeader(400)
				return
			}
			result, status := m.Create(r.Context(), request)
			w.WriteHeader(status)
			if status == 200 || status == 201 {
				json.NewEncoder(w).Encode(result)
			}
		default:
			prefix := "/v2/local/audio/sessions/"
			if !strings.HasPrefix(r.URL.Path, prefix) || !control.ValidID(strings.TrimPrefix(r.URL.Path, prefix)) {
				w.WriteHeader(404)
				return
			}
			if r.Method != "DELETE" {
				w.WriteHeader(405)
				return
			}
			w.WriteHeader(m.Stop(strings.TrimPrefix(r.URL.Path, prefix)))
		}
	})
}
