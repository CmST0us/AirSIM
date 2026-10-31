package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/coder/websocket"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const fixtureID = "11111111-1111-4111-8111-111111111111"

func goodConfig() config { return config{endpoint, fixtureID, strings.Repeat("ab", 32), 20, 20} }
func TestConfigAndFrames(t *testing.T) {
	c := goodConfig()
	b, _ := json.Marshal(c)
	if _, e := parseConfig(b); e != nil {
		t.Fatal(e)
	}
	for _, value := range []config{{"ws://airsim.eric3u.cc/v2/media", c.Session, c.Ticket, 20, 20}, {endpoint + "?ticket=x", c.Session, c.Ticket, 20, 20}, {endpoint, c.Session, c.Ticket, 19, 20}, {endpoint, "bad", c.Ticket, 20, 20}, {endpoint, c.Session, strings.Repeat("AB", 32), 20, 20}} {
		bad, _ := json.Marshal(value)
		if _, e := parseConfig(bad); e == nil {
			t.Fatal("config accepted")
		}
	}
	duplicate := bytes.Replace(b, []byte(`"seconds":20`), []byte(`"seconds":20,"seconds":20`), 1)
	if _, e := parseConfig(duplicate); e == nil {
		t.Fatal("duplicate")
	}
	if _, e := parseConfig(append(b, []byte(` {}`)...)); e == nil {
		t.Fatal("trailing")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, b, 0600)
	if _, e := load(path); e != nil {
		t.Fatal("private config")
	}
	os.Chmod(path, 0644)
	if _, e := load(path); e == nil {
		t.Fatal("permissions")
	}
	os.Chmod(path, 0600)
	link := path + ".link"
	os.Symlink(path, link)
	if _, e := load(link); e == nil {
		t.Fatal("symlink")
	}
	id := sessionBytes(c.Session)
	f := frame(id, 1, 3)
	seq, gap, ok := check(f[:], id, 0)
	if !ok || seq != 3 || gap != 2 {
		t.Fatal("gap")
	}
	if _, _, ok := check(f[:], id, 3); ok {
		t.Fatal("duplicate seq")
	}
	f[5] = 2
	if _, _, ok := check(f[:], id, 0); ok {
		t.Fatal("direction")
	}
	f[5] = 1
	f[8] ^= 1
	if _, _, ok := check(f[:], id, 0); ok {
		t.Fatal("session")
	}
	h := client()
	defer h.CloseIdleConnections()
	tr := h.Transport.(*http.Transport)
	if tr.Proxy != nil || tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.RootCAs != nil || h.CheckRedirect(nil, nil) == nil {
		t.Fatal("production TLS settings")
	}
}
func TestTLSFixtureTwentySeconds(t *testing.T) {
	for _, interval := range []int{20, 200} {
		t.Run(fmt.Sprint(interval), func(t *testing.T) { testTLSCadence(t, interval) })
	}
}
func testTLSCadence(t *testing.T, interval int) {
	c := goodConfig()
	c.SendIntervalMS = interval
	id := sessionBytes(c.Session)
	var frames atomic.Uint64
	var malformed atomic.Bool
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}, CompressionMode: websocket.CompressionDisabled})
		if e != nil {
			return
		}
		defer ws.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
		defer cancel()
		typ, b, e := ws.Read(ctx)
		if e != nil || typ != websocket.MessageText {
			return
		}
		var auth struct {
			ID     string `json:"session_id"`
			Role   string `json:"role"`
			Ticket string `json:"ticket"`
		}
		if exact(b, []string{"session_id", "role", "ticket"}, &auth) != nil || auth.ID != c.Session || auth.Role != "agent" || auth.Ticket != c.Ticket {
			malformed.Store(true)
			return
		}
		waiting, _ := json.Marshal(map[string]string{"type": "waiting", "session_id": c.Session})
		ws.Write(ctx, websocket.MessageText, waiting)
		paired, _ := json.Marshal(map[string]any{"type": "paired", "session_id": c.Session, "format": map[string]any{"codec": "lc3", "codec_frame_us": 10000, "codec_frame_bytes": 40, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}})
		ws.Write(ctx, websocket.MessageText, paired)
		var inseq, outseq uint64
		for {
			typ, b, e = ws.Read(ctx)
			if e != nil {
				return
			}
			if typ != websocket.MessageBinary || len(b) != 120 || b[5] != 2 {
				malformed.Store(true)
				return
			}
			for _, v := range b[40:] {
				if v != 0 {
					malformed.Store(true)
					return
				}
			}
			b[5] = 1
			next, gap, ok := check(b, id, inseq)
			if !ok || gap != 0 {
				malformed.Store(true)
				return
			}
			inseq = next
			frames.Add(1)
			outseq++
			if outseq == 20 {
				outseq++
			}
			out := frame(id, 1, outseq)
			if ws.Write(ctx, websocket.MessageBinary, out[:]) != nil {
				return
			}
		}
	}))
	defer s.Close()
	c.URL = "wss" + strings.TrimPrefix(s.URL, "https")
	h := s.Client()
	h.CheckRedirect = func(*http.Request, []*http.Request) error { return os.ErrPermission }
	h.Transport.(*http.Transport).Proxy = nil
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	r := run(ctx, c, h)
	if r.Reason != "completed" || r.Sent < uint64(19400/interval) || r.Sent > uint64(20000/interval) || r.Received < uint64(19400/interval) || r.Received > r.Sent || r.Gaps != 1 || r.ElapsedMS < 19900 || r.ElapsedMS > 20500 || malformed.Load() {
		t.Fatalf("fixture summary %+v malformed=%v", r, malformed.Load())
	}
	t.Logf("fixture sent=%d received=%d gaps=%d elapsed_ms=%d max_interval_ms=%d", r.Sent, r.Received, r.Gaps, r.ElapsedMS, r.MaxReceiveIntervalMS)
}
func TestPairingStrict(t *testing.T) {
	for _, b := range []string{`{"type":"waiting","session_id":null}`, `{"type":"waiting","session_id":"wrong"}`, `{"type":"waiting","session_id":"11111111-1111-4111-8111-111111111111","extra":1}`} {
		if _, ok := pairing([]byte(b), fixtureID); ok {
			t.Fatal("pairing accepted")
		}
	}
}

