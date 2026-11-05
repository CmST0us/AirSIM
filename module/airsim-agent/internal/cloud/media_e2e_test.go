package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/rtp"
	"github.com/pion/turn/v4"
	"github.com/pion/webrtc/v4"
	pionmedia "github.com/pion/webrtc/v4/pkg/media"
)

var (
	appPacket    = []byte{0x78, 42}
	modulePacket = []byte{0x78, 77}
)

// testApp is an offering peer on loopback that behaves like the App:
// one sendrecv Opus track and a complete, non-trickle offer.
type testApp struct {
	pc          *webrtc.PeerConnection
	track       *webrtc.TrackLocalStaticSample
	redTrack    *webrtc.TrackLocalStaticRTP
	redReceived atomic.Uint64
	received    chan []byte
	offer       string
}

func newTestApp(t *testing.T, useRED ...bool) *testApp {
	red := len(useRED) > 0 && useRED[0]
	t.Helper()
	m := &webrtc.MediaEngine{}
	if e := m.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1"}, PayloadType: 111}, webrtc.RTPCodecTypeAudio); e != nil {
		t.Fatal(e)
	}
	if red {
		if e := m.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: "audio/red", ClockRate: 48000, Channels: 2, SDPFmtpLine: "111/111"}, PayloadType: 63}, webrtc.RTPCodecTypeAudio); e != nil {
			t.Fatal(e)
		}
	}
	s := webrtc.SettingEngine{}
	s.SetIncludeLoopbackCandidate(true)
	s.SetIPFilter(func(ip net.IP) bool { return ip.IsLoopback() })
	s.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	s.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	pc, e := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithSettingEngine(s)).NewPeerConnection(webrtc.Configuration{})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { pc.Close() })
	a := &testApp{pc: pc, received: make(chan []byte, 64)}
	if red {
		a.redTrack, _ = webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: "audio/red", ClockRate: 48000, Channels: 2, SDPFmtpLine: "111/111"}, "audio", "app")
		_, e = pc.AddTrack(a.redTrack)
	} else {
		a.track, _ = webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}, "audio", "app")
		_, e = pc.AddTrack(a.track)
	}
	if e != nil {
		t.Fatal(e)
	}
	pc.OnTrack(func(t *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			p, _, e := t.ReadRTP()
			if e != nil {
				return
			}
			payload := p.Payload
			if p.PayloadType == 63 && len(payload) >= 3 {
				a.redReceived.Add(1)
				// The fixed helper fixture emits one two-byte primary packet.
				payload = payload[len(payload)-2:]
			}
			select {
			case a.received <- payload:
			default:
			}
		}
	})
	offer, e := pc.CreateOffer(nil)
	if e != nil {
		t.Fatal(e)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if e = pc.SetLocalDescription(offer); e != nil {
		t.Fatal(e)
	}
	<-gathered
	a.offer = pc.LocalDescription().SDP
	return a
}
func (a *testApp) accept(t *testing.T, ctx context.Context, answer string) {
	t.Helper()
	if e := a.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); e != nil {
		t.Fatal(e)
	}
	go func() {
		for i := uint32(0); ctx.Err() == nil; i++ {
			if a.redTrack != nil {
				// Independent RFC 2198 fixture: at steady state the previous
				// two 20 ms timestamps and the current primary share one packet.
				payload := []byte{111}
				if i == 1 {
					payload = []byte{239, 15, 0, 2, 111}
					payload = append(payload, appPacket...)
				}
				if i >= 2 {
					payload = []byte{239, 30, 0, 2, 239, 15, 0, 2, 111}
					payload = append(payload, appPacket...)
					payload = append(payload, appPacket...)
				}
				payload = append(payload, appPacket...)
				_ = a.redTrack.WriteRTP(&rtp.Packet{Header: rtp.Header{Version: 2, SequenceNumber: uint16(i), Timestamp: i * rtc.OpusFrameTicks}, Payload: payload})
			} else {
				_ = a.track.WriteSample(pionmedia.Sample{Data: appPacket, Duration: rtc.FrameDuration})
			}
			time.Sleep(rtc.FrameDuration)
		}
	}()
}

