package control

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"airsim.local/airsim-agent/internal/journal"
	"context"
	"errors"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type response struct {
	Value any
	Code  int
}
type apiRequest struct {
	kind, id string
	command  Request
	reply    chan response
}
type job struct {
	request  Request
	deadline time.Time
	record   journal.Record
	serial   uint64
}
type begin struct {
	job   job
	reply chan grant
}
type grant struct {
	backend hal.ControlBackend
	action  hal.WriteAction
	ok      bool
}
type completed struct {
	job    job
	result hal.WriteResult
	ack    chan struct{}
}
type connected struct {
	session hal.ControlSession
	err     error
}
type synced struct {
	snapshot hal.ControlSnapshot
	err      error
	epoch    string
	dropped  uint64
}
type observation struct {
	commandID, callID, action string
	until                     time.Time
}
type Coordinator struct {
	audioEvents       chan struct{}
	audioLast         AudioQualification
	boot              string
	digest            func([]byte) string
	hardware          func() bool
	store             *journal.Store
	storeOK           bool
	api               chan apiRequest
	begin             chan begin
	results           chan completed
	callsQueue        chan job
	smsQueue          chan job
	done              chan struct{}
	calls             map[string]*Call
	callObjects       map[string]string
	ended             []string
	messages          []*Message
	messageObjects    map[string]string
	bodyBytes         int
	backend           hal.ControlSession
	executor          hal.ControlBackend
	eventSerial       uint64
	callEvicted       uint64
	messageEvicted    uint64
	emergencySequence uint64
	tombs             []tombstone
	dialReservation   string
	ready             bool
	reason            string
	gap               bool
	dropped           uint64
	everConnected     bool
	emergency         []string
	stopping          bool
	pending           map[string]job
	watch             []observation
}

