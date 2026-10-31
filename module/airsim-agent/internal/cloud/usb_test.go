package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/coder/websocket"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"airsim.local/airsim-agent/internal/control"
)

func usbFixture(t *testing.T) (*Agent, *USBAuthorization, string) {
	t.Helper()
	f := newFixture(t)
	a := &Agent{P: f.p, Control: &fakeControl{boot: uid(), epoch: uid(), call: uid(), commands: map[string]control.Request{}}, Media: &fakeMedia{}, owners: map[string]owner{}}
	dir := t.TempDir()
	if e := a.ConfigureUSB("192.168.225.1:8577", dir); e != nil {
		t.Fatal(e)
	}
	grant, e := a.USB.authorize(uid(), time.Now().Add(24*time.Hour).UTC().Format(time.RFC3339))
	if e != nil {
		t.Fatal(e)
	}
	return a, grant, dir
}
func signedUSB(t *testing.T, g *USBAuthorization, method, path string, body []byte, nonce string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(method, g.Origin+path, bytes.NewReader(body))
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	key, _ := hex.DecodeString(g.Token)
	h := hmac.New(sha256.New, key)
	h.Write([]byte(stamp + "\n" + nonce + "\n" + method + "\n" + path + "\n"))
	h.Write(body)
	r.Header.Set("Authorization", "Bearer "+g.Token)
	r.Header.Set("X-AirSIM-Timestamp", stamp)
	r.Header.Set("X-AirSIM-Nonce", nonce)
	r.Header.Set("X-AirSIM-Signature", hex.EncodeToString(h.Sum(nil)))
	return r
}
func TestUSBAuthenticationAndWhitelist(t *testing.T) {
	a, g, _ := usbFixture(t)
	nonce := strings.Repeat("a", 64)
	r := signedUSB(t, g, "GET", "/v2/modules", nil, nonce)
	w := httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "GET", "/v2/modules", nil, nonce))
	if w.Code != 401 {
		t.Fatal("replay", w.Code)
	}
	r = signedUSB(t, g, "POST", "/v2/local/cloud/activate", []byte("{}"), strings.Repeat("b", 64))
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 404 {
		t.Fatal("management route", w.Code)
	}
	r = signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("c", 64))
	r.Header.Set("X-AirSIM-Signature", strings.Repeat("0", 64))
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("signature", w.Code)
	}
	if e := a.USB.revoke(g.Client); e != nil {
		t.Fatal(e)
	}
	w = httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("d", 64)))
	if w.Code != 401 {
		t.Fatal("revoked", w.Code)
	}
}
func TestUSBGrantAndCommandMetadataSurviveRestart(t *testing.T) {
	a, g, dir := usbFixture(t)
	fc := a.Control.(*fakeControl)
	req := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Deadline: time.Now().Add(45 * time.Second).UTC().Format(time.RFC3339), Action: "sms.send", Args: control.Args{Number: "+15550000000", Text: "private-body"}}
	data, _ := json.Marshal(map[string]any{"connection_epoch": a.USB.epoch, "command": req})
	path := "/v2/modules/" + a.P.id.ModuleID + "/commands"
	w := httptest.NewRecorder()
	a.USB.ServeHTTP(w, signedUSB(t, g, "POST", path, data, strings.Repeat("e", 64)))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	disk, e := os.ReadFile(filepath.Join(dir, "usb-commands.json"))
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(disk, []byte(req.Args.Text)) || bytes.Contains(disk, []byte(req.Args.Number)) {
		t.Fatal("sensitive command persisted")
	}
	old := a.USB.records[req.CommandID]
	b := &Agent{P: a.P, Control: fc, Media: a.Media, owners: map[string]owner{}}
	if e = b.ConfigureUSB("192.168.225.1:8577", dir); e != nil {
		t.Fatal(e)
	}
	if b.USB.grants[g.Client].Token != g.Token || !bytes.Equal(a.USB.certificate.Certificate[0], b.USB.certificate.Certificate[0]) {
		t.Fatal("identity lost")
	}
	w = httptest.NewRecorder()
	b.USB.ServeHTTP(w, signedUSB(t, g, "GET", path+"/"+req.CommandID, nil, strings.Repeat("f", 64)))
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	var record struct {
		Generation string `json:"generation"`
	}
	if json.Unmarshal(w.Body.Bytes(), &record) != nil || record.Generation != old.Generation || fc.submitted.Load() != 1 {
		t.Fatal("result recovery")
	}
}

type endedControl struct{ *fakeControl }

