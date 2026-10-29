package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/platform/atmodem"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Controller interface {
	atmodem.Querier
	Command(context.Context, string, string) ([]string, error)
	Done() <-chan struct{}
}
type voiceCall struct {
	hal.ControlCall
	index     int
	direction int
}
type Session struct {
	mu       sync.Mutex
	at       Controller
	epoch    string
	sequence uint64
	calls    map[int]voiceCall
	seenSMS  map[string]bool
	events   chan hal.ControlEvent
	overflow chan struct{}
	done     chan struct{}
	dropped  atomic.Uint64
	cancel   context.CancelFunc
}

func Connect(ctx context.Context, port Controller) (*Session, error) {
	if port == nil {
		return nil, errors.New("backend_unavailable")
	}
	for _, cmd := range []string{"ATE0", "AT+CMGF=0"} {
		if _, err := port.Command(ctx, cmd, ""); err != nil {
			return nil, err
		}
	}
	epoch, err := identity.UUID()
	if err != nil {
		return nil, err
	}
	child, cancel := context.WithCancel(ctx)
	s := &Session{at: port, epoch: epoch, calls: map[int]voiceCall{}, seenSMS: map[string]bool{}, events: make(chan hal.ControlEvent, 128), overflow: make(chan struct{}, 1), done: make(chan struct{}), cancel: cancel}
	go s.run(child)
	return s, nil
}
func (s *Session) EpochID() string                 { return s.epoch }
func (s *Session) Events() <-chan hal.ControlEvent { return s.events }
func (s *Session) Overflow() <-chan struct{}       { return s.overflow }
func (s *Session) Done() <-chan struct{}           { return s.done }
func (s *Session) Dropped() uint64                 { return s.dropped.Load() }
func (s *Session) Close()                          { s.cancel(); <-s.done }
func (s *Session) emit(e hal.ControlEvent) {
	s.sequence++
	e.Sequence = s.sequence
	select {
	case s.events <- e:
	default:
		s.dropped.Add(1)
		select {
		case s.overflow <- struct{}{}:
		default:
		}
	}
}

func parseCalls(lines []string) ([]voiceCall, error) {
	var out []voiceCall
	for _, line := range lines {
		if !strings.HasPrefix(line, "+CLCC:") {
			return nil, at.ErrInvalid
		}
		p, err := csv.NewReader(strings.NewReader(strings.TrimSpace(strings.TrimPrefix(line, "+CLCC:")))).Read()
		if err != nil || len(p) < 5 {
			return nil, at.ErrInvalid
		}
		values := [5]int{}
		for i := range values {
			values[i], err = strconv.Atoi(strings.TrimSpace(p[i]))
			if err != nil {
				return nil, at.ErrInvalid
			}
		}
		if values[3] != 0 {
			continue
		} // Packet-data connections are not voice calls.
		if values[0] < 1 || values[0] > 99 || values[1] < 0 || values[1] > 1 || values[2] < 0 || values[2] > 6 {
			return nil, at.ErrInvalid
		}
		states := []string{"active", "held", "dialing", "alerting", "incoming", "waiting", "disconnected"}
		c := voiceCall{ControlCall: hal.ControlCall{State: states[values[2]]}, index: values[0], direction: values[1]}
		if len(p) > 5 {
			c.Number = strings.TrimSpace(p[5])
		}
		if c.State != "disconnected" {
			out = append(out, c)
		}
	}
	return out, nil
}

