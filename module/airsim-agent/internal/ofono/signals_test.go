package ofono

import (
	"github.com/godbus/dbus/v5"
	"sync"
	"testing"
)

func TestBoundedSignalDelivery(t *testing.T) {
	q := NewSignalQueue()
	for i := 0; i < 10000; i++ {
		q.DeliverSignal("org.ofono.VoiceCall", "PropertyChanged", &dbus.Signal{})
	}
	if len(q.Events) != 128 || q.Dropped() != 9872 || len(q.Overflow) != 1 {
		t.Fatal("unbounded or unreported overflow")
	}
}
func TestTerminateConcurrentDelivery(t *testing.T) {
	q := NewSignalQueue()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				q.DeliverSignal("org.ofono.MessageManager", "IncomingMessage", &dbus.Signal{})
			}
		}()
	}
	q.Terminate()
	q.Terminate()
	wg.Wait()
	select {
	case <-q.Done:
	default:
		t.Fatal("not terminated")
	}
}
