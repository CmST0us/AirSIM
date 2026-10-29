package ofono

import (
	"airsim.local/airsim-agent/internal/hal"
	"github.com/godbus/dbus/v5"
	"sync"
	"sync/atomic"
)

// SignalQueue is used with a private connection's WithSignalHandler. It never
// spawns delivery goroutines and never closes the channel a delivery can target.
type SignalQueue struct {
	mu         sync.Mutex
	normalize  func(*dbus.Signal) hal.ControlEvent
	output     chan hal.ControlEvent
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
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.normalize != nil {
		q.deliverNormalized(s)
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

func (q *SignalQueue) deliverNormalized(s *dbus.Signal) {
	e := q.normalize(s)
	if e.Kind == "" {
		return
	}
	select {
	case q.output <- e:
	default:
		q.dropped.Add(1)
		select {
		case q.Overflow <- struct{}{}:
		default:
		}
	}
}
func (q *SignalQueue) normalized(convert func(*dbus.Signal) hal.ControlEvent) chan hal.ControlEvent {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.normalize = convert
	q.output = make(chan hal.ControlEvent, 128)
	for len(q.Events) > 0 {
		q.deliverNormalized(<-q.Events)
	}
	return q.output
}
