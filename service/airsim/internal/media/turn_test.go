package media

import (
	"context"
	"net"
	"testing"
	"time"

	"airsim.local/server/internal/ice"
	"airsim.local/server/internal/wire"
	"github.com/pion/turn/v4"
)

func TestPeerAllowed(t *testing.T) {
	for ip, want := range map[string]bool{
		"120.25.235.237":  true,
		"8.8.8.8":         true,
		"127.0.0.1":       false,
		"10.1.2.3":        false,
		"172.27.242.60":   false,
		"192.168.225.1":   false,
		"100.100.100.200": false,
		"169.254.1.1":     false,
		"0.0.0.0":         false,
		"224.0.0.1":       false,
		"2001:db8::1":     false,
	} {
		if PeerAllowed(net.ParseIP(ip)) != want {
			t.Fatalf("%s want %v", ip, want)
		}
	}
}

func TestRelayAuthenticatesSessionCredentials(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() {
		served <- Serve(ctx, Config{Secret: "secret", PublicIP: net.IPv4(127, 0, 0, 1), Listen: "127.0.0.1"})
	}()
	defer func() {
		cancel()
		if e := <-served; e != nil {
			t.Error(e)
		}
	}()
	address := "127.0.0.1:3478"
	deadline := time.Now().Add(2 * time.Second)
	for !Healthy(address) {
		if time.Now().After(deadline) {
			t.Fatal("relay not serving")
		}
		time.Sleep(20 * time.Millisecond)
	}
	server := ice.Servers("secret", "127.0.0.1", wire.ID(), "client", time.Now())[0]
	allocate := func(username, password string) error {
		conn, e := net.ListenPacket("udp4", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		defer conn.Close()
		c, e := turn.NewClient(&turn.ClientConfig{TURNServerAddr: address, Username: username, Password: password, Realm: ice.Realm, Conn: conn, RTO: 100 * time.Millisecond})
		if e != nil {
			t.Fatal(e)
		}
		defer c.Close()
		if e = c.Listen(); e != nil {
			t.Fatal(e)
		}
		relay, e := c.Allocate()
		if e == nil {
			port := relay.LocalAddr().(*net.UDPAddr).Port
			if port < ice.MinRelay || port > ice.MaxRelay {
				t.Fatalf("relay port %d", port)
			}
			relay.Close()
		}
		return e
	}
	if e := allocate(server.Username, server.Credential); e != nil {
		t.Fatalf("valid credential rejected: %v", e)
	}
	if allocate(server.Username, ice.Password("other", server.Username)) == nil {
		t.Fatal("wrong secret accepted")
	}
	expired := ice.Servers("secret", "127.0.0.1", wire.ID(), "agent", time.Now().Add(-ice.Lifetime))[0]
	if allocate(expired.Username, expired.Credential) == nil {
		t.Fatal("expired credential accepted")
	}
}
