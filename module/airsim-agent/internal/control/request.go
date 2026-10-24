package control

import (
	"airsim.local/airsim-agent/internal/strictjson"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

var uuid = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var number = regexp.MustCompile(`^\+?[0-9]{7,15}$`)
var tones = regexp.MustCompile(`^[0-9A-D*#]{1,16}$`)
var ErrParameters = errors.New("invalid_parameters")
var ErrAction = errors.New("unsupported_action")

type Args struct {
	Number string `json:"number,omitempty"`
	CallID string `json:"call_id,omitempty"`
	Tones  string `json:"tones,omitempty"`
	Text   string `json:"text,omitempty"`
}
type Request struct {
	CommandID string `json:"command_id"`
	BootID    string `json:"agent_boot_id"`
	Epoch     string `json:"backend_epoch"`
	Deadline  string `json:"deadline"`
	Action    string `json:"action"`
	Args      Args   `json:"args"`
}

func Parse(data []byte) (Request, error) {
	var r Request
	if len(data) > 4096 {
		return r, ErrParameters
	}
	fields, e := strictjson.Object(data, []string{"command_id", "agent_boot_id", "backend_epoch", "deadline", "action", "args"}, nil)
	if e != nil {
		return r, ErrParameters
	}
	if json.Unmarshal(data, &r) != nil || !uuid.MatchString(r.CommandID) || !uuid.MatchString(r.BootID) || !uuid.MatchString(r.Epoch) {
		return r, ErrParameters
	}
	if _, e = time.Parse(time.RFC3339Nano, r.Deadline); e != nil {
		return r, ErrParameters
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
		return r, ErrAction
	}
	if e = strictjson.Decode(fields["args"], keys, nil, &r.Args); e != nil {
		return r, ErrParameters
	}
	switch r.Action {
	case "call.dial", "sms.send":
		if !number.MatchString(r.Args.Number) {
			return r, ErrParameters
		}
	}
	if r.Action == "sms.send" && (r.Args.Text == "" || !utf8.ValidString(r.Args.Text) || strings.ContainsRune(r.Args.Text, 0) || len(utf16.Encode([]rune(r.Args.Text))) > 70) {
		return r, ErrParameters
	}
	if r.Action == "call.answer" || r.Action == "call.hangup" || r.Action == "call.dtmf" {
		if !uuid.MatchString(r.Args.CallID) {
			return r, ErrParameters
		}
	}
	if r.Action == "call.dtmf" && !tones.MatchString(r.Args.Tones) {
		return r, ErrParameters
	}
	return r, nil
}
func (r Request) Canonical() []byte { b, _ := json.Marshal(r); return b }
func (r Request) Budget(now time.Time) (time.Time, bool) {
	deadline, e := time.Parse(time.RFC3339Nano, r.Deadline)
	delta := deadline.Sub(now)
	if e != nil || delta <= 0 || delta > 60*time.Second {
		return time.Time{}, false
	}
	return now.Add(delta), true
}

func ValidID(s string) bool { return uuid.MatchString(s) }