func (s *Session) refreshCalls(ctx context.Context) error {
	lines, err := s.at.Query(ctx, "AT+CLCC")
	if err != nil {
		return err
	}
	calls, err := parseCalls(lines)
	if err != nil {
		return err
	}
	next := map[int]voiceCall{}
	for _, c := range calls {
		old, exists := s.calls[c.index]
		if exists {
			c.Object = old.Object
		} else {
			c.Object, err = identity.UUID()
			if err != nil {
				return err
			}
		}
		next[c.index] = c
		if !exists {
			s.emit(hal.ControlEvent{Kind: "call.add", Object: c.Object, State: c.State, Number: c.Number})
		} else {
			if c.State != old.State {
				s.emit(hal.ControlEvent{Kind: "call.state", Object: c.Object, State: c.State})
			}
			if c.Number != old.Number {
				s.emit(hal.ControlEvent{Kind: "call.number", Object: c.Object, Number: c.Number})
			}
		}
	}
	for i, c := range s.calls {
		if _, ok := next[i]; !ok {
			s.emit(hal.ControlEvent{Kind: "call.remove", Object: c.Object})
		}
	}
	s.calls = next
	return nil
}
func (s *Session) Snapshot(ctx context.Context) (hal.ControlSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.refreshCalls(ctx); err != nil {
		return hal.ControlSnapshot{}, err
	}
	out := hal.ControlSnapshot{CallSequence: s.sequence, EmergencyNumbers: []string{"112", "911", "110", "119", "120", "122", "999", "000", "118"}}
	for _, c := range s.calls {
		out.Calls = append(out.Calls, c.ControlCall)
	}
	return out, nil
}
func (s *Session) run(ctx context.Context) {
	defer close(s.done)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	count := 0
	failures := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.at.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			err := s.refreshCalls(ctx)
			if err == nil && count%5 == 0 {
				err = s.refreshSMS(ctx)
			}
			s.mu.Unlock()
			if err != nil {
				// QDC507 can return CME 100 while transitioning into ringing.
				// Keep object identities across a bounded transient query failure.
				failures++
				if !errors.Is(err, at.ErrQuery) || failures >= 3 {
					return
				}
				continue
			}
			failures = 0
			count++
		}
	}
}
func result(err error) hal.WriteResult {
	if err == nil {
		return hal.WriteResult{}
	}
	if errors.Is(err, at.ErrQuery) || errors.Is(err, at.ErrInvalid) {
		return hal.WriteResult{Failed: true}
	}
	return hal.WriteResult{Unknown: true}
}
func (s *Session) Execute(ctx context.Context, a hal.WriteAction) hal.WriteResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	if a.Action == "sms.send" {
		return s.sendSMS(ctx, a)
	}
	if err := s.refreshCalls(ctx); err != nil {
		return hal.WriteResult{Failed: true}
	}
	var target *voiceCall
	for _, c := range s.calls {
		if c.Object == a.Object {
			c := c
			target = &c
		}
	}
	var cmd string
	switch a.Action {
	case "call.dial":
		if len(s.calls) != 0 {
			return hal.WriteResult{Failed: true}
		}
		cmd = "ATD" + a.Number + ";"
	case "call.answer":
		if target == nil || target.State != "incoming" || len(s.calls) != 1 {
			return hal.WriteResult{Failed: true}
		}
		cmd = "ATA"
	case "call.hangup":
		if target == nil {
			return hal.WriteResult{Failed: true}
		}
		cmd = fmt.Sprintf("AT+CHLD=1%d", target.index)
	case "call.dtmf":
		if target == nil || target.State != "active" || len(s.calls) != 1 {
			return hal.WriteResult{Failed: true}
		}
		for _, tone := range a.Tones {
			if _, err := s.at.Command(ctx, fmt.Sprintf("AT+VTS=\"%c\"", tone), ""); err != nil {
				return result(err)
			}
		}
		return hal.WriteResult{}
	default:
		return hal.WriteResult{Failed: true}
	}
	_, err := s.at.Command(ctx, cmd, "")
	if err != nil {
		return result(err)
	}
	if err = s.refreshCalls(ctx); err != nil {
		return hal.WriteResult{Unknown: true}
	}
	if a.Action == "call.dial" {
		if len(s.calls) == 1 {
			for _, c := range s.calls {
				if c.direction == 0 {
					return hal.WriteResult{Object: c.Object}
				}
			}
		}
		return hal.WriteResult{Unknown: true}
	}
	return hal.WriteResult{}
}