// helperSocket stands in for the media manager's Unix socket and the native
// helper: for each session it acknowledges the Opus format, reports whether
// the App's packet reached playout and sends one capture packet every 20 ms.
func helperSocket(t *testing.T, ctx context.Context, fm *fakeMedia) chan bool {
	t.Helper()
	dir, e := os.MkdirTemp("/tmp", "rtc-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	fm.socket = filepath.Join(dir, "media.sock")
	fm.id = uid()
	fm.token = strings.Repeat("a", 64)
	listener, e := net.Listen("unix", fm.socket)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { listener.Close() })
	played := make(chan bool, 1)
	go func() {
		for {
			conn, e := listener.Accept()
			if e != nil {
				return
			}
			go serveHelper(ctx, conn, fm.id, played)
		}
	}()
	return played
}
func serveHelper(ctx context.Context, conn net.Conn, id string, played chan bool) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, e := media.ReadJSON(conn, 1024); e != nil {
		return
	}
	ack := map[string]any{"ok": true, "codec": "opus", "codec_frame_us": 20000, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320}
	if media.WriteJSON(conn, ack, 1024) != nil {
		return
	}
	conn.SetDeadline(time.Time{})
	go func() {
		for seq := uint64(1); ctx.Err() == nil; seq++ {
			conn.SetWriteDeadline(time.Now().Add(time.Second))
			if media.WriteFrame(conn, id, 2, media.Frame{Sequence: seq, Payload: modulePacket}) != nil {
				return
			}
			time.Sleep(rtc.FrameDuration)
		}
	}()
	var last uint64
	reported := false
	for {
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		f, _, e := media.ReadFrame(conn, id, 1, &last)
		if e != nil {
			return
		}
		if !reported && f.Flags == media.FlagOpus && bytes.Equal(f.Payload, appPacket) {
			reported = true
			played <- true
		}
	}
}
func expectDuplex(t *testing.T, ctx context.Context, app *testApp, played chan bool) {
	t.Helper()
	select {
	case <-played:
	case <-ctx.Done():
		t.Fatal("App packet did not reach playout")
	}
	for {
		select {
		case p := <-app.received:
			if bytes.Equal(p, modulePacket) {
				return
			}
		case <-ctx.Done():
			t.Fatal("module packet did not reach the App")
		}
	}
}

func TestUSBMediaDuplexAndCleanup(t *testing.T) {
	a, g, _ := usbFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fc := a.Control.(*fakeControl)
	fm := a.Media.(*fakeMedia)
	played := helperSocket(t, ctx, fm)
	// The USB link address is loopback here; the server is not started.
	a.USB.address = "127.0.0.1:8577"
	a.USB.ctx = ctx
	generation := uid()
	a.owners[fc.call] = owner{fc.call, g.Client, generation, fc.boot, fc.epoch}
	a.claim = &callClaim{client: g.Client, route: "usb", call: fc.call, boot: fc.boot, epoch: fc.epoch}
	path := "/v2/modules/" + a.P.id.ModuleID + "/calls/" + fc.call + "/media-sessions"
	call := func(method, path string, body any, nonce byte) *httptest.ResponseRecorder {
		var data []byte
		if body != nil {
			data, _ = json.Marshal(body)
		}
		recorder := httptest.NewRecorder()
		a.USB.ServeHTTP(recorder, signedUSB(t, g, method, path, data, strings.Repeat(fmt.Sprintf("%02x", nonce), 32)))
		return recorder
	}
	request := map[string]string{"codec": "lc3", "request_id": uid(), "connection_epoch": a.USB.epoch, "generation": generation}
	if r := call("POST", path, request, 1); r.Code != 400 {
		t.Fatal("LC3 media accepted", r.Code)
	}
	request["codec"] = "opus"
	r := call("POST", path, request, 2)
	var created struct {
		ID      string          `json:"session_id"`
		Expires string          `json:"expires_at"`
		Servers []rtc.ICEServer `json:"ice_servers"`
	}
	if r.Code != 201 || exact(r.Body.Bytes(), "session_id,expires_at,ice_servers", &created) != nil || created.Servers == nil || len(created.Servers) != 0 {
		t.Fatal("media result", r.Code, r.Body.String())
	}
	app := newTestApp(t)
	r = call("POST", path+"/"+created.ID+"/offer", map[string]string{"sdp": app.offer}, 3)
	var answer struct {
		SDP string `json:"sdp"`
	}
	if r.Code != 200 || exact(r.Body.Bytes(), "sdp", &answer) != nil || !strings.Contains(answer.SDP, "127.0.0.1") {
		t.Fatal("offer", r.Code, r.Body.String())
	}
	if r = call("POST", path+"/"+created.ID+"/offer", map[string]string{"sdp": app.offer}, 4); r.Code != 410 {
		t.Fatal("second offer accepted", r.Code)
	}
	app.accept(t, ctx, answer.SDP)
	expectDuplex(t, ctx, app, played)
	if a.LastBridgeStats().Candidate != "host" {
		t.Fatal("USB media not direct", a.LastBridgeStats())
	}
	if r = call("DELETE", path+"/"+created.ID, nil, 5); r.Code != 204 {
		t.Fatal("delete", r.Code)
	}
	deadline := time.Now().Add(2 * time.Second)
	for (fm.stops.Load() == 0 || a.LastBridgeStats().State != "closed") && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if fm.stops.Load() != 1 || a.LastBridgeStats().Reason != "media_cancelled" {
		t.Fatal("media not released", a.LastBridgeStats())
	}
}

