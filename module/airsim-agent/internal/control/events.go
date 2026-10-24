package control

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/ofono"
	"context"
	"github.com/godbus/dbus/v5"
	"strings"
	"sync"
	"time"
)

// Run owns every mutable control field. Workers receive immutable jobs and must
// receive a completion acknowledgment before taking the next job.
func (c *Coordinator) Run(ctx context.Context) {
	defer close(c.done)
	defer close(c.audioEvents)
	lifetime, cancel := context.WithCancel(context.Background())
	defer cancel()
	connections := make(chan connected, 1)
	snapshots := make(chan synced, 1)
	var wg sync.WaitGroup
	wg.Add(2)
	go c.worker(c.callsQueue, &wg)
	go c.worker(c.smsQueue, &wg)
	workersDone := make(chan struct{})
	go func() { wg.Wait(); close(workersDone) }()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	retry := time.NewTimer(0)
	defer retry.Stop()
	retryC := retry.C
	delays := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second}
	attempt := 0
	stopping := ctx.Done()
	connecting := false
	synchronizing := false
	var connectionCancel context.CancelFunc
	disconnect := func(reason string) {
		if connectionCancel != nil {
			connectionCancel()
			connectionCancel = nil
		}
		c.lose(reason)
		synchronizing = false
		if !c.stopping {
			retry.Reset(delays[attempt])
			retryC = retry.C
			if attempt < len(delays)-1 {
				attempt++
			}
		}
	}
	for {
		var events <-chan *dbus.Signal
		var overflow, lost <-chan struct{}
		if c.backend != nil {
			overflow = c.backend.Queue.Overflow
			lost = c.backend.Queue.Done
			if !synchronizing {
				events = c.backend.Queue.Events
			}
		}
		select {
		case <-stopping:
			stopping = nil
			c.stopping = true
			c.ready = false
			c.reason = "stopping"
			retryC = nil
			for _, j := range c.pending {
				if j.record.State == "prepared" {
					c.finishState(j, "failed", "stopping")
				}
			}
			close(c.callsQueue)
			close(c.smsQueue)
			if c.backend == nil && connectionCancel != nil {
				connectionCancel()
			}
		case <-workersDone:
			if c.stopping {
				if c.backend != nil {
					c.backend.Close()
				}
				if connectionCancel != nil {
					connectionCancel()
				}
				return
			}
		case <-retryC:
			retryC = nil
			if connecting || c.stopping {
				continue
			}
			connecting = true
			connectCtx, stop := context.WithCancel(lifetime)
			connectionCancel = stop
			go func() {
				s, e := ofono.Connect(connectCtx)
				select {
				case connections <- connected{s, e}:
				case <-lifetime.Done():
					if s != nil {
						s.Close()
					}
				}
			}()
		case result := <-connections:
			connecting = false
			if c.stopping {
				if result.session != nil {
					result.session.Close()
				}
				continue
			}
			if result.err != nil {
				disconnect("backend_unavailable")
				continue
			}
			c.backend = result.session
			c.executor = result.session
			c.ready = false
			c.reason = "synchronizing"
			if c.everConnected {
				c.gap = true
			}
			c.everConnected = true
			c.dialReservation = ""
			// IDs never transfer to a new epoch, including a path reused after recovery.
			c.calls = map[string]*Call{}
			c.callObjects = map[string]string{}
			c.ended = nil
			c.tombs = nil
			c.messageObjects = map[string]string{}
			synchronizing = true
			s := result.session
			startDropped := s.Queue.Dropped()
			go func() {
				snapshot, e := s.Snapshot(lifetime)
				select {
				case snapshots <- synced{snapshot, e, s.Epoch, startDropped}:
				case <-lifetime.Done():
				}
			}()
		case result := <-snapshots:
			if c.backend == nil || c.epoch() != result.epoch || c.stopping {
				continue
			}
			if result.err != nil || c.backend.Queue.Dropped() != result.dropped {
				disconnect("snapshot_failed")
				continue
			}
			c.applySnapshot(result.snapshot)
			synchronizing = false
			// Buffered pre-snapshot signals are reconciled using response sequence.
			c.drainSignals(result.snapshot.CallSequence, result.snapshot.MessageSequence)
			if c.backend != nil && c.reason == "synchronizing" {
				c.ready = true
				c.reason = ""
				attempt = 0
			}
			if c.backend != nil && !c.ready {
				disconnect(c.reason)
			}
		case <-overflow:
			disconnect("signal_overflow")
		case <-lost:
			disconnect("backend_lost")
		case s := <-events:
			if !c.signal(s, 0, 0) {
				disconnect("backend_changed")
			}
		case r := <-c.api:
			c.checkSignals()
			c.handleAPI(r)
			if c.backend != nil && !synchronizing && !c.ready && !c.stopping {
				disconnect(c.reason)
			}
		case b := <-c.begin:
			c.checkSignals()
			c.beginJob(b)
			if c.backend != nil && !synchronizing && !c.ready && !c.stopping {
				disconnect(c.reason)
			}
		case result := <-c.results:
			c.checkSignals()
			c.complete(result)
			if c.backend != nil && !synchronizing && !c.ready && !c.stopping {
				disconnect(c.reason)
			}
		case <-ticker.C:
			c.observe()
		}
		c.publishAudio()
	}
}

