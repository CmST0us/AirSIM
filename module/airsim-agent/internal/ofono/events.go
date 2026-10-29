package ofono

import (
	"airsim.local/airsim-agent/internal/hal"
	"github.com/godbus/dbus/v5"
	"strings"
)

func (s *Session) EpochID() string           { return s.Epoch }
func (s *Session) Overflow() <-chan struct{} { return s.Queue.Overflow }
func (s *Session) Done() <-chan struct{}     { return s.Queue.Done }
func (s *Session) Dropped() uint64           { return s.Queue.Dropped() }
func (s *Session) Events() <-chan hal.ControlEvent {
	s.eventsOnce.Do(func() { s.events = s.Queue.normalized(s.Normalize) })
	return s.events
}

func (s *Session) Normalize(raw *dbus.Signal) hal.ControlEvent {
	e := hal.ControlEvent{}
	if !s.ValidSignal(raw) {
		return e
	}
	e.Sequence = uint64(raw.Sequence)
	e.Object = string(raw.Path)
	property := func() (string, dbus.Variant, bool) {
		if len(raw.Body) != 2 {
			return "", dbus.Variant{}, false
		}
		key, ok := raw.Body[0].(string)
		value, ok2 := raw.Body[1].(dbus.Variant)
		return key, value, ok && ok2
	}
	child := func(object string) bool {
		return dbus.ObjectPath(object).IsValid() && strings.HasPrefix(object, string(s.Modem)+"/")
	}
	switch raw.Name {
	case "org.freedesktop.DBus.NameOwnerChanged":
		if len(raw.Body) == 3 {
			name, _ := raw.Body[0].(string)
			old, _ := raw.Body[1].(string)
			next, _ := raw.Body[2].(string)
			if name == "org.ofono" && (old == s.Owner || next != s.Owner) {
				e.Kind = "backend.changed"
			}
		}
	case "org.ofono.Manager.ModemAdded", "org.ofono.Manager.ModemRemoved":
		e.Kind = "backend.changed"
	case "org.ofono.Modem.PropertyChanged":
		if raw.Path != s.Modem {
			break
		}
		key, v, ok := property()
		if !ok {
			e.Kind = "backend.changed"
			break
		}
		switch key {
		case "Powered", "Online":
			if b, ok := v.Value().(bool); !ok || !b {
				e.Kind = "backend.changed"
			}
		case "Interfaces":
			if !InterfacesReady(map[string]dbus.Variant{"Interfaces": v}) {
				e.Kind = "backend.changed"
			}
		}
	case "org.ofono.VoiceCallManager.PropertyChanged":
		key, v, ok := property()
		if raw.Path == s.Modem && ok && key == "EmergencyNumbers" {
			if numbers, ok := v.Value().([]string); ok {
				e.Kind = "emergency"
				e.EmergencyNumbers = numbers
			} else {
				e.Kind = "backend.changed"
			}
		}
	case "org.ofono.VoiceCallManager.CallAdded", "org.ofono.MessageManager.MessageAdded", "org.ofono.MessageManager.MessageState":
		if raw.Path != s.Modem || len(raw.Body) != 2 {
			break
		}
		object, ok := raw.Body[0].(dbus.ObjectPath)
		props, ok2 := raw.Body[1].(map[string]dbus.Variant)
		if !ok || !ok2 || !child(string(object)) {
			break
		}
		e.Object, e.State, e.Number = string(object), String(props, "State"), String(props, "LineIdentification")
		switch raw.Name {
		case "org.ofono.VoiceCallManager.CallAdded":
			e.Kind = "call.add"
		case "org.ofono.MessageManager.MessageAdded":
			e.Kind = "message.add"
		default:
			e.Kind = "message.state"
		}
	case "org.ofono.VoiceCallManager.CallRemoved", "org.ofono.MessageManager.MessageRemoved":
		if raw.Path != s.Modem || len(raw.Body) != 1 {
			break
		}
		object, ok := raw.Body[0].(dbus.ObjectPath)
		if !ok || !child(string(object)) {
			break
		}
		e.Object = string(object)
		if raw.Name == "org.ofono.VoiceCallManager.CallRemoved" {
			e.Kind = "call.remove"
		} else {
			e.Kind = "message.remove"
		}
	case "org.ofono.VoiceCall.PropertyChanged", "org.ofono.Message.PropertyChanged":
		if !child(e.Object) {
			break
		}
		key, v, ok := property()
		value, _ := v.Value().(string)
		if !ok {
			break
		}
		if key == "State" {
			e.State = value
			if raw.Name == "org.ofono.Message.PropertyChanged" {
				e.Kind = "message.update"
			} else {
				e.Kind = "call.state"
			}
		}
		if key == "LineIdentification" && raw.Name == "org.ofono.VoiceCall.PropertyChanged" {
			e.Kind = "call.number"
			e.Number = value
		}
	case "org.ofono.VoiceCall.DisconnectReason":
		if child(e.Object) && len(raw.Body) == 1 {
			e.Kind = "call.reason"
			e.Reason, _ = raw.Body[0].(string)
		}
	case "org.ofono.MessageManager.IncomingMessage", "org.ofono.MessageManager.ImmediateMessage":
		if raw.Path != s.Modem || len(raw.Body) != 2 {
			break
		}
		text, ok := raw.Body[0].(string)
		props, ok2 := raw.Body[1].(map[string]dbus.Variant)
		if ok && ok2 {
			e.Kind = "message.incoming"
			e.Text = text
			e.Sender = String(props, "Sender")
		}
	}
	return e
}
