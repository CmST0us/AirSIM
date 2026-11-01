package cloud

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// relayStart is a media_start the Agent answers through the loopback relay.
func relayStart(t *testing.T, fc *fakeControl, o owner, offer, address, username string) []byte {
	t.Helper()
	r := testMediaStart(fc, time.Now().Add(15*time.Second))
	r.Client, r.Generation, r.Offer = o.client, o.generation, offer
	r.Servers = []json.RawMessage{json.RawMessage(fmt.Sprintf(`{"urls":["turn:%s?transport=udp"],"username":%q,"credential":"secret"}`, address, username))}
	b, _ := json.Marshal(r)
	return b
}

// sentAnswer waits for the media_answer the connection queued for the signaling path.
func sentAnswer(t *testing.T, ctx context.Context, c *connection) string {
	t.Helper()
	for {
		select {
		case out := <-c.queue:
			if out.kind != "media_answer" {
				continue
			}
			b, _ := json.Marshal(out.payload)
			var v struct {
				Answer string `json:"answer"`
			}
			if json.Unmarshal(b, &v) != nil {
				t.Fatal("answer payload")
			}
			return v.Answer
		case <-ctx.Done():
			t.Fatal("no media answer")
		}
	}
}

func TestMediaOutlivesControlAndNewerSessionReplaces(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, fc := testConnection(t)
	c.life = ctx
	a := c.agent
	fm := a.Media.(*fakeMedia)
	played := helperSocket(t, ctx, fm)
	o := owner{fc.call, uid(), uid(), fc.boot, fc.epoch}
	a.owners[fc.call] = o
	username := fmt.Sprintf("%d:%s:agent", time.Now().Add(time.Hour).Unix(), uid())
	address, _ := relay(t, username, "secret")

	first := newTestApp(t)
	if !c.startMedia(relayStart(t, fc, o, first.offer, address, username)) {
		t.Fatal("first media_start rejected")
	}
	first.accept(t, ctx, sentAnswer(t, ctx, c))
	expectDuplex(t, ctx, first, played)
	session := a.LastBridgeStats().SessionID

	// The control connection drops; the WebRTC path does not cross it.
	c.cancel()
	time.Sleep(300 * time.Millisecond)
	for len(first.received) > 0 {
		<-first.received
	}
	select {
	case <-first.received:
	case <-time.After(2 * time.Second):
		t.Fatal("media stopped with the control connection")
	}
	if s := a.LastBridgeStats(); s.SessionID != session || s.State != "streaming" {
		t.Fatal("media did not survive", s)
	}

	// After reconnecting, the App replaces the session it lost.
	next, _ := testConnection(t)
	next.agent, next.owners, next.life = a, a.owners, ctx
	second := newTestApp(t)
	if !next.startMedia(relayStart(t, fc, o, second.offer, address, username)) {
		t.Fatal("replacement media_start rejected")
	}
	second.accept(t, ctx, sentAnswer(t, ctx, next))
	expectDuplex(t, ctx, second, played)
	if s := a.LastBridgeStats(); s.SessionID == session || s.State != "streaming" {
		t.Fatal("newer session not current", s)
	}
	if fm.stops.Load() != 1 || fm.creates.Load() != 2 {
		t.Fatal("older helper not released before the newer started", fm.stops.Load(), fm.creates.Load())
	}
	cancel()
	a.media.Wait()
}
