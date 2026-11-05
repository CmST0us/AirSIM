package rtc

import (
	"bytes"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/rtp"
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
	if !strings.Contains(answer, "maxaveragebitrate=96000") {
		t.Fatal("App encoder did not receive the 96 kbps preference")
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
	// 96 kbps at 20 ms is 240 payload bytes, unchanged by either relay direction.
	sent := bytes.Repeat([]byte{0x78, 1, 2, 3}, 60)
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
	first, e := track.ReadPacket(buf, time.Now().Add(2*time.Second))
	if e != nil || (len(first) != 1 || !bytes.Equal(first[0].Payload, sent)) {
		t.Fatal("App packet not received", e)
	}
	next, e := track.ReadPacket(buf, time.Now().Add(2*time.Second))
	if e != nil || (len(next) != 1 || next[0].Sequence != first[0].Sequence+1 || next[0].Timestamp-first[0].Timestamp != OpusFrameTicks) {
		t.Fatal("sequence", first, next, e)
	}
	back := bytes.Repeat([]byte{0x78, 9, 8}, 80)
	for i := 0; i < 3; i++ {
		if e = peer.WriteOpus(back, 0); e != nil {
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
	if _, e = track.ReadPacket(buf, time.Now().Add(-time.Second)); e == nil {
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

// Exercise actual SRTP in both directions, negotiated payload mapping, exact
// redundancy and capture gaps. No microphones or external network are used.
func TestREDPeerMovesPacketsAndPreservesCaptureGaps(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	codecs := audioCodecs{opus: 109, red: 63, hasRED: true}
	pc, e := api(Config{LocalIP: net.IPv4(127, 0, 0, 1)}, codecs).NewPeerConnection(webrtc.Configuration{})
	if e != nil {
		t.Fatal(e)
	}
	defer pc.Close()
	out, e := webrtc.NewTrackLocalStaticRTP(codecs.parameters()[0].RTPCodecCapability, "audio", "app")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = pc.AddTrack(out); e != nil {
		t.Fatal(e)
	}
	received := make(chan *rtp.Packet, 10)
	pc.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			p, _, e := track.ReadRTP()
			if e != nil {
				return
			}
			select {
			case received <- p:
			case <-ctx.Done():
				return
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
	peer, answer, e := Answer(ctx, Config{LocalIP: net.IPv4(127, 0, 0, 1), GatherTimeout: time.Second}, pc.LocalDescription().SDP)
	if e != nil {
		t.Fatal(e)
	}
	defer peer.Close()
	if !strings.Contains(answer, "UDP/TLS/RTP/SAVPF 63 109\r\n") {
		t.Fatal("RED not preferred")
	}
	if e = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); e != nil {
		t.Fatal(e)
	}
	select {
	case <-peer.Connected():
	case <-ctx.Done():
		t.Fatal("connect")
	}
	sent := []AudioPacket{{Sequence: 10, Timestamp: 10000, Payload: []byte{0x78, 1}}, {Sequence: 11, Timestamp: 10960, Payload: []byte{0x78, 2}}, {Sequence: 12, Timestamp: 11920, Payload: []byte{0x78, 3}}}
	wire := encodeRED(sent[2], sent[:2], 109)
	if e = out.WriteRTP(&rtp.Packet{Header: rtp.Header{Version: 2, SequenceNumber: 12, Timestamp: 11920}, Payload: wire}); e != nil {
		t.Fatal(e)
	}
	remote, e := peer.Track(ctx)
	if e != nil {
		t.Fatal(e)
	}
	got, e := remote.ReadPacket(make([]byte, 1500), time.Now().Add(time.Second))
	if e != nil || len(got) != 3 {
		t.Fatal("RED read", e, len(got))
	}
	for i, want := range []AudioPacket{sent[2], sent[0], sent[1]} {
		if got[i].Timestamp != want.Timestamp || !bytes.Equal(got[i].Payload, want.Payload) {
			t.Fatal("RED content changed")
		}
	}
	for i := 0; i < 4; i++ {
		skipped := uint64(0)
		if i == 3 {
			skipped = 2
		}
		if e = peer.WriteOpus([]byte{0x78, byte(i)}, skipped); e != nil {
			t.Fatal(e)
		}
	}
	var previous *rtp.Packet
	for i := 0; i < 4; i++ {
		var packet *rtp.Packet
		select {
		case packet = <-received:
		case <-ctx.Done():
			t.Fatal("receive")
		}
		blocks, e := decodeRED(packet.SequenceNumber, packet.Timestamp, packet.Payload, 109)
		expected := min(i+1, 3)
		if i == 3 {
			expected = 1
		}
		if e != nil || len(blocks) != expected || packet.PayloadType != 63 {
			t.Fatal("RED negotiation/history", i, e)
		}
		if previous != nil {
			advance := uint32(1)
			if i == 3 {
				advance = 3
			}
			if packet.Timestamp-previous.Timestamp != advance*OpusFrameTicks || packet.SequenceNumber-previous.SequenceNumber != 1 {
				t.Fatal("capture gap hidden")
			}
		}
		previous = packet
	}
}
