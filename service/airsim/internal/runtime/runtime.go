package runtime

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func Context() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
}
func Serve(ctx context.Context, h http.Handler) error {
	srv := &http.Server{Addr: Env("LISTEN_ADDR", ":8080"), Handler: h, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 20 * time.Second, MaxHeaderBytes: 16384, ErrorLog: log.New(io.Discard, "", 0)}
	go func() {
		<-ctx.Done()
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(stop)
	}()
	e := srv.ListenAndServe()
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return errors.New("server_failed")
}
func Env(k, d string) string {
	v := os.Getenv(k)
	if v == "" {
		return d
	}
	return v
}
func Health() bool {
	if len(os.Args) != 2 || os.Args[1] != "healthcheck" {
		return false
	}
	c := http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{Proxy: nil}}
	url := "http://127.0.0.1" + strings.Replace(Env("LISTEN_ADDR", ":8080"), "127.0.0.1", "", 1) + "/readyz"
	r, e := c.Get(url)
	if e != nil {
		os.Exit(1)
	}
	r.Body.Close()
	if r.StatusCode != 200 {
		os.Exit(1)
	}
	os.Exit(0)
	return true
}
func Exit(e error) {
	if e != nil {
		_, _ = os.Stderr.WriteString("operation_failed\n")
		os.Exit(1)
	}
}
