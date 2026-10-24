package ofono

import (
	"github.com/godbus/dbus/v5"
	"sync"
	"sync/atomic"
)

// SignalQueue is used with a private connection's WithSignalHandler. It never
// spawns delivery goroutines and never closes the channel a delivery can target.
type SignalQueue struct {
	Events     chan *dbus.Signal
	Overflow   chan struct{}
	Done       chan struct{}
	dropped    atomic.Uint64
	terminated atomic.Bool
	once       sync.Once
}

func NewSignalQueue() *SignalQueue {
	return &SignalQueue{Events: make(chan *dbus.Signal, 128), Overflow: make(chan struct{}, 1), Done: make(chan struct{})}
}
func (q *SignalQueue) DeliverSignal(iface, name string, s *dbus.Signal) {
	if q.terminated.Load() || s == nil {
		return
	}
	switch iface {
	case "org.freedesktop.DBus":
		if name != "NameOwnerChanged" {
			return
		}
	case "org.ofono.Manager", "org.ofono.Modem", "org.ofono.VoiceCallManager", "org.ofono.VoiceCall", "org.ofono.MessageManager", "org.ofono.Message":
	default:
		return
	}
	select {
	case q.Events <- s:
	default:
		q.dropped.Add(1)
		select {
		case q.Overflow <- struct{}{}:
		default:
		}
	}
}
func (q *SignalQueue) Terminate()      { q.once.Do(func() { q.terminated.Store(true); close(q.Done) }) }
func (q *SignalQueue) Dropped() uint64 { return q.dropped.Load() }
