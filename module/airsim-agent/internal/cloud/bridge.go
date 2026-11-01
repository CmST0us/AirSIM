package cloud

import (
	"airsim.local/airsim-agent/internal/control"
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxSDP = 32768
	// mediaSetup bounds answering, helper start and ICE connection.
	mediaSetup    = 20 * time.Second
	gatherTimeout = 8 * time.Second
	// rtpTimeout ends media after the App stops sending.
	rtpTimeout = 5 * time.Second
)

type mediaStart struct {
	Request    string            `json:"request_id"`
	Session    string            `json:"session_id"`
	Call       string            `json:"call_id"`
	Boot       string            `json:"agent_boot_id"`
	Epoch      string            `json:"backend_epoch"`
	Client     string            `json:"client_installation_id"`
	Generation string            `json:"generation"`
	Expires    string            `json:"expires_at"`
	Offer      string            `json:"offer"`
	Servers    []json.RawMessage `json:"ice_servers"`
}
type BridgeStats struct {
	SessionID string `json:"session_id"`
	State     string `json:"state"`
	Reason    string `json:"reason"`
	Candidate string `json:"candidate"`
	Received  uint64 `json:"packets_received"`
	Sent      uint64 `json:"packets_sent"`
	Lost      uint64 `json:"packets_lost"`
	Late      uint64 `json:"packets_late"`
	FEC       uint64 `json:"fec_frames"`
	PLC       uint64 `json:"plc_frames"`
	Drops     uint64 `json:"queue_drops"`
	LocalGaps uint64 `json:"local_input_gaps"`
	// Stalls count waits well beyond the 20 ms frame period: for the next
	// helper frame, between RTP packets from the App, and between frames paced
	// to the helper. Send stalls are RTP writes that took longer than a frame.
	LocalStalls     uint64 `json:"local_stalls"`
	LocalStallMax   int64  `json:"local_stall_max_ms"`
	SendStalls      uint64 `json:"send_stalls"`
	SendStallMax    int64  `json:"send_stall_max_ms"`
	RTPStalls       uint64 `json:"rtp_stalls"`
	RTPStallMax     int64  `json:"rtp_stall_max_ms"`
	PlayoutStalls   uint64 `json:"playout_stalls"`
	PlayoutStallMax int64  `json:"playout_stall_max_ms"`
}
type bridgeCounters struct {
	received, sent, lost, late, fec, plc, drops, local atomic.Uint64
	localStall, sendStall, rtpStall, playoutStall      stall
	candidate                                          atomic.Value
}

// stall counts intervals above a threshold and keeps the longest. Each stall
// has a single writer.
type stall struct {
	count atomic.Uint64
	max   atomic.Int64
}

const (
	frameStall = 60 * time.Millisecond
	rtpStall   = 100 * time.Millisecond
)

func (s *stall) add(d, threshold time.Duration) {
	if d > threshold {
		s.count.Add(1)
		if ms := d.Milliseconds(); ms > s.max.Load() {
			s.max.Store(ms)
		}
	}
}
func (s *stall) observe(last *time.Time, now time.Time, threshold time.Duration) {
	if !last.IsZero() {
		s.add(now.Sub(*last), threshold)
	}
	*last = now
}

func validSDP(sdp string) bool { return len(sdp) <= maxSDP && strings.HasPrefix(sdp, "v=0\r\n") }

