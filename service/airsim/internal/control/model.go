package control

import (
	"airsim.local/server/internal/wire"
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

type Request struct {
	ID       string          `json:"command_id"`
	Boot     string          `json:"agent_boot_id"`
	Backend  string          `json:"backend_epoch"`
	Deadline string          `json:"deadline"`
	Action   string          `json:"action"`
	Args     json.RawMessage `json:"args"`
}
type Args struct {
	Number string `json:"number,omitempty"`
	Call   string `json:"call_id,omitempty"`
	Text   string `json:"text,omitempty"`
	Tones  string `json:"tones,omitempty"`
}

func parse(b []byte) (Request, Args, error) {
	var r Request
	var a Args
	if len(b) > 4096 || wire.Decode(b, &r, "command_id", "agent_boot_id", "backend_epoch", "deadline", "action", "args") != nil || !wire.UUID.MatchString(r.ID) || !wire.UUID.MatchString(r.Boot) || !wire.UUID.MatchString(r.Backend) {
		return r, a, wire.ErrInvalid
	}
	var keys []string
	switch r.Action {
	case "call.dial":
		keys = []string{"number"}
	case "call.answer", "call.hangup":
		keys = []string{"call_id"}
	case "call.dtmf":
		keys = []string{"call_id", "tones"}
	case "sms.send":
		keys = []string{"number", "text"}
	default:
		return r, a, wire.ErrInvalid
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(r.Args, &fields) != nil || len(fields) != len(keys) || wire.Decode(r.Args, &a, keys...) != nil {
		return r, a, wire.ErrInvalid
	}
	if r.Action == "call.dial" || r.Action == "sms.send" {
		if !regexp.MustCompile(`^\+?[0-9]{7,15}$`).MatchString(a.Number) {
			return r, a, wire.ErrInvalid
		}
	}
	if r.Action == "sms.send" && (a.Text == "" || !utf8.ValidString(a.Text) || strings.ContainsRune(a.Text, 0) || len(utf16.Encode([]rune(a.Text))) > 70) {
		return r, a, wire.ErrInvalid
	}
	if a.Call != "" && !wire.UUID.MatchString(a.Call) {
		return r, a, wire.ErrInvalid
	}
	if r.Action == "call.dtmf" && !regexp.MustCompile(`^[0-9A-D*#]{1,16}$`).MatchString(a.Tones) {
		return r, a, wire.ErrInvalid
	}
	if _, e := time.Parse(time.RFC3339Nano, r.Deadline); e != nil || !strings.HasSuffix(r.Deadline, "Z") {
		return r, a, wire.ErrInvalid
	}
	r.Args, _ = json.Marshal(a)
	return r, a, nil
}

type Envelope struct {
	Type     string          `json:"type"`
	Version  int             `json:"protocol_version"`
	Module   string          `json:"module_id"`
	Epoch    string          `json:"connection_epoch"`
	Sequence uint64          `json:"sequence"`
	Payload  json.RawMessage `json:"payload"`
}
type Status struct {
	Schema    int    `json:"schema_version"`
	Boot      string `json:"agent_boot_id"`
	Backend   string `json:"backend_epoch"`
	Ready     bool   `json:"ready"`
	Reason    string `json:"reason"`
	Scope     string `json:"scope"`
	Voice     bool   `json:"voice_ready"`
	Telephony bool   `json:"telephony_ready"`
	Messaging bool   `json:"messaging_ready"`
	Gap       bool   `json:"inbox_gap"`
	Dropped   uint64 `json:"inbox_dropped"`
	Remaining uint64 `json:"command_capacity_remaining"`
}
type Call struct {
	ID        string    `json:"call_id"`
	State     string    `json:"state"`
	Ownership string    `json:"ownership"`
	Direction string    `json:"direction"`
	Number    string    `json:"number"`
	Observed  time.Time `json:"observed_at"`
	Reason    string    `json:"disconnect_reason"`
}
type Calls struct {
	Boot      string `json:"agent_boot_id"`
	Backend   string `json:"backend_epoch"`
	Available bool   `json:"available"`
	Calls     []Call `json:"calls"`
}
type Snapshot struct {
	Boot     string          `json:"agent_boot_id"`
	Backend  string          `json:"backend_epoch"`
	Observed time.Time       `json:"observed_at"`
	Control  Status          `json:"control"`
	Calls    Calls           `json:"calls"`
	Audio    json.RawMessage `json:"audio"`
	Signal   json.RawMessage `json:"signal,omitempty"`
}
type Message struct {
	ID        string    `json:"message_id"`
	Direction string    `json:"direction"`
	Sender    string    `json:"sender"`
	Recipient string    `json:"recipient"`
	Text      string    `json:"text"`
	State     string    `json:"state"`
	Delivery  string    `json:"delivery"`
	Observed  time.Time `json:"observed_at"`
}
type Messages struct {
	Boot     string    `json:"agent_boot_id"`
	Backend  string    `json:"backend_epoch"`
	Observed time.Time `json:"observed_at"`
	Gap      bool      `json:"inbox_gap"`
	Dropped  uint64    `json:"inbox_dropped"`
	Messages []Message `json:"messages"`
}
type Record struct {
	ID         string          `json:"command_id"`
	State      string          `json:"state"`
	Generation string          `json:"generation"`
	Receipt    json.RawMessage `json:"receipt"`
}

// validSignal accepts legacy snapshots without a signal measurement.
func validSignal(raw json.RawMessage) bool {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return true
	}
	var signal struct {
		Available bool    `json:"available"`
		Observed  *string `json:"observed_at"`
		RSSI      *int    `json:"rssi"`
		DBM       *int    `json:"dbm"`
	}
	if wire.DecodeNullable(raw, &signal, "observed_at", "rssi", "dbm") != nil {
		return false
	}
	if signal.Observed != nil {
		if _, err := time.Parse(time.RFC3339Nano, *signal.Observed); err != nil || !strings.HasSuffix(*signal.Observed, "Z") {
			return false
		}
	}
	if !signal.Available {
		return signal.RSSI == nil && signal.DBM == nil
	}
	return signal.Observed != nil && signal.RSSI != nil && signal.DBM != nil && *signal.RSSI >= 0 && *signal.RSSI <= 31 && *signal.DBM == -113+2*(*signal.RSSI)
}

func visibleSnapshot(p *peer, online bool) *Snapshot {
	if p == nil || p.snapshot == nil {
		return nil
	}
	snapshot := *p.snapshot
	if !online {
		snapshot.Signal = nil
	}
	return &snapshot
}

func (s *Server) moduleSummary(id string) map[string]any {
	online := s.peers[id] != nil
	v := map[string]any{"module_id": id, "online": online, "last_seen": nil, "agent_boot_id": "", "backend_epoch": "", "connection_epoch": ""}
	if p := s.last[id]; p != nil {
		v["last_seen"] = p.last.UTC()
		v["agent_boot_id"] = p.boot
		v["backend_epoch"] = p.backend
		v["connection_epoch"] = p.epoch
		if snapshot := visibleSnapshot(p, online); snapshot != nil && len(snapshot.Signal) > 0 {
			v["signal"] = snapshot.Signal
		}
	}
	return v
}
