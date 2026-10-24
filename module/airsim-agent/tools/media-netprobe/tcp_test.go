package main

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

func TestTCPCollector(t *testing.T) {
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal("listen")
	}
	defer listener.Close()
	peer := make(chan net.Conn, 1)
	go func() {
		c, e := listener.Accept()
		if e == nil {
			peer <- c
		}
	}()
	tracker := &tcpTracker{}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, e := tracker.dial(ctx, "tcp", listener.Addr().String())
	if e != nil {
		t.Fatal("dial")
	}
	defer c.Close()
	other := <-peer
	defer other.Close()
	stop := tracker.collect(ctx)
	time.Sleep(1100 * time.Millisecond)
	samples := stop()
	if len(samples) != 1 || samples[0].LocalPort != c.LocalAddr().(*net.TCPAddr).Port || samples[0].ElapsedMS < 950 || samples[0].ElapsedMS > 1300 {
		t.Fatal("sample cadence/port")
	}
	b, _ := json.Marshal(samples)
	if strings.Contains(string(b), "127.0.0.1") {
		t.Fatal("address exposed")
	}
}