// Only the future plausibility bound tolerates five seconds of clock skew.
// The server remains authoritative for its unchanged absolute answer deadline.
func validMediaExpiry(expires string, now time.Time) bool {
	expiry, err := utc(expires)
	if err != nil {
		return false
	}
	remaining := expiry.Sub(now)
	return remaining > 0 && remaining <= 20*time.Second
}
func parseServers(raw []json.RawMessage) ([]rtc.ICEServer, bool) {
	if len(raw) == 0 || len(raw) > 4 {
		return nil, false
	}
	servers := make([]rtc.ICEServer, 0, len(raw))
	for _, b := range raw {
		var s rtc.ICEServer
		if exact(b, "urls,username,credential", &s) != nil || len(s.URLs) == 0 || len(s.URLs) > 4 || s.Username == "" || len(s.Username) > 256 || s.Credential == "" || len(s.Credential) > 256 {
			return nil, false
		}
		for _, u := range s.URLs {
			if !strings.HasPrefix(u, "turn:") || len(u) > 256 {
				return nil, false
			}
		}
		servers = append(servers, s)
	}
	return servers, true
}
func (c *connection) startMedia(b []byte) bool {
	return c.startMediaAt(b, time.Now())
}
func (c *connection) startMediaAt(b []byte, now time.Time) bool {
	var r mediaStart
	if exact(b, "request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,expires_at,offer,ice_servers", &r) != nil {
		return false
	}
	for _, id := range []string{r.Request, r.Session, r.Call, r.Boot, r.Epoch, r.Client, r.Generation} {
		if !control.ValidID(id) {
			return false
		}
	}
	servers, ok := parseServers(r.Servers)
	if !ok || !validSDP(r.Offer) || !validMediaExpiry(r.Expires, now) {
		return false
	}
	c.agent.ownerMu.Lock()
	o, ok := c.owners[r.Call]
	usbOwned := c.agent.claim != nil && c.agent.claim.route == "usb"
	c.agent.ownerMu.Unlock()
	if usbOwned || !ok || o.client != r.Client || o.generation != r.Generation || o.boot != r.Boot || o.epoch != r.Epoch {
		return c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": "media_owner"})
	}
	if c.mediaCancel != nil {
		select {
		case <-c.mediaDone:
			c.mediaCancel = nil
		default:
			return c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": "media_busy"})
		}
	}
	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Minute)
	c.mediaCancel = cancel
	c.mediaID = r.Session
	c.mediaDone = make(chan struct{})
	done := c.mediaDone
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer close(done)
		defer cancel()
		c.send("media_status", map[string]string{"session_id": r.Session, "state": "starting", "reason": ""})
		reason := c.agent.runMedia(ctx, mediaRun{
			request: r.Request, session: r.Session, call: r.Call, boot: r.Boot, epoch: r.Epoch, offer: r.Offer,
			config: rtc.Config{Servers: servers, GatherTimeout: gatherTimeout},
			answer: func(sdp string) bool {
				return c.send("media_answer", map[string]string{"session_id": r.Session, "answer": sdp})
			},
			streaming: func() bool {
				return c.send("media_status", map[string]string{"session_id": r.Session, "state": "streaming", "reason": ""})
			},
		})
		c.send("media_status", map[string]string{"session_id": r.Session, "state": "closed", "reason": reason})
	}()
	return true
}

// mediaRun is one WebRTC media session for an owned, active call.
type mediaRun struct {
	request, session, call, boot, epoch, offer string
	config                                     rtc.Config
	// answer delivers the complete answer to the App's signaling path.
	answer    func(string) bool
	streaming func() bool
}

type localMedia struct {
	conn net.Conn
	id   string
	err  string
}

// openLocal starts the helper session and completes the Unix media handshake.
func (a *Agent) openLocal(ctx context.Context, r mediaRun) localMedia {
	local, code := a.Media.Create(ctx, media.Request{RequestID: r.request, Boot: r.boot, Epoch: r.epoch, CallID: r.call})
	if code != 201 && code != 200 {
		return localMedia{err: "media_local_busy"}
	}
	conn, e := (&net.Dialer{}).DialContext(ctx, "unix", local.Socket)
	if e != nil {
		a.Media.Stop(local.ID)
		return localMedia{err: "media_local_connect"}
	}
	deadline, _ := ctx.Deadline()
	conn.SetDeadline(deadline)
	fail := func(reason string) localMedia {
		conn.Close()
		a.Media.Stop(local.ID)
		return localMedia{err: reason}
	}
	if media.WriteJSON(conn, map[string]string{"session_id": local.ID, "token": local.Token}, 1024) != nil {
		return fail("media_local_auth")
	}
	b, e := media.ReadJSON(conn, 1024)
	if e != nil {
		return fail("media_local_auth")
	}
	var ack struct {
		OK bool `json:"ok"`
		media.Format
	}
	if exact(b, "ok,codec,sample_rate,channels,sample_format,frame_samples,codec_frame_us", &ack) != nil || !ack.OK || ack.Format != media.OpusFormat {
		return fail("media_local_auth")
	}
	conn.SetDeadline(time.Time{})
	return localMedia{conn: conn, id: local.ID}
}

