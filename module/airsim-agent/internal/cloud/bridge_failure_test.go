package cloud

import (
	"airsim.local/airsim-agent/internal/media"
	"airsim.local/airsim-agent/internal/rtc"
	"context"
	"errors"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

type fakePeer struct {
	mu      sync.Mutex
	written [][]byte
	failed  chan struct{}
	once    sync.Once
}

func newFakePeer() *fakePeer { return &fakePeer{failed: make(chan struct{})} }
func (p *fakePeer) WriteOpus(b []byte, _ uint64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.written = append(p.written, append([]byte(nil), b...))
	return nil
}
func (p *fakePeer) Failed() <-chan struct{} { return p.failed }
func (p *fakePeer) Close()                  { p.once.Do(func() { close(p.failed) }) }
func (p *fakePeer) sent() int               { p.mu.Lock(); defer p.mu.Unlock(); return len(p.written) }

// fakeTrack delivers queued packets, then blocks until its deadline.
type fakeTrack struct {
	packets chan []byte
	seq     uint16
	closed  chan struct{}
}

func newFakeTrack() *fakeTrack {
	return &fakeTrack{packets: make(chan []byte, 64), closed: make(chan struct{})}
}
func (t *fakeTrack) ReadPacket(buf []byte, deadline time.Time) ([]rtc.AudioPacket, error) {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case p := <-t.packets:
		t.seq++
		return []rtc.AudioPacket{{Sequence: t.seq, Timestamp: uint32(t.seq) * rtc.OpusFrameTicks, Payload: p}}, nil
	case <-timer.C:
		return nil, os.ErrDeadlineExceeded
	case <-t.closed:
		return nil, net.ErrClosed
	}
}

func TestStreamMediaFirstFailure(t *testing.T) {
	for _, kind := range []string{"rtp_closed", "local_read_closed", "local_invalid_frame", "ice_failed", "media_cancelled"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			peer, track := newFakePeer(), newFakeTrack()
			conn, helper := net.Pipe()
			defer conn.Close()
			defer helper.Close()
			id := uid()
			go func() {
				// The helper side drains playout frames like the Manager relay.
				var last uint64
				for {
					if _, _, e := media.ReadFrame(helper, id, 1, &last); e != nil {
						return
					}
				}
			}()
			switch kind {
			case "rtp_closed":
				close(track.closed)
			case "local_read_closed":
				helper.Close()
			case "local_invalid_frame":
				go media.WriteFrame(helper, id, 2, media.Frame{Sequence: 1, Flags: media.FlagErasure})
			case "ice_failed":
				peer.Close()
			case "media_cancelled":
				cancel()
			}
			reason := streamMedia(ctx, cancel, peer, localMedia{conn: conn, id: id}, &bridgeCounters{}, connected(track))
			// A closed helper socket fails playout writes as well as capture reads.
			if reason != kind && !(kind == "local_read_closed" && reason == "local_write_closed") {
				t.Fatalf("got %s want %s", reason, kind)
			}
		})
	}
}

func TestStreamMediaMovesBothDirections(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	peer, track := newFakePeer(), newFakeTrack()
	conn, helper := net.Pipe()
	defer helper.Close()
	id := uid()
	counts := &bridgeCounters{}
	done := make(chan string, 1)
	go func() {
		done <- streamMedia(ctx, cancel, peer, localMedia{conn: conn, id: id}, counts, connected(track))
	}()
	for i := byte(1); i <= 3; i++ {
		track.packets <- []byte{0x78, i}
	}
	var last uint64
	var got []media.Frame
	for len(got) < 3 {
		helper.SetReadDeadline(time.Now().Add(time.Second))
		f, _, e := media.ReadFrame(helper, id, 1, &last)
		if e != nil {
			t.Fatal(e)
		}
		if len(got) > 0 || f.Flags != media.FlagErasure {
			got = append(got, f)
		}
	}
	for i, f := range got {
		if f.Flags != media.FlagOpus || f.Payload[1] != byte(i+1) {
			t.Fatalf("frame %d %+v", i, f)
		}
	}
	for seq := uint64(1); seq <= 2; seq++ {
		if e := media.WriteFrame(helper, id, 2, media.Frame{Sequence: seq, Payload: []byte{0x78, 0xaa}}); e != nil {
			t.Fatal(e)
		}
	}
	deadline := time.Now().Add(time.Second)
	for peer.sent() < 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if peer.sent() != 2 || counts.sent.Load() != 2 || counts.received.Load() != 3 {
		t.Fatal("packets not forwarded")
	}
	cancel()
	if reason := <-done; reason != "media_cancelled" {
		t.Fatal(reason)
	}
}

func connected(track rtcTrack) func() (rtcTrack, string) {
	return func() (rtcTrack, string) { return track, "" }
}

// While ICE connects the helper keeps receiving erasures, so the Manager does
// not end the session, and its capture is dropped instead of sent late.
func TestStreamMediaServesHelperBeforeConnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	peer, track := newFakePeer(), newFakeTrack()
	conn, helper := net.Pipe()
	defer helper.Close()
	id := uid()
	release := make(chan struct{})
	done := make(chan string, 1)
	go func() {
		done <- streamMedia(ctx, cancel, peer, localMedia{conn: conn, id: id}, &bridgeCounters{}, func() (rtcTrack, string) {
			<-release
			return track, ""
		})
	}()
	var last uint64
	for i := 0; i < 5; i++ {
		helper.SetReadDeadline(time.Now().Add(time.Second))
		f, _, e := media.ReadFrame(helper, id, 1, &last)
		if e != nil || f.Flags != media.FlagErasure {
			t.Fatalf("frame %d %+v %v", i, f, e)
		}
	}
	if e := media.WriteFrame(helper, id, 2, media.Frame{Sequence: 1, Payload: []byte{0x78, 1}}); e != nil {
		t.Fatal(e)
	}
	close(release)
	go func() {
		// Keep draining playout so the writer is never blocked on the pipe.
		for {
			if _, _, e := media.ReadFrame(helper, id, 1, &last); e != nil {
				return
			}
		}
	}()
	deadline := time.Now().Add(time.Second)
	for seq := uint64(2); peer.sent() == 0 && time.Now().Before(deadline); seq++ {
		if e := media.WriteFrame(helper, id, 2, media.Frame{Sequence: seq, Payload: []byte{0x78, byte(seq)}}); e != nil {
			t.Fatal(e)
		}
	}
	peer.mu.Lock()
	written := peer.written
	peer.mu.Unlock()
	if len(written) == 0 || written[0][1] == 1 {
		t.Fatalf("sent %v", written)
	}
	cancel()
	if reason := <-done; reason != "media_cancelled" {
		t.Fatal(reason)
	}
}

func TestRTPTimeoutReason(t *testing.T) {
	if rtpReason(os.ErrDeadlineExceeded) != "rtp_timeout" || rtpReason(errors.New("x")) != "rtp_closed" {
		t.Fatal("rtp reason")
	}
}