func (c *Coordinator) lose(reason string) {
	c.ready = false
	c.reason = reason
	if c.backend != nil {
		c.dropped += c.backend.Queue.Dropped()
		c.backend.Close()
		c.gap = true
	}
	for _, j := range c.pending {
		if j.record.State == "dispatched" {
			c.finishState(j, "outcome_unknown", "backend_lost")
		} else {
			c.finishState(j, "failed", "backend_lost")
		}
	}
	c.backend = nil
	c.executor = nil
	c.watch = nil
}
func (c *Coordinator) applySnapshot(s hal.ControlSnapshot) {
	c.emergency = append([]string(nil), s.EmergencyNumbers...)
	c.emergencySequence = s.EmergencySequence
	for _, call := range s.Calls {
		c.ensureCall(call.Object, call.State, call.Number, "unmanaged")
	}
	for _, message := range s.Messages {
		m := c.ensureMessage(message.Object)
		m.State = messageState(message.State)
	}
}
func (c *Coordinator) checkSignals() {
	if c.backend == nil || c.reason == "synchronizing" {
		return
	}
	if c.backend.Queue.Dropped() != 0 {
		c.ready = false
		c.reason = "signal_overflow"
		return
	}
	select {
	case <-c.backend.Queue.Done:
		c.ready = false
		c.reason = "backend_lost"
		return
	default:
	}
	c.drainSignals(0, 0)
}
func (c *Coordinator) drainSignals(callSequence, messageSequence uint64) {
	if c.backend == nil {
		return
	}
	// A finite snapshot of channel occupancy prevents a noisy peer starving APIs.
	n := len(c.backend.Queue.Events)
	for i := 0; i < n; i++ {
		s := <-c.backend.Queue.Events
		if !c.signal(s, callSequence, messageSequence) {
			c.ready = false
			c.reason = "backend_changed"
			return
		}
	}
}
func (c *Coordinator) signal(s *dbus.Signal, callSequence, messageSequence uint64) bool {
	if c.backend == nil || !c.backend.ValidSignal(s) {
		return true
	}
	switch s.Name {
	case "org.freedesktop.DBus.NameOwnerChanged":
		if len(s.Body) != 3 {
			return true
		}
		name, _ := s.Body[0].(string)
		old, _ := s.Body[1].(string)
		next, _ := s.Body[2].(string)
		return name != "org.ofono" || (old != c.backend.Owner && next == c.backend.Owner)
	case "org.ofono.Manager.ModemAdded", "org.ofono.Manager.ModemRemoved":
		return false
	case "org.ofono.Modem.PropertyChanged":
		if s.Path != c.backend.Modem {
			return true
		}
		key, v, ok := property(s)
		if !ok {
			return false
		}
		switch key {
		case "Powered", "Online":
			b, ok := v.Value().(bool)
			return ok && b
		case "Interfaces":
			return ofono.InterfacesReady(map[string]dbus.Variant{"Interfaces": v})
		}
		return true
	case "org.ofono.VoiceCallManager.PropertyChanged":
		if s.Path != c.backend.Modem {
			return true
		}
		key, v, ok := property(s)
		if !ok {
			return true
		}
		if key == "EmergencyNumbers" {
			if uint64(s.Sequence) <= c.emergencySequence {
				return true
			}
			numbers, ok := v.Value().([]string)
			if !ok {
				return false
			}
			c.emergency = append([]string(nil), numbers...)
		}
		return true
	}
	if strings.HasPrefix(s.Name, "org.ofono.VoiceCall") && uint64(s.Sequence) <= callSequence {
		return true
	}
	if (s.Name == "org.ofono.MessageManager.MessageAdded" || s.Name == "org.ofono.MessageManager.MessageRemoved" || s.Name == "org.ofono.MessageManager.MessageState" || strings.HasPrefix(s.Name, "org.ofono.Message.")) && uint64(s.Sequence) <= messageSequence {
		return true
	}
	switch s.Name {
	case "org.ofono.VoiceCallManager.CallAdded":
		object, p, ok := objectProperties(s)
		if !ok || s.Path != c.backend.Modem || !c.childObject(object) {
			return true
		}
		c.eventSerial++
		state := ofono.String(p, "State")
		ownership := "unmanaged"
		if state == "incoming" || state == "waiting" {
			ownership = "incoming"
		}
		c.ensureCall(object, state, ofono.String(p, "LineIdentification"), ownership)
	case "org.ofono.VoiceCallManager.CallRemoved":
		object, ok := oneObject(s)
		if ok && s.Path == c.backend.Modem && c.childObject(object) {
			c.endCall(object)
		}
	case "org.ofono.VoiceCall.PropertyChanged":
		call := c.calls[c.callObjects[string(s.Path)]]
		if call == nil {
			return true
		}
		key, v, ok := property(s)
		if !ok {
			return true
		}
		value, _ := v.Value().(string)
		switch key {
		case "State":
			call.State = callState(value)
		case "LineIdentification":
			call.Number = value
		}
		call.Observed = time.Now().UTC()
		c.observe()
	case "org.ofono.VoiceCall.DisconnectReason":
		call := c.calls[c.callObjects[string(s.Path)]]
		if call != nil && len(s.Body) == 1 {
			value, _ := s.Body[0].(string)
			switch value {
			case "local", "remote", "network":
				call.DisconnectReason = value
			default:
				call.DisconnectReason = "unknown"
			}
		}
	case "org.ofono.MessageManager.MessageAdded", "org.ofono.MessageManager.MessageState":
		object, p, ok := objectProperties(s)
		if ok && s.Path == c.backend.Modem && c.childObject(object) {
			if s.Name == "org.ofono.MessageManager.MessageAdded" {
				for _, old := range c.messages {
					if old.ID == c.messageObjects[object] && old.removed {
						delete(c.messageObjects, object)
						break
					}
				}
			}
			m := c.ensureMessage(object)
			m.State = messageState(ofono.String(p, "State"))
			m.Observed = time.Now().UTC()
		}
	case "org.ofono.Message.PropertyChanged":
		id := c.messageObjects[string(s.Path)]
		key, v, ok := property(s)
		if ok && key == "State" {
			for _, m := range c.messages {
				if m.ID == id {
					value, _ := v.Value().(string)
					m.State = messageState(value)
					m.Observed = time.Now().UTC()
				}
			}
		}
	case "org.ofono.MessageManager.MessageRemoved":
		object, ok := oneObject(s)
		if ok && s.Path == c.backend.Modem {
			for _, m := range c.messages {
				if m.ID == c.messageObjects[object] {
					m.removed = true
				}
			}
		} // Preserve association for a method reply that arrives after removal.
	case "org.ofono.MessageManager.IncomingMessage", "org.ofono.MessageManager.ImmediateMessage":
		if s.Path != c.backend.Modem || len(s.Body) != 2 {
			return true
		}
		text, ok := s.Body[0].(string)
		props, ok2 := s.Body[1].(map[string]dbus.Variant)
		if ok && ok2 {
			c.incoming(text, props)
		}
	}
	return true
}
func (c *Coordinator) childObject(object string) bool {
	return dbus.ObjectPath(object).IsValid() && strings.HasPrefix(object, string(c.backend.Modem)+"/")
}
func property(s *dbus.Signal) (string, dbus.Variant, bool) {
	if len(s.Body) != 2 {
		return "", dbus.Variant{}, false
	}
	key, ok := s.Body[0].(string)
	value, ok2 := s.Body[1].(dbus.Variant)
	return key, value, ok && ok2
}
func objectProperties(s *dbus.Signal) (string, map[string]dbus.Variant, bool) {
	if len(s.Body) != 2 {
		return "", nil, false
	}
	object, ok := s.Body[0].(dbus.ObjectPath)
	props, ok2 := s.Body[1].(map[string]dbus.Variant)
	return string(object), props, ok && ok2
}
func oneObject(s *dbus.Signal) (string, bool) {
	if len(s.Body) != 1 {
		return "", false
	}
	object, ok := s.Body[0].(dbus.ObjectPath)
	return string(object), ok
}