func TestTLSFixtureReadTimeout(t *testing.T) {
	c := goodConfig()
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"airsim.media.v2"}})
		if e != nil {
			return
		}
		defer ws.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if _, _, e = ws.Read(ctx); e != nil {
			return
		}
		b, _ := json.Marshal(map[string]any{"type": "paired", "session_id": c.Session, "format": map[string]any{"codec": "lc3", "codec_frame_us": 10000, "codec_frame_bytes": 40, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}})
		if ws.Write(ctx, websocket.MessageText, b) != nil {
			return
		}
		for {
			if _, _, e = ws.Read(ctx); e != nil {
				return
			}
		} // consume uplink but send no direction1 frames
	}))
	defer s.Close()
	c.URL = "wss" + strings.TrimPrefix(s.URL, "https")
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	r := run(ctx, c, s.Client())
	if r.Reason != "read_timeout" || r.Received != 0 || r.ElapsedMS < 1900 || r.ElapsedMS > 2500 {
		t.Fatalf("timeout summary %+v", r)
	}
}

func TestIntervalConfig(t *testing.T) {
	b, _ := json.Marshal(goodConfig())
	for _, value := range []string{"20", "200", "0", "-20", "21", "201", "null", "20.1", `"20"`} {
		candidate := bytes.Replace(b, []byte(`"send_interval_ms":20`), []byte(`"send_interval_ms":`+value), 1)
		c, e := parseConfig(candidate)
		valid := value == "20" || value == "200"
		if (e == nil) != valid {
			t.Fatalf("interval %s accepted=%v", value, e == nil)
		}
		if valid && c.SendIntervalMS != map[string]int{"20": 20, "200": 200}[value] {
			t.Fatal("interval lost")
		}
	}
	absent := bytes.Replace(b, []byte(`,"send_interval_ms":20`), nil, 1)
	if c, e := parseConfig(absent); e != nil || c.SendIntervalMS != 20 {
		t.Fatal("default")
	}
	duplicate := bytes.Replace(b, []byte(`"send_interval_ms":20`), []byte(`"send_interval_ms":20,"send_interval_ms":200`), 1)
	if _, e := parseConfig(duplicate); e == nil {
		t.Fatal("duplicate interval")
	}
}

func TestConnectTLSFailureIsSanitized(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	h := client()
	defer h.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := run(ctx, config{URL: "wss" + strings.TrimPrefix(server.URL, "https"), Seconds: 20}, h)
	if result.Reason != "connect_tls_verification" || result.Sent != 0 || result.Received != 0 {
		t.Fatalf("connection classification: %+v", result)
	}
}
