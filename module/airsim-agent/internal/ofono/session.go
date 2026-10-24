package ofono

import (
	"airsim.local/airsim-agent/internal/hal"
	"airsim.local/airsim-agent/internal/identity"
	"context"
	"errors"
	"github.com/godbus/dbus/v5"
	"net"
	"strings"
	"time"
)

var ErrUnavailable = errors.New("backend_unavailable")

type Object struct {
	Path       dbus.ObjectPath
	Properties map[string]dbus.Variant
}
type Session struct {
	Conn  *dbus.Conn
	Queue *SignalQueue
	Owner string
	Modem dbus.ObjectPath
	Epoch string
}

func Connect(ctx context.Context) (*Session, error) {
	q := NewSignalQueue()
	conn, e := connectBus(ctx, q)
	if e != nil {
		return nil, ErrUnavailable
	}
	s := &Session{Conn: conn, Queue: q}
	fail := func() (*Session, error) { conn.Close(); return nil, ErrUnavailable }
	for _, iface := range []string{"org.ofono.Manager", "org.ofono.Modem", "org.ofono.VoiceCallManager", "org.ofono.VoiceCall", "org.ofono.MessageManager", "org.ofono.Message"} {
		callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		e = conn.AddMatchSignalContext(callCtx, dbus.WithMatchSender("org.ofono"), dbus.WithMatchInterface(iface))
		cancel()
		if e != nil {
			return fail()
		}
	}
	callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	e = conn.AddMatchSignalContext(callCtx, dbus.WithMatchSender("org.freedesktop.DBus"), dbus.WithMatchInterface("org.freedesktop.DBus"), dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, "org.ofono"))
	cancel()
	if e != nil {
		return fail()
	}
	callCtx, cancel = context.WithTimeout(ctx, 5*time.Second)
	e = conn.BusObject().CallWithContext(callCtx, "org.freedesktop.DBus.GetNameOwner", 0, "org.ofono").Store(&s.Owner)
	cancel()
	if e != nil || !strings.HasPrefix(s.Owner, ":") {
		return fail()
	}
	var modems []Object
	callCtx, cancel = context.WithTimeout(ctx, 5*time.Second)
	e = conn.Object(s.Owner, "/").CallWithContext(callCtx, "org.ofono.Manager.GetModems", dbus.FlagNoAutoStart).Store(&modems)
	cancel()
	if e != nil || len(modems) != 1 {
		return fail()
	}
	m := modems[0]
	if !m.Path.IsValid() || !Bool(m.Properties, "Powered") || !Bool(m.Properties, "Online") || !InterfacesReady(m.Properties) {
		return fail()
	}
	s.Modem = m.Path
	s.Epoch, e = identity.UUID()
	if e != nil {
		return fail()
	}
	return s, nil
}
func Bool(p map[string]dbus.Variant, key string) bool     { v, ok := p[key].Value().(bool); return ok && v }
func String(p map[string]dbus.Variant, key string) string { v, _ := p[key].Value().(string); return v }
func InterfacesReady(p map[string]dbus.Variant) bool {
	values, ok := p["Interfaces"].Value().([]string)
	if !ok {
		return false
	}
	voice, sms := false, false
	for _, v := range values {
		voice = voice || v == "org.ofono.VoiceCallManager"
		sms = sms || v == "org.ofono.MessageManager"
	}
	return voice && sms
}
func (s *Session) Snapshot(ctx context.Context) (hal.ControlSnapshot, error) {
	var out hal.ControlSnapshot
	var calls, messages []Object
	var props map[string]dbus.Variant
	callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	c := s.Conn.Object(s.Owner, s.Modem).CallWithContext(callCtx, "org.ofono.VoiceCallManager.GetCalls", dbus.FlagNoAutoStart)
	e := c.Store(&calls)
	cancel()
	if e != nil {
		return out, ErrUnavailable
	}
	out.CallSequence = uint64(c.ResponseSequence)
	callCtx, cancel = context.WithTimeout(ctx, 5*time.Second)
	c = s.Conn.Object(s.Owner, s.Modem).CallWithContext(callCtx, "org.ofono.MessageManager.GetMessages", dbus.FlagNoAutoStart)
	e = c.Store(&messages)
	cancel()
	if e != nil {
		return out, ErrUnavailable
	}
	out.MessageSequence = uint64(c.ResponseSequence)
	callCtx, cancel = context.WithTimeout(ctx, 5*time.Second)
	c = s.Conn.Object(s.Owner, s.Modem).CallWithContext(callCtx, "org.ofono.VoiceCallManager.GetProperties", dbus.FlagNoAutoStart)
	e = c.Store(&props)
	out.EmergencySequence = uint64(c.ResponseSequence)
	cancel()
	if e != nil {
		return out, ErrUnavailable
	}
	numbers, ok := props["EmergencyNumbers"].Value().([]string)
	if !ok {
		return out, ErrUnavailable
	}
	out.EmergencyNumbers = numbers
	for _, c := range calls {
		out.Calls = append(out.Calls, hal.ControlCall{Object: string(c.Path), State: String(c.Properties, "State"), Number: String(c.Properties, "LineIdentification")})
	}
	for _, m := range messages {
		out.Messages = append(out.Messages, hal.PendingMessage{Object: string(m.Path), State: String(m.Properties, "State")})
	}
	return out, nil
}
func (s *Session) Execute(ctx context.Context, a hal.WriteAction) hal.WriteResult {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	path := s.Modem
	var method string
	var args []any
	returnsPath := false
	switch a.Action {
	case "call.dial":
		method = "org.ofono.VoiceCallManager.Dial"
		args = []any{a.Number, "default"}
		returnsPath = true
	case "call.answer":
		path = dbus.ObjectPath(a.Object)
		method = "org.ofono.VoiceCall.Answer"
	case "call.hangup":
		path = dbus.ObjectPath(a.Object)
		method = "org.ofono.VoiceCall.Hangup"
	case "call.dtmf":
		method = "org.ofono.VoiceCallManager.SendTones"
		args = []any{a.Tones}
	case "sms.send":
		method = "org.ofono.MessageManager.SendMessage"
		args = []any{a.Number, a.Text}
		returnsPath = true
	default:
		return hal.WriteResult{Failed: true}
	}
	if !path.IsValid() {
		return hal.WriteResult{Failed: true}
	}
	call := s.Conn.Object(s.Owner, path).CallWithContext(ctx, method, dbus.FlagNoAutoStart, args...)
	if call.Err != nil {
		var remote dbus.Error
		if errors.As(call.Err, &remote) && strings.HasPrefix(remote.Name, "org.ofono.Error.") {
			return hal.WriteResult{Failed: true}
		}
		return hal.WriteResult{Unknown: true}
	}
	if returnsPath {
		var object dbus.ObjectPath
		if call.Store(&object) != nil || !object.IsValid() || !strings.HasPrefix(string(object), string(s.Modem)+"/") {
			return hal.WriteResult{Unknown: true}
		}
		return hal.WriteResult{Object: string(object)}
	}
	return hal.WriteResult{}
}
func (s *Session) Close() {
	if s.Conn != nil {
		s.Conn.Close()
	}
	if s.Queue != nil {
		s.Queue.Terminate()
	}
}
func (s *Session) ValidSignal(signal *dbus.Signal) bool {
	if signal == nil {
		return false
	}
	if signal.Name == "org.freedesktop.DBus.NameOwnerChanged" {
		return signal.Sender == "org.freedesktop.DBus" && signal.Path == "/org/freedesktop/DBus"
	}
	if signal.Name == "org.ofono.Manager.ModemAdded" || signal.Name == "org.ofono.Manager.ModemRemoved" {
		return signal.Sender == s.Owner && signal.Path == "/"
	}
	return signal.Sender == s.Owner && (signal.Path == s.Modem || strings.HasPrefix(string(signal.Path), string(s.Modem)+"/"))
}

// The raw transport deadline bounds authentication as well as Hello. A parent
// cancellation closes even an authentication peer that never sends a byte.
func connectBus(ctx context.Context, q *SignalQueue) (*dbus.Conn, error) {
	raw, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", "/var/run/dbus/system_bus_socket")
	if err != nil {
		return nil, err
	}
	return handshake(ctx, raw, q)
}
func handshake(ctx context.Context, raw net.Conn, q *SignalQueue) (*dbus.Conn, error) {
	stop := context.AfterFunc(ctx, func() { raw.Close() })
	defer stop()
	fail := func(err error) (*dbus.Conn, error) { raw.Close(); return nil, err }
	if err := raw.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return fail(err)
	}
	conn, err := dbus.NewConn(raw, dbus.WithContext(ctx), dbus.WithSignalHandler(q))
	if err != nil {
		return fail(err)
	}
	if err = conn.Auth(nil); err == nil {
		err = conn.Hello()
	}
	if err == nil {
		err = ctx.Err()
	}
	if err == nil {
		err = raw.SetDeadline(time.Time{})
	}
	if err != nil {
		conn.Close()
		return fail(err)
	}
	return conn, nil
}
