package at

import (
	"context"
	"regexp"
	"strings"
	"time"
)

var dialCommand = regexp.MustCompile(`^ATD\+?[0-9]{7,15};$`)
var hangupCommand = regexp.MustCompile(`^AT\+CHLD=1[1-9][0-9]?$`)
var toneCommand = regexp.MustCompile(`^AT\+VTS="[0-9A-D*#]"$`)
var smsCommand = regexp.MustCompile(`^AT\+CMGS=[1-9][0-9]{0,2}$`)
var hexPDU = regexp.MustCompile(`^(?:[0-9A-Fa-f]{2}){1,256}$`)

// Command is the bounded write surface used by the EG25 HAL. Arguments and
// SMS bodies stay in memory; the transaction fence records only the operation.
func (m *Manager) Command(ctx context.Context, cmd, payload string) ([]string, error) {
	r := request{ctx: ctx, command: cmd, timeout: 5 * time.Second}
	switch {
	case cmd == "ATE0", cmd == "AT+CMGF=0":
		r.label = "configure"
	case cmd == "AT+CMGL=4":
		r.label = "sms.list"
		r.prefix = "+CMGL:"
		r.pduLines = true
	case dialCommand.MatchString(cmd):
		r.label = "call.dial"
		r.timeout = 30 * time.Second
	case cmd == "ATA":
		r.label = "call.answer"
		r.timeout = 30 * time.Second
	case hangupCommand.MatchString(cmd):
		r.label = "call.hangup"
	case toneCommand.MatchString(cmd):
		r.label = "call.dtmf"
	case smsCommand.MatchString(cmd) && hexPDU.MatchString(payload):
		r.label = "sms.send"
		r.prefix = "+CMGS:"
		r.payload = strings.ToUpper(payload)
		r.timeout = 60 * time.Second
	default:
		return nil, ErrInvalid
	}
	if payload != "" && r.label != "sms.send" {
		return nil, ErrInvalid
	}
	return m.submit(r)
}
