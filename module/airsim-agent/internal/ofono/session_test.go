package ofono

import (
	"context"
	"github.com/godbus/dbus/v5"
	"net"
	"testing"
	"time"
)

func TestHandshakeCancellationClosesBlockedAuth(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := handshake(ctx, a, NewSignalQueue()); done <- err }()
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("authentication unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("authentication ignored cancellation")
	}
}
func TestManagerAndOwnerSignalFiltering(t *testing.T) {
	s := &Session{Owner: ":1.2", Modem: "/modem"}
	for _, tc := range []struct {
		sender, path, name string
		valid              bool
	}{{":1.2", "/", "org.ofono.Manager.ModemRemoved", true}, {":1.3", "/", "org.ofono.Manager.ModemRemoved", false}, {":1.2", "/other", "org.ofono.Modem.PropertyChanged", false}, {":1.2", "/modem/call1", "org.ofono.VoiceCall.PropertyChanged", true}} {
		signal := &dbus.Signal{Sender: tc.sender, Path: dbus.ObjectPath(tc.path), Name: tc.name}
		if s.ValidSignal(signal) != tc.valid {
			t.Fatal(tc.name)
		}
	}
}
