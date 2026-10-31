package main

import (
	"context"
	"net"
	"sync"
	"time"
)

type tcpSample struct {
	ElapsedMS    int64   `json:"elapsed_ms"`
	LocalPort    int     `json:"local_port"`
	Available    bool    `json:"tcp_info_available"`
	RTT          *uint32 `json:"rtt_us,omitempty"`
	RTO          *uint32 `json:"rto_us,omitempty"`
	SndCwnd      *uint32 `json:"snd_cwnd,omitempty"`
	Unacked      *uint32 `json:"unacked,omitempty"`
	TotalRetrans *uint32 `json:"total_retrans,omitempty"`
}
type tcpTracker struct {
	mu   sync.Mutex
	conn *net.TCPConn
}

func (t *tcpTracker) dial(ctx context.Context, network, address string) (net.Conn, error) {
	c, e := (&net.Dialer{}).DialContext(ctx, network, address)
	if e == nil {
		if tcp, ok := c.(*net.TCPConn); ok {
			t.mu.Lock()
			t.conn = tcp
			t.mu.Unlock()
		}
	}
	return c, e
}

// The collector retains at most 45 one-second samples and never prints addresses.
func (t *tcpTracker) collect(parent context.Context) func() []tcpSample {
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	samples := make([]tcpSample, 0, 45)
	start := time.Now()
	go func() {
		defer close(done)
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				t.mu.Lock()
				c := t.conn
				t.mu.Unlock()
				if c == nil || len(samples) >= 45 {
					continue
				}
				s := readTCPInfo(c)
				s.ElapsedMS = time.Since(start).Milliseconds()
				if addr, ok := c.LocalAddr().(*net.TCPAddr); ok {
					s.LocalPort = addr.Port
				}
				samples = append(samples, s)
			}
		}
	}()
	return func() []tcpSample { cancel(); <-done; return samples }
}