func (a *Agent) runMedia(parent context.Context, r mediaRun) (reason string) {
	counts := &bridgeCounters{}
	a.beginBridge(r.session, counts)
	defer func() { a.endBridge(r.session, reason) }()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	setup, scancel := context.WithTimeout(ctx, mediaSetup)
	defer scancel()
	peer, answer, e := rtc.Answer(setup, r.config, r.offer)
	if e != nil {
		if errors.Is(e, rtc.ErrGather) {
			return "media_gather"
		}
		if ctx.Err() != nil {
			return "media_cancelled"
		}
		return "media_offer"
	}
	defer peer.Close()
	if !r.answer(answer) {
		return "control_disconnected"
	}
	// The helper starts while ICE and DTLS connect.
	local := a.openLocal(setup, r)
	if local.err != "" {
		return local.err
	}
	defer func() {
		local.conn.Close()
		a.Media.Stop(local.id)
	}()
	return streamMedia(ctx, cancel, peer, local, counts, func() (rtcTrack, string) {
		select {
		case <-peer.Connected():
		case <-peer.Failed():
			return nil, "ice_failed"
		case <-setup.Done():
			return nil, setupReason(ctx)
		}
		track, e := peer.Track(setup)
		if e != nil {
			if errors.Is(e, rtc.ErrFailed) {
				return nil, "ice_failed"
			}
			return nil, setupReason(ctx)
		}
		counts.candidate.Store(peer.Candidate())
		a.bridgeState(r.session, "streaming", "")
		if !r.streaming() {
			return nil, "control_disconnected"
		}
		return track, ""
	})
}
func setupReason(ctx context.Context) string {
	if ctx.Err() != nil {
		return "media_cancelled"
	}
	return "media_setup_timeout"
}

// mediaPeer and rtcTrack are the parts of the WebRTC connection streamMedia uses.
type mediaPeer interface {
	WriteOpus([]byte) error
	Failed() <-chan struct{}
	Close()
}
type rtcTrack interface {
	ReadPacket([]byte, time.Time) (uint16, []byte, error)
}

