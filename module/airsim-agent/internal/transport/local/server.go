package local

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/state"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"syscall"
	"time"
)

func Handler(s *state.Store, version, boot string, controllers ...*control.Coordinator) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if len(controllers) > 0 && controlRoute(controllers[0], w, r) {
			return
		}
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		var v any
		switch r.URL.Path {
		case "/healthz":
			v = struct {
				Status  string `json:"status"`
				Version string `json:"version"`
				Boot    string `json:"agent_boot_id"`
			}{"ok", version, boot}
		case "/readyz":
			_, ready := s.View(time.Now())
			v = ready
			if !ready.Ready {
				w.WriteHeader(503)
			}
		case "/v2/local/snapshot":
			v, _ = s.View(time.Now())
		case "/v2/local/capabilities":
			caps := s.Capabilities(time.Now())
			if len(controllers) > 0 {
				value, code := controllers[0].View(r.Context(), "control", "")
				cap := hal.Capability{Support: "supported", Readiness: "unavailable", Reason: "backend_unavailable"}
				if status, ok := value.(control.Status); ok && code == 200 {
					cap.Reason = status.Reason
					if status.Messaging {
						cap.Readiness = "ready"
					}
				}
				caps.Capabilities["messaging"] = cap
			}
			v = caps
		default:
			w.WriteHeader(404)
			return
		}
		_ = json.NewEncoder(w).Encode(v)
	})
}

// Serve is called only while the instance lock is held. A live socket is never removed.
func Serve(ctx context.Context, path string, handler http.Handler) error {
	if info, e := os.Lstat(path); e == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("socket_conflict")
		}
		c, e := net.DialTimeout("unix", path, 200*time.Millisecond)
		if e == nil {
			c.Close()
			return errors.New("socket_conflict")
		}
		if !errors.Is(e, syscall.ECONNREFUSED) {
			return errors.New("socket_conflict")
		}
		current, statErr := os.Lstat(path)
		if statErr != nil || !os.SameFile(info, current) {
			return errors.New("socket_conflict")
		}
		if e = os.Remove(path); e != nil {
			return e
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	l, e := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if e != nil {
		return e
	}
	l.SetUnlinkOnClose(false)
	owned, e := os.Lstat(path)
	if e != nil {
		l.Close()
		return e
	}
	defer func() {
		l.Close()
		current, e := os.Lstat(path)
		if e == nil && os.SameFile(owned, current) {
			_ = os.Remove(path)
		}
	}()
	if e = os.Chmod(path, 0600); e != nil {
		return e
	}
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	stopped := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			_ = server.Shutdown(shutdown)
		case <-stopped:
		}
	}()
	defer close(stopped)
	e = server.Serve(l)
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return e
}
