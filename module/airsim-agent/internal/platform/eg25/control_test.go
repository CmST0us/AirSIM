package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"context"
	"sync/atomic"
	"testing"
	"time"
)

type ringingPort struct {
	polls atomic.Int32
	done  chan struct{}
}

func (p *ringingPort) Done() <-chan struct{}                                     { return p.done }
func (p *ringingPort) Command(context.Context, string, string) ([]string, error) { return nil, nil }
func (p *ringingPort) Query(_ context.Context, cmd string) ([]string, error) {
	if cmd != "AT+CLCC" {
		return nil, at.ErrInvalid
	}
	if p.polls.Add(1) <= 6 {
		return nil, at.ErrQuery
	}
	return []string{`+CLCC: 3,1,4,0,0`}, nil
}
func TestRingingTransientDoesNotReplaceControlEpoch(t *testing.T) {
	p := &ringingPort{done: make(chan struct{})}
	s, err := Connect(context.Background(), p, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	epoch := s.EpochID()
	select {
	case e := <-s.Events():
		if e.Kind != "call.add" || e.State != "incoming" || s.EpochID() != epoch {
			t.Fatal("ringing identity lost")
		}
	case <-s.Done():
		t.Fatal("transient CLCC error disconnected backend")
	case <-time.After(10 * time.Second):
		t.Fatal("incoming event not delivered")
	}
}
