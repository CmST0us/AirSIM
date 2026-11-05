// Package rtc terminates the App's WebRTC audio connection on the module: ICE,
// DTLS-SRTP and RTP for one Opus track. Encoding and decoding stay in the
// native helper; this package moves Opus packets only.
package rtc

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

type Config struct {
	Servers []ICEServer
	// LocalIP limits the connection to host candidates on one address, the USB
	// link. Without it the module behind carrier NAT gathers relay candidates only.
	LocalIP net.IP
	// GatherTimeout bounds candidate gathering before the answer is sent.
	GatherTimeout time.Duration
}

// FrameDuration is the Opus packet time on both directions.
const FrameDuration = 20 * time.Millisecond

// opusFmtp is what the module asks the App's encoder for: wideband voice with
// in-band FEC and a 96 kbps target. libwebrtc uses maxaveragebitrate to configure
// its Opus encoder; the helper's capture encoder uses the same target.
const opusFmtp = "minptime=10;useinbandfec=1;maxplaybackrate=16000;sprop-maxcapturerate=16000;maxaveragebitrate=96000"

var (
	ErrRejected = errors.New("rtc_offer_rejected")
	ErrGather   = errors.New("rtc_gather_timeout")
	ErrFailed   = errors.New("rtc_failed")
)

type Peer struct {
	pc        *webrtc.PeerConnection
	track     *webrtc.TrackLocalStaticRTP
	codecs    audioCodecs
	sendMu    sync.Mutex
	sequence  uint16
	timestamp uint32
	history   []AudioPacket
	sender    *webrtc.RTPSender
	remote    chan *webrtc.TrackRemote
	connected chan struct{}
	failed    chan struct{}
	up, down  sync.Once
}

func api(c Config, codecs audioCodecs) *webrtc.API {
	m := &webrtc.MediaEngine{}
	for _, codec := range codecs.parameters() {
		_ = m.RegisterCodec(codec, webrtc.RTPCodecTypeAudio)
	}

	r := &interceptor.Registry{}
	_ = webrtc.ConfigureRTCPReports(r)
	s := webrtc.SettingEngine{}
	// ICE reports disconnected after 5 s without traffic and fails 5 s later.
	s.SetICETimeouts(5*time.Second, 5*time.Second, 2*time.Second)
	s.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	s.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	if c.LocalIP != nil {
		ip := c.LocalIP
		s.SetIPFilter(func(candidate net.IP) bool { return candidate.Equal(ip) })
		s.SetIncludeLoopbackCandidate(ip.IsLoopback())
	}
	return webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(r), webrtc.WithSettingEngine(s))
}

// Answer accepts the App's complete offer and returns the module's complete
// answer once candidate gathering finishes.
func Answer(ctx context.Context, c Config, offer string) (*Peer, string, error) {
	configuration := webrtc.Configuration{BundlePolicy: webrtc.BundlePolicyMaxBundle, RTCPMuxPolicy: webrtc.RTCPMuxPolicyRequire, ICETransportPolicy: webrtc.ICETransportPolicyRelay}
	if c.LocalIP != nil {
		configuration.ICETransportPolicy = webrtc.ICETransportPolicyAll
	}
	for _, s := range c.Servers {
		configuration.ICEServers = append(configuration.ICEServers, webrtc.ICEServer{URLs: s.URLs, Username: s.Username, Credential: s.Credential})
	}
	codecs, e := offeredAudioCodecs(offer)
	if e != nil {
		return nil, "", e
	}
	pc, e := api(c, codecs).NewPeerConnection(configuration)
	if e != nil {
		return nil, "", e
	}
	p := &Peer{pc: pc, codecs: codecs, sequence: uint16(rand.Uint32()), timestamp: rand.Uint32(), remote: make(chan *webrtc.TrackRemote, 1), connected: make(chan struct{}), failed: make(chan struct{})}
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		switch s {
		case webrtc.PeerConnectionStateConnected:
			p.up.Do(func() { close(p.connected) })
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			p.fail()
		}
	})
	pc.OnTrack(func(t *webrtc.TrackRemote, r *webrtc.RTPReceiver) {
		if t.Kind() != webrtc.RTPCodecTypeAudio || (!strings.EqualFold(t.Codec().MimeType, webrtc.MimeTypeOpus) && !strings.EqualFold(t.Codec().MimeType, "audio/red")) {
			return
		}
		select {
		case p.remote <- t:
		default:
			return
		}
		go drainRTCP(func() error { _, _, e := r.ReadRTCP(); return e })
	})
	if e = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); e != nil {
		p.Close()
		return nil, "", ErrRejected
	}
	capability := webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}
	if codecs.hasRED {
		capability.MimeType = "audio/red"
		capability.SDPFmtpLine = fmt.Sprintf("%d/%d", codecs.opus, codecs.opus)
	}
	p.track, e = webrtc.NewTrackLocalStaticRTP(capability, "audio", "airsim")
	if e == nil {
		p.sender, e = pc.AddTrack(p.track)
	}
	if e != nil {
		p.Close()
		return nil, "", ErrRejected
	}
	go drainRTCP(func() error { b := make([]byte, 1500); _, _, e := p.sender.Read(b); return e })
	// Set preferences through Pion, before CreateAnswer. Editing the generated
	// answer before SetLocalDescription violates its signaling state machine.
	for _, transceiver := range pc.GetTransceivers() {
		if transceiver.Kind() == webrtc.RTPCodecTypeAudio {
			if e = transceiver.SetCodecPreferences(codecs.parameters()); e != nil {
				p.Close()
				return nil, "", ErrRejected
			}
		}
	}
	answer, e := pc.CreateAnswer(nil)
	if e != nil {
		p.Close()
		return nil, "", ErrRejected
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if e = pc.SetLocalDescription(answer); e != nil {
		p.Close()
		return nil, "", ErrRejected
	}
	timer := time.NewTimer(c.GatherTimeout)
	defer timer.Stop()
	select {
	case <-gathered:
	case <-timer.C:
		p.Close()
		return nil, "", ErrGather
	case <-ctx.Done():
		p.Close()
		return nil, "", ctx.Err()
	}
	local := pc.LocalDescription()
	if local == nil || !strings.Contains(local.SDP, "a=candidate:") {
		p.Close()
		return nil, "", ErrGather
	}
	return p, preferVoice(local.SDP), nil
}

