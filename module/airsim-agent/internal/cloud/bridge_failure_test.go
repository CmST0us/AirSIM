package cloud

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestBridgePreservesFirstFailureDuringCleanup(t *testing.T) {
	for _, kind := range []string{"cloud_invalid_frame", "cloud_remote_closed", "local_read_closed", "media_cancelled"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				peer, e := websocket.Accept(w, r, nil)
				if e != nil {
					return
				}
				defer peer.CloseNow()
				switch kind {
				case "cloud_invalid_frame":
					peer.Write(ctx, websocket.MessageBinary, []byte("invalid"))
				case "cloud_remote_closed":
					peer.Close(websocket.StatusNormalClosure, "")
				}
				<-ctx.Done()
			}))
			defer server.Close()
			ws, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if e != nil {
				t.Fatal(e)
			}
			defer ws.CloseNow()
			local, peer := net.Pipe()
			defer local.Close()
			defer peer.Close()
			if kind == "local_read_closed" {
				peer.Close()
			}
			if kind == "media_cancelled" {
				cancel()
			}
			reason := bridgeFrames(ctx, cancel, ws, local, uid(), uid(), &bridgeCounters{})
			if reason != kind {
				t.Fatalf("got %s want %s", reason, kind)
			}
		})
	}
}

func TestMediaConnectFailureCategories(t *testing.T) {
	for _, tc := range []struct {
		name     string
		response *http.Response
		err      error
		want     string
	}{
		{"dns", nil, &net.DNSError{IsNotFound: true}, "media_connect_dns"},
		{"timeout", nil, context.DeadlineExceeded, "media_connect_timeout"},
		{"cancelled", nil, context.Canceled, "media_cancelled"},
		{"http", &http.Response{StatusCode: 503}, errors.New("upgrade failed"), "media_connect_http"},
		{"refused", nil, &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED}, "media_connect_refused"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := mediaConnectReason(tc.err, tc.response); got != tc.want {
				t.Fatalf("got %s want %s", got, tc.want)
			}
		})
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	ws, resp, err := websocket.Dial(ctx, "wss"+strings.TrimPrefix(server.URL, "https"), nil)
	if ws != nil {
		ws.CloseNow()
		t.Fatal("untrusted certificate accepted")
	}
	if got := mediaConnectReason(err, resp); got != "media_connect_tls" {
		t.Fatal(got)
	}
}

func TestMediaConnectStageTimeoutPreservesCause(t *testing.T) {
	for _, stage := range []string{"tcp", "tls"} {
		err := &mediaDialStageError{stage: stage, err: &net.OpError{Op: "dial", Net: "tcp", Err: context.DeadlineExceeded}}
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("timeout cause lost")
		}
		want := "media_connect_" + stage + "_timeout"
		if got := mediaConnectReason(err, nil); got != want {
			t.Fatalf("got %s want %s", got, want)
		}
	}
}
