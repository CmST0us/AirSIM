package rtc

import (
	"bytes"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

// app builds an offering peer on loopback the way the App's libwebrtc does:
// one sendrecv Opus track and a complete, non-trickle offer.
func app(t *testing.T) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticSample, string) {
	t.Helper()
	m := &webrtc.MediaEngine{}
	if e := m.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1"}, PayloadType: 111}, webrtc.RTPCodecTypeAudio); e != nil {
		t.Fatal(e)
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
	track, e := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}, "audio", "app")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = pc.AddTrack(track); e != nil {
		t.Fatal(e)
	}
	offer, e := pc.CreateOffer(nil)
	if e != nil {
		t.Fatal(e)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if e = pc.SetLocalDescription(offer); e != nil {
		t.Fatal(e)
	}
	<-gathered
	return pc, track, pc.LocalDescription().SDP
}

func TestAnswerCarriesVoicePreferencesAndMovesOpus(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pc, out, offer := app(t)
	received := make(chan []byte, 8)
	pc.OnTrack(func(t *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			p, _, e := t.ReadRTP()
			if e != nil {
				return
			}
			received <- p.Payload
		}
	})
	peer, answer, e := Answer(ctx, Config{LocalIP: net.IPv4(127, 0, 0, 1), GatherTimeout: 2 * time.Second}, offer)
	if e != nil {
		t.Fatal(e)
	}
	defer peer.Close()
	if !strings.Contains(answer, "a=fmtp:111 "+opusFmtp+"\r\na=ptime:20\r\n") || strings.Count(answer, "a=fmtp:111") != 1 || !strings.Contains(answer, "a=candidate:") || !strings.Contains(answer, "a=sendrecv") {
		t.Fatalf("answer:\n%s", answer)
	}
	if e = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); e != nil {
		t.Fatal(e)
	}
	select {
	case <-peer.Connected():
	case <-ctx.Done():
		t.Fatal("not connected")
	}
	if peer.Candidate() != "host" {
		t.Fatalf("candidate %q", peer.Candidate())
	}
	sent := []byte{0x78, 1, 2, 3}
	go func() {
		for ctx.Err() == nil {
			_ = out.WriteSample(media.Sample{Data: sent, Duration: FrameDuration})
			time.Sleep(FrameDuration)
		}
	}()
	track, e := peer.Track(ctx)
	if e != nil {
		t.Fatal(e)
	}
	buf := make([]byte, 1500)
	first, payload, e := track.ReadPacket(buf, time.Now().Add(2*time.Second))
	if e != nil || !bytes.Equal(payload, sent) {
		t.Fatal("App packet not received", e)
	}
	next, _, e := track.ReadPacket(buf, time.Now().Add(2*time.Second))
	if e != nil || next != first+1 {
		t.Fatal("sequence", first, next, e)
	}
	back := []byte{0x78, 9, 8}
	for i := 0; i < 3; i++ {
		if e = peer.WriteOpus(back); e != nil {
			t.Fatal(e)
		}
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, back) {
			t.Fatal("module packet changed")
		}
	case <-ctx.Done():
		t.Fatal("module packet not received")
	}
	if _, _, e = track.ReadPacket(buf, time.Now().Add(-time.Second)); e == nil {
		t.Fatal("expired deadline read")
	}
	peer.Close()
	select {
	case <-peer.Failed():
	case <-time.After(time.Second):
		t.Fatal("close not reported")
	}
}

func TestAnswerRejectsInvalidOffer(t *testing.T) {
	if _, _, e := Answer(context.Background(), Config{LocalIP: net.IPv4(127, 0, 0, 1), GatherTimeout: time.Second}, "v=0\r\n"); e != ErrRejected {
		t.Fatal(e)
	}
}

func TestPreferVoiceRewritesOnlyOpus(t *testing.T) {
	in := strings.Join([]string{"v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 109 0", "a=rtpmap:109 opus/48000/2", "a=fmtp:109 minptime=10;useinbandfec=1", "a=rtpmap:0 PCMU/8000", "a=fmtp:0 x", ""}, "\r\n")
	out := preferVoice(in)
	want := strings.Join([]string{"v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 109 0", "a=rtpmap:109 opus/48000/2", "a=fmtp:109 " + opusFmtp, "a=ptime:20", "a=rtpmap:0 PCMU/8000", "a=fmtp:0 x", ""}, "\r\n")
	if out != want {
		t.Fatalf("got\n%q", out)
	}
	if preferVoice("v=0\r\n") != "v=0\r\n" {
		t.Fatal("SDP without Opus changed")
	}
}
