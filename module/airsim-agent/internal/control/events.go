package control

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/ofono"
	"context"
	"strings"
	"sync"
	"time"
)

// Run owns every mutable control field. Workers receive immutable jobs and must
// receive a completion acknowledgment before taking the next job.
func (c *Coordinator) Run(ctx context.Context) {
	c.RunWithBackend(ctx, func(ctx context.Context) (hal.ControlSession, error) {
		s, err := ofono.Connect(ctx)
		if err != nil {
			return nil, err
		}
		return s, nil
	})
}
func (c *Coordinator) RunWithBackend(ctx context.Context, connect func(context.Context) (hal.ControlSession, error)) {
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
		var events <-chan hal.ControlEvent
		var overflow, lost <-chan struct{}
		if c.backend != nil {
			overflow = c.backend.Overflow()
			lost = c.backend.Done()
			if !synchronizing {
				events = c.backend.Events()
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
				s, e := connect(connectCtx)
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
			startDropped := s.Dropped()
			go func() {
				snapshot, e := s.Snapshot(lifetime)
				select {
				case snapshots <- synced{snapshot, e, s.EpochID(), startDropped}:
				case <-lifetime.Done():
				}
			}()
		case result := <-snapshots:
			if c.backend == nil || c.epoch() != result.epoch || c.stopping {
				continue
			}
			if result.err != nil || c.backend.Dropped() != result.dropped {
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
			if !c.event(s, 0, 0) {
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
		c.dropped += c.backend.Dropped()
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
	if c.backend.Dropped() != 0 {
		c.ready = false
		c.reason = "signal_overflow"
		return
	}
	select {
	case <-c.backend.Done():
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
	n := len(c.backend.Events())
	for i := 0; i < n; i++ {
		s := <-c.backend.Events()
		if !c.event(s, callSequence, messageSequence) {
			c.ready = false
			c.reason = "backend_changed"
			return
		}
	}
}
func (c *Coordinator) event(e hal.ControlEvent, callSequence, messageSequence uint64) bool {
	if c.backend == nil {
		return true
	}
	if e.Kind == "backend.changed" {
		return false
	}
	if e.Kind == "emergency" {
		if e.Sequence > c.emergencySequence {
			c.emergency = append([]string(nil), e.EmergencyNumbers...)
			c.emergencySequence = e.Sequence
		}
		return true
	}
	if strings.HasPrefix(e.Kind, "call.") && e.Sequence <= callSequence {
		return true
	}
	if strings.HasPrefix(e.Kind, "message.") && e.Kind != "message.incoming" && e.Sequence <= messageSequence {
		return true
	}
	switch e.Kind {
	case "call.add":
		c.eventSerial++
		ownership := "unmanaged"
		if e.State == "incoming" || e.State == "waiting" {
			ownership = "incoming"
		}
		c.ensureCall(e.Object, e.State, e.Number, ownership)
	case "call.remove":
		c.endCall(e.Object)
	case "call.state", "call.number", "call.reason":
		if call := c.calls[c.callObjects[e.Object]]; call != nil {
			switch e.Kind {
			case "call.state":
				call.State = callState(e.State)
			case "call.number":
				call.Number = e.Number
			case "call.reason":
				switch e.Reason {
				case "local", "remote", "network":
					call.DisconnectReason = e.Reason
				default:
					call.DisconnectReason = "unknown"
				}
			}
			call.Observed = time.Now().UTC()
			c.observe()
		}
	case "message.add", "message.state":
		if e.Kind == "message.add" {
			for _, old := range c.messages {
				if old.ID == c.messageObjects[e.Object] && old.removed {
					delete(c.messageObjects, e.Object)
					break
				}
			}
		}
		m := c.ensureMessage(e.Object)
		m.State = messageState(e.State)
		m.Observed = time.Now().UTC()
	case "message.update", "message.remove":
		for _, m := range c.messages {
			if m.ID == c.messageObjects[e.Object] {
				if e.Kind == "message.remove" {
					m.removed = true
				} else {
					m.State = messageState(e.State)
					m.Observed = time.Now().UTC()
				}
			}
		}
	case "message.incoming":
		c.incoming(e.Text, e.Sender)
	}
	return true
}
