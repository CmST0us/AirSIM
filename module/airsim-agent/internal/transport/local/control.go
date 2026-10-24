package local

import (
	"airsim.local/airsim-agent/internal/control"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"
)

func controlRoute(c *control.Coordinator, w http.ResponseWriter, r *http.Request) bool {
	path := r.URL.Path
	kind, id := "", ""
	switch path {
	case "/v2/local/control":
		kind = "control"
	case "/v2/local/calls":
		kind = "calls"
	case "/v2/local/messages":
		kind = "messages"
	case "/v2/local/commands":
		kind = "submit"
	default:
		if strings.HasPrefix(path, "/v2/local/commands/") {
			kind = "command"
			id = strings.TrimPrefix(path, "/v2/local/commands/")
			if !control.ValidID(id) {
				w.WriteHeader(404)
				return true
			}
		} else {
			return false
		}
	}
	method := "GET"
	if kind == "submit" {
		method = "POST"
	}
	if r.Method != method {
		w.WriteHeader(405)
		return true
	}
	var value any
	var status int
	if kind == "submit" {
		media, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if e != nil || media != "application/json" {
			w.WriteHeader(400)
			return true
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		data, e := io.ReadAll(r.Body)
		if e != nil {
			w.WriteHeader(400)
			return true
		}
		request, e := control.Parse(data)
		if e != nil {
			status = 400
			if errors.Is(e, control.ErrAction) {
				status = 404
			}
			w.WriteHeader(status)
			return true
		}
		value, status = c.Submit(r.Context(), request)
	} else {
		value, status = c.View(r.Context(), kind, id)
	}
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
	return true
}