// streamMedia moves packets until either side fails. The helper is served from
// the moment it is ready: until connect returns the media track it receives
// erasures and its captured frames are dropped, so no stale audio is sent.
// Downlink RTP is ordered by the jitter buffer and paced to the helper every
// 20 ms; uplink Opus from the helper is sent as soon as it is encoded.
func streamMedia(ctx context.Context, cancel context.CancelFunc, peer mediaPeer, local localMedia, counts *bridgeCounters, connect func() (rtcTrack, string)) string {
	var first sync.Once
	reason := "media_cancelled"
	fail := func(code string) {
		if ctx.Err() != nil {
			return
		}
		first.Do(func() { reason = code; cancel() })
	}
	jitter := newJitter(counts)
	clock := realPlayoutClock{}
	var live atomic.Bool
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		track, code := connect()
		if code != "" {
			fail(code)
			return
		}
		live.Store(true)
		buf := make([]byte, 1500)
		var last time.Time
		for {
			seq, payload, e := track.ReadPacket(buf, time.Now().Add(rtpTimeout))
			if e != nil {
				fail(rtpReason(e))
				return
			}
			counts.rtpStall.observe(&last, time.Now(), rtpStall)
			if len(payload) == 0 || len(payload) > media.MaxPayload {
				continue
			}
			jitter.push(seq, append([]byte(nil), payload...), clock.Now())
		}
	}()
	go func() {
		defer wg.Done()
		var seq uint64
		var last time.Time
		paced(ctx, clock, clock.Now(), func() error {
			now := clock.Now()
			counts.playoutStall.observe(&last, now, frameStall)
			f := jitter.pop(now)
			seq++
			f.Sequence = seq
			local.conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
			e := media.WriteFrame(local.conn, local.id, 1, f)
			if e != nil {
				fail(ioReason("local_write", e))
			}
			return e
		})
	}()
	go func() {
		defer wg.Done()
		var seq uint64
		for {
			local.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			waiting := time.Now()
			f, gap, e := media.ReadFrame(local.conn, local.id, 2, &seq)
			if e != nil {
				if errors.Is(e, media.ErrProtocol) {
					fail("local_invalid_frame")
				} else {
					fail(ioReason("local_read", e))
				}
				return
			}
			if seq > 1 {
				counts.localStall.add(time.Since(waiting), frameStall)
			}
			counts.local.Add(gap)
			if f.Flags != media.FlagOpus {
				fail("local_invalid_frame")
				return
			}
			if !live.Load() {
				continue
			}
			sending := time.Now()
			if e = peer.WriteOpus(f.Payload); e != nil {
				fail("rtp_write")
				return
			}
			counts.sendStall.add(time.Since(sending), rtc.FrameDuration)
			counts.sent.Add(1)
		}
	}()
	select {
	case <-ctx.Done():
	case <-peer.Failed():
		fail("ice_failed")
	}
	local.conn.Close()
	peer.Close()
	wg.Wait()
	return reason
}

func rtpReason(err error) string {
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return "rtp_timeout"
	}
	return "rtp_closed"
}
func ioReason(direction string, err error) string {
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout()) {
		return direction + "_timeout"
	}
	return direction + "_closed"
}

func countersInto(s BridgeStats, c *bridgeCounters) BridgeStats {
	if c != nil {
		s.Received = c.received.Load()
		s.Sent = c.sent.Load()
		s.Lost = c.lost.Load()
		s.Late = c.late.Load()
		s.FEC = c.fec.Load()
		s.PLC = c.plc.Load()
		s.Drops = c.drops.Load()
		s.LocalGaps = c.local.Load()
		s.LocalStalls, s.LocalStallMax = c.localStall.count.Load(), c.localStall.max.Load()
		s.SendStalls, s.SendStallMax = c.sendStall.count.Load(), c.sendStall.max.Load()
		s.RTPStalls, s.RTPStallMax = c.rtpStall.count.Load(), c.rtpStall.max.Load()
		s.PlayoutStalls, s.PlayoutStallMax = c.playoutStall.count.Load(), c.playoutStall.max.Load()
		if v, ok := c.candidate.Load().(string); ok {
			s.Candidate = v
		}
	}
	return s
}
func (a *Agent) beginBridge(id string, c *bridgeCounters) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	a.lastBridge = BridgeStats{SessionID: id, State: "starting"}
	a.activeCounters = c
}
func (a *Agent) bridgeState(id, state, reason string) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	if a.lastBridge.SessionID == id {
		a.lastBridge.State = state
		a.lastBridge.Reason = reason
	}
}
func (a *Agent) endBridge(id, reason string) {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	if a.lastBridge.SessionID == id {
		a.lastBridge = countersInto(a.lastBridge, a.activeCounters)
		a.lastBridge.State = "closed"
		a.lastBridge.Reason = reason
		a.activeCounters = nil
	}
}
func (a *Agent) LastBridgeStats() BridgeStats {
	a.statsMu.Lock()
	defer a.statsMu.Unlock()
	s := countersInto(a.lastBridge, a.activeCounters)
	if s.State == "" {
		s.State = "idle"
	}
	return s
}