func drainRTCP(read func() error) {
	for read() == nil {
	}
}

var opusMap = regexp.MustCompile(`(?m)^a=rtpmap:(\d+) opus/48000/2\r$`)

// preferVoice states the module's receive preferences for the App's Opus
// encoder in the answer. The negotiated payload type and every transport
// attribute stay as generated.
func preferVoice(sdp string) string {
	m := opusMap.FindStringSubmatch(sdp)
	if m == nil {
		return sdp
	}
	lines := strings.Split(sdp, "\r\n")
	out := make([]string, 0, len(lines)+2)
	for _, line := range lines {
		if strings.HasPrefix(line, "a=fmtp:"+m[1]+" ") || line == "a=ptime:20" {
			continue
		}
		out = append(out, line)
		if line == "a=rtpmap:"+m[1]+" opus/48000/2" {
			out = append(out, "a=fmtp:"+m[1]+" "+opusFmtp, "a=ptime:20")
		}
	}
	return strings.Join(out, "\r\n")
}

func (p *Peer) fail() { p.down.Do(func() { close(p.failed) }) }

// Connected closes once ICE and DTLS complete.
func (p *Peer) Connected() <-chan struct{} { return p.connected }

// Failed closes when the connection fails or closes.
func (p *Peer) Failed() <-chan struct{} { return p.failed }

// Remote is the App's audio track.
type Remote struct {
	t      *webrtc.TrackRemote
	codecs audioCodecs
}

// Track waits for the App's audio track.
func (p *Peer) Track(ctx context.Context) (*Remote, error) {
	select {
	case t := <-p.remote:
		return &Remote{t: t, codecs: p.codecs}, nil
	case <-p.failed:
		return nil, ErrFailed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// WriteOpus preserves the capture timeline across locally dropped frames.
// A skipped source frame advances the RTP timestamp, not the packet counter; it must
// not be hidden by squeezing the following audio into its old time slot.
func (p *Peer) WriteOpus(packet []byte, skipped uint64) error {
	if !opus20ms(packet) {
		return ErrAudioPacket
	}
	p.sendMu.Lock()
	defer p.sendMu.Unlock()
	p.timestamp += uint32(skipped) * OpusFrameTicks
	if skipped != 0 {
		p.history = nil
	}
	f := AudioPacket{Sequence: p.sequence, Timestamp: p.timestamp, Payload: packet}
	payload := packet
	if p.codecs.hasRED {
		payload = encodeRED(f, p.history, p.codecs.opus)
	}
	err := p.track.WriteRTP(&rtp.Packet{Header: rtp.Header{Version: 2, SequenceNumber: p.sequence, Timestamp: p.timestamp}, Payload: payload})
	if err != nil {
		return err
	}
	if p.codecs.hasRED {
		f.Payload = append([]byte(nil), packet...)
		p.history = append(p.history, f)
		if len(p.history) > redDepth {
			p.history = p.history[len(p.history)-redDepth:]
		}
	}
	p.sequence++
	p.timestamp += OpusFrameTicks
	return nil
}

// Candidate reports the local candidate type of the selected pair.
func (p *Peer) Candidate() string {
	if p.sender == nil || p.sender.Transport() == nil {
		return ""
	}
	pair, e := p.sender.Transport().ICETransport().GetSelectedCandidatePair()
	if e != nil || pair == nil || pair.Local == nil {
		return ""
	}
	return pair.Local.Typ.String()
}

func (p *Peer) Close() {
	p.fail()
	_ = p.pc.Close()
}

// ReadPacket preserves RTP media timestamps and extracts exact RED copies.
// Returned payloads alias buf and are consumed before the next network read.
func (r *Remote) ReadPacket(buf []byte, deadline time.Time) ([]AudioPacket, error) {
	if e := r.t.SetReadDeadline(deadline); e != nil {
		return nil, e
	}
	n, _, e := r.t.Read(buf)
	if e != nil {
		return nil, e
	}
	var packet rtp.Packet
	if e = packet.Unmarshal(buf[:n]); e != nil {
		return nil, ErrAudioPacket
	}
	if r.codecs.hasRED && packet.PayloadType == r.codecs.red {
		return decodeRED(packet.SequenceNumber, packet.Timestamp, packet.Payload, r.codecs.opus)
	}
	if packet.PayloadType != r.codecs.opus || !opus20ms(packet.Payload) {
		return nil, ErrAudioPacket
	}
	return []AudioPacket{{Sequence: packet.SequenceNumber, Timestamp: packet.Timestamp, Payload: packet.Payload}}, nil
}
