package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/coder/websocket"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const endpoint = "wss://airsim.eric3u.cc/v2/media"

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type config struct {
	URL            string `json:"url"`
	Session        string `json:"session_id"`
	Ticket         string `json:"ticket"`
	Seconds        int    `json:"seconds"`
	SendIntervalMS int    `json:"send_interval_ms,omitempty"`
}
type result struct {
	TCP                  []tcpSample `json:"tcp_samples,omitempty"`
	Sent                 uint64      `json:"sent_frames"`
	Received             uint64      `json:"received_frames"`
	Gaps                 uint64      `json:"gaps"`
	ElapsedMS            int64       `json:"elapsed_ms"`
	MaxReceiveIntervalMS int64       `json:"max_receive_interval_ms"`
	Reason               string      `json:"reason"`
}

func exact(b []byte, keys []string, v any) error { return exactOptional(b, keys, nil, v) }
func exactOptional(b []byte, keys, optional []string, v any) error {
	if !utf8.Valid(b) {
		return errors.New("invalid")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return errors.New("invalid")
	}
	allowed := map[string]bool{}
	for _, k := range keys {
		allowed[k] = true
	}
	for _, k := range optional {
		allowed[k] = true
	}
	seen := map[string]bool{}
	for d.More() {
		t, e = d.Token()
		if e != nil {
			return errors.New("invalid")
		}
		k, ok := t.(string)
		if !ok || !allowed[k] || seen[k] {
			return errors.New("invalid")
		}
		seen[k] = true
		var value json.RawMessage
		if d.Decode(&value) != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return errors.New("invalid")
		}
	}
	if _, e = d.Token(); e != nil {
		return errors.New("invalid")
	}
	for _, k := range keys {
		if !seen[k] {
			return errors.New("invalid")
		}
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("invalid")
	}
	return json.Unmarshal(b, v)
}
func parseConfig(b []byte) (config, error) {
	c := config{SendIntervalMS: 20}
	if len(b) > 4096 || exactOptional(b, []string{"url", "session_id", "ticket", "seconds"}, []string{"send_interval_ms"}, &c) != nil || c.URL != endpoint || !uuidPattern.MatchString(c.Session) || c.Seconds != 20 || (c.SendIntervalMS != 20 && c.SendIntervalMS != 200) {
		return c, errors.New("config")
	}
	ticket, e := hex.DecodeString(c.Ticket)
	if e != nil || len(ticket) != 32 || hex.EncodeToString(ticket) != c.Ticket {
		return c, errors.New("config")
	}
	return c, nil
}
func load(path string) (config, error) {
	var c config
	f, e := os.Open(path)
	if e != nil {
		return c, errors.New("config")
	}
	defer f.Close()
	l, e := os.Lstat(path)
	if e != nil || !l.Mode().IsRegular() || l.Mode().Perm() != 0600 || l.Size() > 4096 {
		return c, errors.New("config")
	}
	st, e := f.Stat()
	if e != nil || !os.SameFile(l, st) {
		return c, errors.New("config")
	}
	b, e := io.ReadAll(io.LimitReader(f, 4097))
	if e != nil {
		return c, errors.New("config")
	}
	return parseConfig(b)
}
func sessionBytes(id string) [16]byte {
	b, _ := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	var s [16]byte
	copy(s[:], b)
	return s
}
func frame(id [16]byte, direction byte, sequence uint64) [120]byte {
	var f [120]byte
	copy(f[:4], "ASMP")
	f[4] = 2
	f[5] = direction
	binary.LittleEndian.PutUint16(f[6:8], 40)
	copy(f[8:24], id[:])
	binary.LittleEndian.PutUint64(f[24:32], sequence)
	binary.LittleEndian.PutUint32(f[32:36], 80)
	binary.LittleEndian.PutUint32(f[36:40], 1) // Network probe carries erasures, never encoded audio.
	return f
}
func check(b []byte, id [16]byte, last uint64) (uint64, uint64, bool) {
	if len(b) != 120 || string(b[:4]) != "ASMP" || b[4] != 2 || b[5] != 1 || binary.LittleEndian.Uint16(b[6:8]) != 40 || !bytes.Equal(b[8:24], id[:]) || binary.LittleEndian.Uint32(b[32:36]) != 80 || binary.LittleEndian.Uint32(b[36:40]) > 1 {
		return 0, 0, false
	}
	if b[36] == 1 {
		for _, value := range b[40:] {
			if value != 0 {
				return 0, 0, false
			}
		}
	}
	seq := binary.LittleEndian.Uint64(b[24:32])
	if seq == 0 || seq <= last {
		return 0, 0, false
	}
	return seq, seq - last - 1, true
}
func pairing(b []byte, id string) (string, bool) {
	var tag struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(b, &tag) != nil {
		return "", false
	}
	if tag.Type == "waiting" {
		var v struct {
			Type string `json:"type"`
			ID   string `json:"session_id"`
		}
		return tag.Type, exact(b, []string{"type", "session_id"}, &v) == nil && v.ID == id
	}
	var v struct {
		Type   string          `json:"type"`
		ID     string          `json:"session_id"`
		Format json.RawMessage `json:"format"`
	}
	if tag.Type != "paired" || exact(b, []string{"type", "session_id", "format"}, &v) != nil || v.ID != id {
		return "", false
	}
	var f struct {
		Codec           string `json:"codec"`
		CodecFrameUS    int    `json:"codec_frame_us"`
		CodecFrameBytes int    `json:"codec_frame_bytes"`
		Rate            int    `json:"sample_rate"`
		Channels        int    `json:"channels"`
		Format          string `json:"sample_format"`
		Frames          int    `json:"frame_samples"`
	}
	return tag.Type, exact(v.Format, []string{"codec", "codec_frame_us", "codec_frame_bytes", "sample_rate", "channels", "sample_format", "frame_samples"}, &f) == nil && f.Codec == "lc3" && f.CodecFrameUS == 10000 && f.CodecFrameBytes == 40 && f.Rate == 16000 && f.Channels == 1 && f.Format == "s16le" && f.Frames == 320
}
func client() *http.Client {
	return &http.Client{Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, ForceAttemptHTTP2: false}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect") }}
}
func run(parent context.Context, c config, h *http.Client) result {
	out := result{Reason: "connect"}
	connectStarted := time.Now()
	handshake, hcancel := context.WithTimeout(parent, 20*time.Second)
	defer hcancel()
	ws, resp, e := websocket.Dial(handshake, c.URL, &websocket.DialOptions{HTTPClient: h, Subprotocols: []string{"airsim.media.v2"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		out.ElapsedMS = time.Since(connectStarted).Milliseconds()
		var cert *tls.CertificateVerificationError
		var unknown x509.UnknownAuthorityError
		var invalid x509.CertificateInvalidError
		var hostname x509.HostnameError
		var network net.Error
		switch {
		case errors.As(e, &cert), errors.As(e, &unknown), errors.As(e, &invalid), errors.As(e, &hostname):
			out.Reason = "connect_tls_verification"
		case errors.Is(e, context.DeadlineExceeded):
			out.Reason = "connect_timeout"
		case errors.As(e, &network):
			if network.Timeout() {
				out.Reason = "connect_timeout"
			} else {
				out.Reason = "connect_network"
			}
		case resp != nil:
			out.Reason = "connect_http"
		}
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		return out
	}
	defer ws.CloseNow()
	ws.SetReadLimit(2048)
	if ws.Subprotocol() != "airsim.media.v2" {
		out.Reason = "subprotocol"
		return out
	}
	auth, _ := json.Marshal(map[string]string{"session_id": c.Session, "role": "agent", "ticket": c.Ticket})
	authctx, acancel := context.WithTimeout(handshake, 3*time.Second)
	e = ws.Write(authctx, websocket.MessageText, auth)
	if e != nil {
		acancel()
		out.Reason = "authentication_write"
		return out
	}
	acancel()
	readAuth, readAuthCancel := context.WithTimeout(handshake, 3*time.Second)
	typ, b, e := ws.Read(readAuth)
	readAuthCancel()
	if e != nil || typ != websocket.MessageText {
		out.Reason = "authentication_read"
		return out
	}
	phase, ok := pairing(b, c.Session)
	if !ok {
		out.Reason = "pairing_protocol"
		return out
	}
	if phase == "waiting" {
		pairctx, pcancel := context.WithCancel(handshake)
		typ, b, e = ws.Read(pairctx)
		pcancel()
		phase, ok = pairing(b, c.Session)
		if e != nil || typ != websocket.MessageText || !ok || phase != "paired" {
			out.Reason = "pairing"
			return out
		}
	}
	started := time.Now()
	ctx, cancel := context.WithTimeout(parent, time.Duration(c.Seconds)*time.Second)
	defer cancel()
	closeOnCancel := context.AfterFunc(ctx, func() { ws.CloseNow() })
	defer closeOnCancel()
	sid := sessionBytes(c.Session)
	var sent, received, gaps atomic.Uint64
	var maxInterval atomic.Int64
	var readTimedOut atomic.Bool
	failures := make(chan string, 1)
	fail := func(reason string) {
		select {
		case failures <- reason:
		default:
		}
		cancel()
	}
	var wg sync.WaitGroup
	wg.Add(2)
	// No application queue: each direction has one working frame (less than five).
	go func() {
		defer wg.Done()
		tick := time.NewTicker(time.Duration(c.SendIntervalMS) * time.Millisecond)
		defer tick.Stop()
		var seq uint64
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				seq++
				f := frame(sid, 2, seq)
				wctx, wcancel := context.WithTimeout(ctx, 100*time.Millisecond)
				err := ws.Write(wctx, websocket.MessageBinary, f[:])
				wcancel()
				if err != nil {
					if ctx.Err() == nil {
						fail("write")
					}
					return
				}
				sent.Add(1)
			}
		}
	}()
	go func() {
		defer wg.Done()
		var last uint64
		previous := started
		for {
			rctx, rcancel := context.WithTimeout(ctx, 2*time.Second)
			typ, b, e := ws.Read(rctx)
			timedOut := rctx.Err() == context.DeadlineExceeded
			if timedOut && parent.Err() == nil && time.Since(started) < time.Duration(c.Seconds)*time.Second {
				readTimedOut.Store(true)
			}
			rcancel()
			if e != nil {
				if ctx.Err() == nil {
					if timedOut {
						fail("read_timeout")
					} else {
						fail("read")
					}
				}
				return
			}
			if typ != websocket.MessageBinary {
				fail("frame_type")
				return
			}
			seq, gap, valid := check(b, sid, last)
			if !valid {
				fail("frame_invalid")
				return
			}
			last = seq
			gaps.Add(gap)
			received.Add(1)
			now := time.Now()
			interval := now.Sub(previous).Milliseconds()
			previous = now
			if interval > maxInterval.Load() {
				maxInterval.Store(interval)
			}
		}
	}()
	<-ctx.Done()
	ws.CloseNow()
	wg.Wait()
	out.Sent = sent.Load()
	out.Received = received.Load()
	out.Gaps = gaps.Load()
	out.MaxReceiveIntervalMS = maxInterval.Load()
	out.ElapsedMS = time.Since(started).Milliseconds()
	out.Reason = "completed"
	select {
	case out.Reason = <-failures:
	default:
		if parent.Err() != nil {
			out.Reason = "overall_timeout"
		}
	}
	if readTimedOut.Load() {
		out.Reason = "read_timeout"
	}
	return out
}
func main() {
	var output sync.Once
	emit := func(r result) { output.Do(func() { _ = json.NewEncoder(os.Stdout).Encode(r) }) }
	// Process-wide watchdog also bounds blocking stdout/cleanup/library calls.
	watchdog := time.AfterFunc(45*time.Second, func() { os.Exit(1) })
	defer watchdog.Stop()
	if len(os.Args) != 2 {
		emit(result{Reason: "config"})
		return
	}
	c, e := load(os.Args[1])
	if e != nil {
		emit(result{Reason: "config"})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 44900*time.Millisecond)
	defer cancel()
	h := client()
	tracker := &tcpTracker{}
	h.Transport.(*http.Transport).DialContext = tracker.dial
	stop := tracker.collect(ctx)
	defer h.CloseIdleConnections()
	r := run(ctx, c, h)
	r.TCP = stop()
	emit(r)
}