func New(boot string, digest func([]byte) string, hardware func() bool, store *journal.Store, storeErr error) *Coordinator {
	return &Coordinator{audioEvents: make(chan struct{}, 1), boot: boot, digest: digest, hardware: hardware, store: store, storeOK: storeErr == nil, api: make(chan apiRequest, 32), begin: make(chan begin, 2), results: make(chan completed, 2), callsQueue: make(chan job, 8), smsQueue: make(chan job, 8), done: make(chan struct{}), calls: map[string]*Call{}, callObjects: map[string]string{}, messageObjects: map[string]string{}, messages: []*Message{}, pending: map[string]job{}, reason: "initializing"}
}
func (c *Coordinator) invoke(ctx context.Context, r apiRequest) response {
	r.reply = make(chan response, 1)
	select {
	case c.api <- r:
	case <-ctx.Done():
		return response{Code: 503}
	case <-c.done:
		return response{Code: 503}
	}
	select {
	case out := <-r.reply:
		return out
	case <-ctx.Done():
		return response{Code: 503}
	case <-c.done:
		return response{Code: 503}
	}
}
func (c *Coordinator) Submit(ctx context.Context, r Request) (any, int) {
	v := c.invoke(ctx, apiRequest{kind: "submit", command: r})
	return v.Value, v.Code
}
func (c *Coordinator) View(ctx context.Context, kind, id string) (any, int) {
	v := c.invoke(ctx, apiRequest{kind: kind, id: id})
	return v.Value, v.Code
}
func (c *Coordinator) Done() <-chan struct{} { return c.done }
func (c *Coordinator) epoch() string {
	if c.backend != nil {
		return c.backend.EpochID()
	}
	return ""
}
func (c *Coordinator) status() Status {
	ready := c.ready && c.storeOK && !c.stopping && c.hardware()
	reason := c.reason
	if !c.storeOK {
		reason = "journal_unavailable"
	} else if !c.hardware() {
		reason = "hardware_unavailable"
	} else if c.stopping {
		reason = "stopping"
	}
	if ready {
		reason = ""
	}
	return Status{Schema: 1, Boot: c.boot, Epoch: c.epoch(), Ready: ready, Reason: reason, Scope: "local_control", Telephony: ready, Messaging: ready, InboxGap: c.gap, Dropped: c.dropped, Remaining: c.store.Remaining()}
}
func (c *Coordinator) handleAPI(r apiRequest) {
	var out response
	out.Code = 200
	switch r.kind {
	case "audio_qualification":
		c.publishAudio()
		out.Value = c.audioLast
	case "control":
		out.Value = c.status()
	case "calls":
		view := CallsView{Boot: c.boot, Epoch: c.epoch(), Available: c.ready, Calls: []Call{}}
		for _, call := range c.calls {
			view.Calls = append(view.Calls, *call)
		}
		out.Value = view
	case "messages", "cloud_messages":
		view := MessagesView{Boot: c.boot, Epoch: c.epoch(), Available: c.ready, Gap: c.gap, Dropped: c.dropped, Messages: []Message{}}
		for _, m := range c.messages {
			if r.kind == "cloud_messages" && m.epoch != view.Epoch {
				view.Gap = true
				continue
			}
			view.Messages = append(view.Messages, *m)
		}
		out.Value = view
	case "command":
		record, ok := c.store.Get(r.id)
		if !ok {
			out.Code = 404
		} else {
			out.Value = receipt(record)
		}
	case "submit":
		out = c.submit(r.command)
	default:
		out.Code = 404
	}
	r.reply <- out
}
func receipt(r journal.Record) any {
	return struct {
		ID        string    `json:"command_id"`
		Action    string    `json:"action"`
		State     string    `json:"state"`
		Code      string    `json:"result_code"`
		CallID    string    `json:"call_id,omitempty"`
		MessageID string    `json:"message_id,omitempty"`
		Updated   time.Time `json:"updated_at"`
	}{r.CommandID, r.Action, r.State, r.Code, r.CallID, r.MessageID, r.UpdatedAt}
}
func (c *Coordinator) submit(r Request) response {
	digest := c.digest(r.Canonical())
	if old, ok := c.store.Get(r.CommandID); ok {
		if old.Digest != digest {
			return response{Code: 409}
		}
		return response{Value: receipt(old), Code: 200}
	}
	if !c.storeOK {
		return response{Code: 503}
	}
	if r.BootID != c.boot || r.Epoch != c.epoch() {
		return response{Code: 409}
	}
	deadline, ok := r.Budget(time.Now())
	if !ok {
		return response{Code: 400}
	}
	if code := c.validate(r); code != 0 {
		return response{Code: code}
	}
	queue := c.callsQueue
	if r.Action == "sms.send" {
		queue = c.smsQueue
	}
	if len(queue) == cap(queue) || c.store.Remaining() == 0 {
		return response{Code: 429}
	}
	now := time.Now().UTC()
	record := journal.Record{CommandID: r.CommandID, Digest: digest, Action: r.Action, State: "prepared", CreatedAt: now, UpdatedAt: now, BootID: r.BootID, Epoch: r.Epoch}
	if e := c.store.Put(record); e != nil {
		if errors.Is(e, journal.ErrFull) {
			return response{Code: 429}
		}
		c.storeOK = false
		return response{Code: 503}
	}
	item := job{request: r, deadline: deadline, record: record}
	c.pending[r.CommandID] = item
	queue <- item
	return response{Value: receipt(record), Code: 202}
}
func (c *Coordinator) validate(r Request) int {
	if c.stopping || !c.ready || c.backend == nil || !c.storeOK {
		return 503
	}
	if r.BootID != c.boot || r.Epoch != c.epoch() {
		return 409
	}
	if !c.hardware() {
		call := c.calls[r.Args.CallID]
		if r.Action != "call.hangup" || call == nil || call.Ownership != "managed" {
			return 503
		}
	}
	active := 0
	for _, call := range c.calls {
		if call.epoch == c.epoch() && call.State != "disconnected" {
			active++
		}
	}
	if r.Action == "call.dial" || r.Action == "sms.send" {
		for _, n := range c.emergency {
			if strings.TrimPrefix(r.Args.Number, "+") == strings.TrimPrefix(n, "+") {
				return 400
			}
		}
	}
	switch r.Action {
	case "call.dial":
		if active != 0 || c.dialReservation != "" {
			return 409
		}
	case "sms.send":
	case "call.answer", "call.hangup", "call.dtmf":
		call := c.calls[r.Args.CallID]
		if call == nil || call.epoch != c.epoch() || call.State == "disconnected" || call.Ownership == "unmanaged" {
			return 409
		}
		switch r.Action {
		case "call.answer":
			if call.Ownership != "incoming" || call.State != "incoming" || active != 1 {
				return 409
			}
		case "call.dtmf":
			if call.Ownership != "managed" || call.State != "active" || active != 1 {
				return 409
			}
		case "call.hangup":
			if call.Ownership == "incoming" && call.State != "incoming" && call.State != "waiting" {
				return 409
			}
		}
	default:
		return 404
	}
	return 0
}
func (c *Coordinator) beginJob(b begin) {
	j := b.job
	if _, ok := c.pending[j.request.CommandID]; !ok {
		b.reply <- grant{}
		return
	}
	if time.Now().After(j.deadline) {
		c.finishState(j, "expired", "deadline_expired")
		b.reply <- grant{}
		return
	}
	if code := c.validate(j.request); code != 0 {
		c.finishState(j, "failed", "state_changed")
		b.reply <- grant{}
		return
	}
	record := j.record
	record.State = "dispatched"
	record.UpdatedAt = time.Now().UTC()
	if e := c.store.Put(record); e != nil {
		c.storeOK = false
		delete(c.pending, j.request.CommandID)
		b.reply <- grant{}
		return
	}
	j.record = record
	j.serial = c.eventSerial
	if j.request.Action == "call.dial" {
		c.dialReservation = j.request.CommandID
	}
	c.pending[j.request.CommandID] = j
	action := hal.WriteAction{Action: j.request.Action, Number: j.request.Args.Number, Text: j.request.Args.Text, Tones: j.request.Args.Tones}
	if call := c.calls[j.request.Args.CallID]; call != nil {
		action.Object = call.object
	}
	b.reply <- grant{c.executor, action, true}
}
func (c *Coordinator) finishState(j job, state, code string) {
	record, ok := c.store.Get(j.request.CommandID)
	if !ok {
		return
	}
	record.State = state
	record.Code = code
	record.UpdatedAt = time.Now().UTC()
	if e := c.store.Put(record); e != nil {
		c.storeOK = false
	}
	delete(c.pending, j.request.CommandID)
}
func (c *Coordinator) worker(queue <-chan job, wg *sync.WaitGroup) {
	defer wg.Done()
	for j := range queue {
		reply := make(chan grant, 1)
		c.begin <- begin{j, reply}
		g := <-reply
		if !g.ok {
			continue
		}
		ctx, cancel := context.WithDeadline(context.Background(), j.deadline)
		result := g.backend.Execute(ctx, g.action)
		cancel()
		ack := make(chan struct{})
		c.results <- completed{j, result, ack}
		<-ack
	}
}
func (c *Coordinator) complete(result completed) {
	if result.ack != nil {
		defer close(result.ack)
	}
	j := result.job
	if current, ok := c.pending[j.request.CommandID]; ok {
		j = current
	}
	record, ok := c.store.Get(j.request.CommandID)
	if !ok {
		return
	}
	if record.State != "dispatched" {
		delete(c.pending, j.request.CommandID)
		return
	}
	if result.result.Unknown || j.request.Epoch != c.epoch() || (!c.ready && !c.stopping) {
		c.finishState(j, "outcome_unknown", "backend_lost")
		return
	}
	if result.result.Failed {
		if c.dialReservation == j.request.CommandID {
			c.dialReservation = ""
		}
		c.finishState(j, "failed", "backend_rejected")
		return
	}
	record.State = "accepted"
	record.Code = ""
	record.UpdatedAt = time.Now().UTC()
	switch j.request.Action {
	case "call.dial":
		if c.callEvicted > j.serial {
			c.finishState(j, "outcome_unknown", "ambiguous_call")
			return
		}
		for _, t := range c.tombs {
			if t.epoch == j.request.Epoch && t.object == result.result.Object && t.serial > j.serial {
				c.finishState(j, "outcome_unknown", "ambiguous_call")
				return
			}
		}
		if existing := c.calls[c.callObjects[result.result.Object]]; existing != nil && (existing.born <= j.serial || existing.Direction == "incoming") {
			c.finishState(j, "outcome_unknown", "ambiguous_call")
			return
		}
		call := c.ensureCall(result.result.Object, "", "", "managed")
		c.dialReservation = ""
		call.Ownership = "managed"
		call.Direction = "outgoing"
		record.CallID = call.ID
	case "call.answer":
		call := c.calls[j.request.Args.CallID]
		if call != nil {
			call.Ownership = "managed"
		}
		record.CallID = j.request.Args.CallID
		c.watch = append(c.watch, observation{record.CommandID, record.CallID, "call.answer", time.Now().Add(10 * time.Second)})
	case "call.hangup":
		record.CallID = j.request.Args.CallID
		c.watch = append(c.watch, observation{record.CommandID, record.CallID, "call.hangup", time.Now().Add(10 * time.Second)})
	case "call.dtmf":
		record.CallID = j.request.Args.CallID
	case "sms.send":
		var m *Message
		ambiguous := c.messageEvicted > j.serial
		for _, candidate := range c.messages {
			if candidate.object == result.result.Object && candidate.epoch == j.request.Epoch && candidate.born > j.serial {
				if m != nil {
					ambiguous = true
				}
				m = candidate
			}
		}
		if m == nil && c.messageObjects[result.result.Object] != "" {
			ambiguous = true
		}
		if ambiguous {
			c.finishState(j, "outcome_unknown", "ambiguous_message")
			return
		}
		if m == nil {
			m = c.ensureMessage(result.result.Object)
			m.State = "queued"
		}
		m.Recipient = j.request.Args.Number
		c.bodyBytes -= len(m.Text)
		m.Text = j.request.Args.Text
		c.bodyBytes += len(m.Text)
		record.MessageID = m.ID
		c.trimMessages()
	}
	if e := c.store.Put(record); e != nil {
		c.storeOK = false
	}
	delete(c.pending, j.request.CommandID)
	c.observe()
}
func (c *Coordinator) observe() {
	kept := c.watch[:0]
	for _, w := range c.watch {
		record, ok := c.store.Get(w.commandID)
		if !ok || record.State != "accepted" {
			continue
		}
		call := c.calls[w.callID]
		observed := (w.action == "call.answer" && call != nil && call.State == "active") || (w.action == "call.hangup" && call != nil && call.State == "disconnected")
		if observed {
			record.State = "observed"
			record.UpdatedAt = time.Now().UTC()
			if c.store.Put(record) != nil {
				c.storeOK = false
			}
		} else if time.Now().Before(w.until) {
			kept = append(kept, w)
		}
	}
	c.watch = kept
}
func (c *Coordinator) ensureCall(object, state, number, ownership string) *Call {
	if id, ok := c.callObjects[object]; ok {
		call := c.calls[id]
		if state != "" {
			call.State = callState(state)
		}
		if number != "" {
			call.Number = number
		}
		call.Observed = time.Now().UTC()
		return call
	}
	id, _ := identity.UUID()
	direction := "unknown"
	if state == "incoming" || state == "waiting" {
		direction = "incoming"
	}
	if state == "dialing" || state == "alerting" {
		direction = "outgoing"
	}
	call := &Call{ID: id, State: callState(state), Number: number, Ownership: ownership, Direction: direction, Observed: time.Now().UTC(), object: object, epoch: c.epoch(), born: c.eventSerial}
	c.calls[id] = call
	c.callObjects[object] = id
	return call
}
func (c *Coordinator) endCall(object string) {
	c.eventSerial++
	c.tombs = append(c.tombs, tombstone{object, c.epoch(), c.eventSerial})
	if len(c.tombs) > 32 {
		c.callEvicted = c.tombs[len(c.tombs)-33].serial
		c.tombs = c.tombs[len(c.tombs)-32:]
	}
	id, ok := c.callObjects[object]
	if !ok {
		return
	}
	call := c.calls[id]
	call.State = "disconnected"
	call.Observed = time.Now().UTC()
	delete(c.callObjects, object)
	c.ended = append(c.ended, id)
	if len(c.ended) > 32 {
		delete(c.calls, c.ended[0])
		c.ended = c.ended[1:]
	}
	c.observe()
}
func (c *Coordinator) ensureMessage(object string) *Message {
	if id, ok := c.messageObjects[object]; ok {
		for _, m := range c.messages {
			if m.ID == id {
				return m
			}
		}
	}
	id, _ := identity.UUID()
	c.eventSerial++
	m := &Message{born: c.eventSerial, ID: id, Direction: "outgoing", State: "unknown", Delivery: "unknown", Observed: time.Now().UTC(), object: object, epoch: c.epoch()}
	c.messages = append(c.messages, m)
	c.messageObjects[object] = id
	c.trimMessages()
	return m
}
func (c *Coordinator) trimMessages() {
	for len(c.messages) > 128 || c.bodyBytes > 1<<20 {
		m := c.messages[0]
		c.messages = c.messages[1:]
		c.bodyBytes -= len(m.Text)
		if m.born > c.messageEvicted {
			c.messageEvicted = m.born
		}
		if c.messageObjects[m.object] == m.ID {
			delete(c.messageObjects, m.object)
		}
		c.gap = true
		c.dropped++
	}
}
func (c *Coordinator) incoming(text, sender string) {
	if len(text) > 8192 || !utf8.ValidString(text) {
		c.gap = true
		c.dropped++
		return
	}
	id, _ := identity.UUID()
	m := &Message{ID: id, Direction: "incoming", Sender: sender, Text: text, State: "received", Delivery: "unknown", Observed: time.Now().UTC(), epoch: c.epoch()}
	c.messages = append(c.messages, m)
	c.bodyBytes += len(text)
	c.trimMessages()
}

type tombstone struct {
	object, epoch string
	serial        uint64
}
