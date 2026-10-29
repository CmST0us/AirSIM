package hal

import "context"

// Backend object handles never become external call_id/message_id values.
type ControlCall struct{ Object, State, Number string }
type PendingMessage struct{ Object, State string }
type ControlSnapshot struct {
	Calls                         []ControlCall
	Messages                      []PendingMessage
	CallSequence, MessageSequence uint64
	EmergencyNumbers              []string
	EmergencySequence             uint64
}
type WriteAction struct{ Action, Object, Number, Text, Tones string }
type WriteResult struct {
	Object  string
	Unknown bool
	Failed  bool
}
type ControlBackend interface {
	Snapshot(context.Context) (ControlSnapshot, error)
	Execute(context.Context, WriteAction) WriteResult
}

type ControlEvent struct {
	Kind, Object, State, Number, Reason, Text, Sender string
	Sequence                                          uint64
	EmergencyNumbers                                  []string
}

type ControlSession interface {
	ControlBackend
	EpochID() string
	Events() <-chan ControlEvent
	Overflow() <-chan struct{}
	Done() <-chan struct{}
	Dropped() uint64
	Close()
}
