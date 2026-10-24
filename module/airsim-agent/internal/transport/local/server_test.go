package local

import (
	"airsim.local/airsim-agent/internal/state"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAllowlist(t *testing.T) {
	h := Handler(state.New("m", "b"), "v", "b")
	for _, tc := range []struct {
		method, path string
		status       int
	}{{"GET", "/healthz", 200}, {"GET", "/readyz", 503}, {"GET", "/v2/local/snapshot", 200}, {"GET", "/v2/local/capabilities", 200}, {"POST", "/healthz", 405}, {"HEAD", "/healthz", 405}, {"GET", "/api/at", 404}, {"GET", "/healthz/", 404}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.status {
			t.Fatalf("%s %s %d", tc.method, tc.path, w.Code)
		}
	}
}
func TestSocketShutdownAndLiveOwner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.sock")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, path, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})) }()
	deadline := time.Now().Add(time.Second)
	for {
		if i, e := os.Stat(path); e == nil && i.Mode().Perm() == 0600 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("not listening")
		}
		time.Sleep(time.Millisecond)
	}
	if e := Serve(context.Background(), path, http.NotFoundHandler()); e == nil {
		t.Fatal("stole socket")
	}
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown blocked")
	}
	if _, e := net.Dial("unix", path); e == nil {
		t.Fatal("socket survived")
	}
	if _, e := os.Stat(path); !os.IsNotExist(e) {
		t.Fatal("socket not removed")
	}
}

func TestRegularFileIsNeverRemoved(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control.sock")
	os.WriteFile(path, []byte("owned elsewhere"), 0600)
	if e := Serve(context.Background(), path, http.NotFoundHandler()); e == nil {
		t.Fatal("accepted regular file")
	}
	b, e := os.ReadFile(path)
	if e != nil || string(b) != "owned elsewhere" {
		t.Fatal("removed another file")
	}
}
