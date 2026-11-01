// Package media runs the TURN relay that carries WebRTC call media between the
// App and the Agent. Media stays DTLS-SRTP encrypted end to end; the relay only
// forwards packets for holders of an unexpired session credential.
package media

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"airsim.local/server/internal/ice"
	"github.com/pion/logging"
	"github.com/pion/stun/v3"
	"github.com/pion/turn/v4"
)

type Config struct {
	Secret string
	// PublicIP is the address peers reach the relay at; the host's interfaces
	// only carry its private address.
	PublicIP net.IP
	Listen   string
}

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// PeerAllowed keeps relays from reaching the host's private networks, loopback
// and the cloud metadata range. The relay's own public address stays reachable
// so two relayed peers can meet.
func PeerAllowed(ip net.IP) bool {
	return ip.To4() != nil && ip.IsGlobalUnicast() && !ip.IsPrivate() && !cgnat.Contains(ip)
}

func authenticate(secret string) turn.AuthHandler {
	return func(username, realm string, _ net.Addr) ([]byte, bool) {
		if realm != ice.Realm || !ice.Valid(username, time.Now()) {
			return nil, false
		}
		return turn.GenerateAuthKey(username, realm, ice.Password(secret, username)), true
	}
}

// session strips the expiry so logs identify the session and role only.
func session(username string) string {
	if _, rest, ok := strings.Cut(username, ":"); ok {
		return rest
	}
	return "unknown"
}

func Serve(ctx context.Context, c Config) error {
	if c.Secret == "" || c.PublicIP.To4() == nil {
		return errors.New("turn_config_invalid")
	}
	udp, e := net.ListenPacket("udp4", net.JoinHostPort(c.Listen, fmt.Sprint(ice.Port)))
	if e != nil {
		return e
	}
	tcp, e := net.Listen("tcp4", net.JoinHostPort(c.Listen, fmt.Sprint(ice.Port)))
	if e != nil {
		udp.Close()
		return e
	}
	relay := func() turn.RelayAddressGenerator {
		return &turn.RelayAddressGeneratorPortRange{RelayAddress: c.PublicIP, Address: c.Listen, MinPort: ice.MinRelay, MaxPort: ice.MaxRelay}
	}
	permit := func(_ net.Addr, peer net.IP) bool { return PeerAllowed(peer) }
	loggers := logging.NewDefaultLoggerFactory()
	loggers.DefaultLogLevel = logging.LogLevelError
	s, e := turn.NewServer(turn.ServerConfig{
		Realm:         ice.Realm,
		AuthHandler:   authenticate(c.Secret),
		LoggerFactory: loggers,
		EventHandler: turn.EventHandler{
			OnAllocationCreated: func(_, _ net.Addr, protocol, username, _ string, address net.Addr, _ int) {
				log.Printf("relay_allocated session=%s protocol=%s relay=%s", session(username), protocol, address)
			},
			OnAllocationDeleted: func(_, _ net.Addr, protocol, username, _ string) {
				log.Printf("relay_released session=%s protocol=%s", session(username), protocol)
			},
		},
		PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: udp, RelayAddressGenerator: relay(), PermissionHandler: permit}},
		ListenerConfigs:   []turn.ListenerConfig{{Listener: tcp, RelayAddressGenerator: relay(), PermissionHandler: permit}},
	})
	if e != nil {
		udp.Close()
		tcp.Close()
		return e
	}
	<-ctx.Done()
	return s.Close()
}

// Healthy sends a STUN binding request to the local relay.
func Healthy(addr string) bool {
	c, e := net.Dial("udp4", addr)
	if e != nil {
		return false
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	request := stun.MustBuild(stun.TransactionID, stun.BindingRequest)
	if _, e = c.Write(request.Raw); e != nil {
		return false
	}
	b := make([]byte, 1500)
	n, e := c.Read(b)
	if e != nil {
		return false
	}
	response := &stun.Message{Raw: b[:n]}
	return response.Decode() == nil && response.Type == stun.BindingSuccess && response.TransactionID == request.TransactionID
}