func (e endedControl) View(ctx context.Context, kind, id string) (any, int) {
	if kind == "calls" {
		return control.CallsView{Boot: e.boot, Epoch: e.epoch, Calls: []control.Call{{ID: e.call, State: "disconnected"}}}, 200
	}
	return e.fakeControl.View(ctx, kind, id)
}
func TestUSBCloudOwnerAndShortCallRelease(t *testing.T) {
	a, g, _ := usbFixture(t)
	fc := a.Control.(*fakeControl)
	req := control.Request{CommandID: uid(), BootID: fc.boot, Epoch: fc.epoch, Action: "call.answer", Args: control.Args{CallID: fc.call}}
	if !a.reserveCommand(context.Background(), req, g.Client, "usb") {
		t.Fatal("reserve")
	}
	if a.reserveCommand(context.Background(), req, g.Client, "cloud") {
		t.Fatal("cloud stole USB call")
	}
	a.Control = endedControl{fc}
	next := req
	next.CommandID = uid()
	next.Action = "call.dial"
	next.Args = control.Args{Number: "+15550000000"}
	if !a.reserveCommand(context.Background(), next, g.Client, "usb") {
		t.Fatal("ended call retained")
	}
}
func TestUSBExpiryAndClientReplacement(t *testing.T) {
	a, g, _ := usbFixture(t)
	if _, e := a.USB.authorize(uid(), time.Now().Add(25*time.Hour).UTC().Format(time.RFC3339)); e == nil {
		t.Fatal("unbounded grant")
	}
	if _, e := a.USB.authorize(uid(), time.Now().Add(time.Hour).UTC().Format(time.RFC3339)); e != nil {
		t.Fatal(e)
	}
	if len(a.USB.grants) != 1 {
		t.Fatal("multiple owners")
	}
	r := signedUSB(t, g, "GET", "/v2/modules", nil, strings.Repeat("a", 64))
	if a.USB.client(r) != "" {
		t.Fatal("old client accepted")
	}
}
func TestUSBBodySignatureIncludesContent(t *testing.T) {
	a, g, _ := usbFixture(t)
	r := signedUSB(t, g, "POST", "/v2/modules", []byte("{}"), strings.Repeat("a", 64))
	r.Body = io.NopCloser(strings.NewReader("{\"changed\":true}"))
	if a.USB.client(r) != "" {
		t.Fatal("modified body accepted")
	}
}

func TestUSBMediaDuplexAndCleanup(t *testing.T) {
	a, g, dir := usbFixture(t)
	fc := a.Control.(*fakeControl)
	fm := a.Media.(*fakeMedia)
	fm.socket = filepath.Join(dir, "media.sock")
	fm.id = uid()
	fm.token = strings.Repeat("a", 64)
	listener, e := net.Listen("unix", fm.socket)
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	finished := make(chan struct{})
	defer close(finished)
	up := make(chan bool, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		if _, e = media.ReadJSON(conn, 1024); e != nil {
			return
		}
		_ = media.WriteJSON(conn, map[string]any{"ok": true, "codec": "lc3", "codec_frame_us": 10000, "codec_frame_bytes": 40, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}, 1024)
		down := media.NewFrame(fm.id, 2, 1)
		down[40] = 77
		if writeFrame(conn, down[:]) != nil {
			return
		}
		var seq uint64
		frame, _, e := media.ReadFrame(conn, fm.id, 1, &seq)
		up <- e == nil && frame[40] == 42
		<-finished
	}()
	generation := uid()
	a.owners[fc.call] = owner{fc.call, g.Client, generation, fc.boot, fc.epoch}
	a.claim = &callClaim{client: g.Client, route: "usb", call: fc.call, boot: fc.boot, epoch: fc.epoch}
	data, _ := json.Marshal(map[string]string{"codec": "lc3", "request_id": uid(), "connection_epoch": a.USB.epoch, "generation": generation})
	path := "/v2/modules/" + a.P.id.ModuleID + "/calls/" + fc.call + "/media-sessions"
	recorder := httptest.NewRecorder()
	a.USB.ServeHTTP(recorder, signedUSB(t, g, "POST", path, data, strings.Repeat("a", 64)))
	if recorder.Code != 201 {
		t.Fatal(recorder.Code)
	}
	var created struct {
		ID     string `json:"session_id"`
		Ticket string `json:"ticket"`
	}
	if json.Unmarshal(recorder.Body.Bytes(), &created) != nil {
		t.Fatal("media result")
	}
	server := httptest.NewServer(a.USB)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ws, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v2/media", &websocket.DialOptions{Subprotocols: []string{"airsim.media.v2"}})
	if e != nil {
		t.Fatal(e)
	}
	defer ws.CloseNow()
	auth, _ := json.Marshal(map[string]string{"session_id": created.ID, "role": "client", "ticket": created.Ticket})
	if e = ws.Write(ctx, websocket.MessageText, auth); e != nil {
		t.Fatal(e)
	}
	for _, expected := range []string{"waiting", "paired"} {
		typ, b, e := ws.Read(ctx)
		phase, ok := paired(b, created.ID)
		if e != nil || typ != websocket.MessageText || !ok || phase != expected {
			t.Fatal("handshake", expected, e)
		}
	}
	frame := media.NewFrame(created.ID, 1, 1)
	frame[40] = 42
	if e = ws.Write(ctx, websocket.MessageBinary, frame[:]); e != nil {
		t.Fatal(e)
	}
	typ, b, e := ws.Read(ctx)
	if e != nil || typ != websocket.MessageBinary || len(b) != media.FrameSize || b[40] != 77 {
		t.Fatal("downlink", e)
	}
	select {
	case ok := <-up:
		if !ok {
			t.Fatal("uplink")
		}
	case <-ctx.Done():
		t.Fatal("uplink timeout")
	}
	ws.CloseNow()
	deadline := time.Now().Add(time.Second)
	for fm.stops.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if fm.stops.Load() != 1 {
		t.Fatal("media not released")
	}
}