// relay runs a TURN server on loopback that accepts one credential.
func relay(t *testing.T, username, password string) (udp, tcp string) {
	t.Helper()
	packet, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	stream, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	generator := func() turn.RelayAddressGenerator {
		return &turn.RelayAddressGeneratorStatic{RelayAddress: net.IPv4(127, 0, 0, 1), Address: "127.0.0.1"}
	}
	key := turn.GenerateAuthKey(username, "airsim", password)
	server, e := turn.NewServer(turn.ServerConfig{
		Realm: "airsim",
		AuthHandler: func(u, _ string, _ net.Addr) ([]byte, bool) {
			return key, u == username
		},
		PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: packet, RelayAddressGenerator: generator()}},
		ListenerConfigs:   []turn.ListenerConfig{{Listener: stream, RelayAddressGenerator: generator()}},
	})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { server.Close() })
	return packet.LocalAddr().String(), stream.Addr().String()
}

func TestRunMediaThroughRelay(t *testing.T) {
	for _, profile := range []struct {
		transport string
		red       bool
	}{{"udp", false}, {"tcp", false}, {"udp", true}, {"tcp", true}} {
		transport := profile.transport
		t.Run(fmt.Sprintf("%s/red=%t", transport, profile.red), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			fm := &fakeMedia{}
			played := helperSocket(t, ctx, fm)
			username := fmt.Sprintf("%d:%s:agent", time.Now().Add(time.Hour).Unix(), uid())
			udp, tcp := relay(t, username, "secret")
			address := map[string]string{"udp": udp, "tcp": tcp}[transport]
			a := &Agent{Media: fm}
			app := newTestApp(t, profile.red)
			answers := make(chan string, 1)
			streaming := make(chan struct{})
			done := make(chan string, 1)
			go func() {
				done <- a.runMedia(ctx, cancel, mediaRun{
					request: uid(), session: uid(), call: uid(), boot: uid(), epoch: uid(), offer: app.offer,
					config:    rtc.Config{Servers: []rtc.ICEServer{{URLs: []string{"turn:" + address + "?transport=" + transport}, Username: username, Credential: "secret"}}, GatherTimeout: 5 * time.Second},
					answer:    func(sdp string) bool { answers <- sdp; return true },
					streaming: func() { close(streaming) },
				})
			}()
			var answer string
			select {
			case answer = <-answers:
			case reason := <-done:
				t.Fatal("media ended before answer:", reason)
			}
			if !strings.Contains(answer, "typ relay") || strings.Contains(answer, "typ host") {
				t.Fatalf("answer is not relay-only:\n%s", answer)
			}
			app.accept(t, ctx, answer)
			select {
			case <-streaming:
			case reason := <-done:
				t.Fatal("media ended before streaming:", reason)
			}
			expectDuplex(t, ctx, app, played)
			if profile.red && app.redReceived.Load() == 0 {
				t.Fatal("TURN did not carry RED")
			}
			stats := a.LastBridgeStats()
			if stats.Candidate != "relay" || stats.State != "streaming" || stats.Received == 0 || stats.Sent == 0 {
				t.Fatal("stats", stats)
			}
			app.pc.Close()
			select {
			case reason := <-done:
				if reason != "ice_failed" && reason != "rtp_closed" && reason != "rtp_timeout" {
					t.Fatal("unexpected end", reason)
				}
			case <-time.After(12 * time.Second):
				t.Fatal("App close not detected")
			}
			if fm.stops.Load() != 1 {
				t.Fatal("local media not released")
			}
		})
	}
}
