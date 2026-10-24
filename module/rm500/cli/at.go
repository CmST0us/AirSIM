package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

type atSession struct {
	port    io.ReadWriteCloser
	pending []byte
}
type atResult struct {
	Lines    []string            `json:"lines"`
	Fields   map[string][]string `json:"fields"`
	Terminal string              `json:"terminal"`
}

func parseAT(text, echo string) atResult {
	r := atResult{Lines: []string{}, Fields: map[string][]string{}}
	for _, s := range strings.Split(strings.ReplaceAll(text, "\r", ""), "\n") {
		s = strings.TrimSpace(s)
		if s == "" || s == echo {
			continue
		}
		if terminal(s) {
			r.Terminal = s
			continue
		}
		r.Lines = append(r.Lines, s)
		if k, v, ok := strings.Cut(s, ":"); ok {
			r.Fields[k] = append(r.Fields[k], strings.TrimSpace(v))
		}
	}
	return r
}
func terminal(s string) bool {
	return s == "OK" || s == "ERROR" || s == "NO CARRIER" || s == "BUSY" || s == "NO ANSWER" || s == "NO DIALTONE" || s == "CONNECT" || strings.HasPrefix(s, "+CME ERROR:") || strings.HasPrefix(s, "+CMS ERROR:")
}
func (s *atSession) read(ctx context.Context, prompt bool) (string, error) {
	var result strings.Builder
	for {
		if len(s.pending) > 0 {
			if prompt && strings.TrimSpace(string(s.pending)) == ">" {
				s.pending = nil
				return result.String(), nil
			}
			if i := strings.IndexByte(string(s.pending), '\n'); i >= 0 {
				line := string(s.pending[:i+1])
				s.pending = s.pending[i+1:]
				result.WriteString(line)
				if result.Len() > 1<<20 {
					return result.String(), fail(3, "AT response exceeds 1 MiB")
				}
				if terminal(strings.TrimSpace(line)) {
					return result.String(), nil
				}
				continue
			}
		}
		if ctx.Err() != nil {
			return result.String(), ctx.Err()
		}
		b := make([]byte, 4096)
		n, e := s.port.Read(b)
		if n > 0 {
			s.pending = append(s.pending, b[:n]...)
		}
		if len(s.pending) > 1<<20 {
			return result.String(), fail(3, "AT line exceeds 1 MiB")
		}
		if e != nil && !wouldBlock(e) {
			return result.String(), e
		}
		if n == 0 {
			if err := pause(ctx, 10*time.Millisecond); err != nil {
				return result.String(), err
			}
		}
	}
}
func (s *atSession) write(ctx context.Context, b []byte) error {
	for len(b) > 0 {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		n, e := s.port.Write(b)
		b = b[n:]
		if e != nil && !wouldBlock(e) {
			return e
		}
		if n == 0 {
			if e = pause(ctx, 10*time.Millisecond); e != nil {
				return e
			}
		}
	}
	return nil
}
func (s *atSession) command(ctx context.Context, cmd string) (atResult, error) {
	if strings.ContainsAny(cmd, "\r\n\x00\x1a") || !strings.HasPrefix(strings.ToUpper(cmd), "AT") {
		return atResult{}, fail(2, "invalid AT command")
	}
	if e := s.write(ctx, []byte(cmd+"\r")); e != nil {
		return atResult{}, e
	}
	text, e := s.read(ctx, false)
	r := parseAT(text, cmd)
	if e != nil {
		return r, e
	}
	if r.Terminal != "OK" {
		return r, fail(5, "modem returned %s", r.Terminal)
	}
	return r, nil
}
func (a *app) openAT() (*atSession, error) {
	path := a.opts.Device
	if path == "" {
		return nil, fail(2, "set --at-device or RM500_AT_DEVICE; system capabilities lists candidates without opening them")
	}
	port, e := openPort(path, a.opts.Baud)
	if e != nil {
		return nil, fail(3, "open AT device: %v", e)
	}
	return &atSession{port: port}, nil
}
func (a *app) runAT(ctx context.Context, c command, v map[string]string) error {
	if c.Name == "sms send" {
		if _, err := makeSMSPDU(v["number"], v["text"]); err != nil {
			return err
		}
	}
	if c.Name == "sms send-pdu" {
		b, err := hex.DecodeString(v["pdu"])
		if err != nil || len(b) < 2 || int(b[0])+1 >= len(b) {
			return fail(2, "invalid complete SMS PDU")
		}
	}
	s, e := a.openAT()
	if e != nil {
		return e
	}
	defer s.port.Close()
	ctx, cancel := context.WithTimeout(ctx, a.opts.Timeout)
	defer cancel()
	if strings.HasPrefix(c.Name, "sms ") && (c.Name == "sms list" || c.Name == "sms read" || c.Name == "sms send" || c.Name == "sms send-pdu") {
		return a.sms(ctx, s, c.Name, v)
	}
	results := []atResult{}
	for _, step := range c.Steps {
		r, e := s.command(ctx, renderAT(step, v))
		if e != nil {
			return e
		}
		if !c.Mutates && c.Name != "calls status" && len(r.Lines) == 0 {
			return fail(5, "%s returned OK without data; capability is not exposed by this firmware", c.Name)
		}
		results = append(results, r)
	}
	result := map[string]any{"command": c.Name, "responses": results}
	if c.Name == "calls dial" || c.Name == "calls answer" {
		result["note"] = "Command accepted; this does not confirm an active call or working audio. Query calls status and observe call events."
	}
	return a.emit(result)
}
func (a *app) sms(ctx context.Context, s *atSession, name string, v map[string]string) (err error) {
	var result atResult
	// Emit success only after the previous SMS format has been restored.
	defer func() {
		if err == nil {
			err = a.emit(result)
		}
	}()
	old, e := s.command(ctx, "AT+CMGF?")
	if e != nil {
		return e
	}
	modes := old.Fields["+CMGF"]
	if len(modes) != 1 || (modes[0] != "0" && modes[0] != "1") {
		return fail(3, "invalid CMGF response")
	}
	if modes[0] != "0" {
		if _, e = s.command(ctx, "AT+CMGF=0"); e != nil {
			return e
		}
		defer func() {
			restore, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_, e := s.command(restore, "AT+CMGF="+modes[0])
			if err == nil && e != nil {
				err = fmt.Errorf("SMS operation completed but CMGF restoration failed: %w", e)
			}
		}()
	}
	if name == "sms list" || name == "sms read" {
		cmd := "AT+CMGL=4"
		if name == "sms read" {
			cmd = "AT+CMGR=" + v["index"]
		}
		r, e := s.command(ctx, cmd)
		if e != nil {
			return e
		}
		result = r
		return nil
	}
	pdu := v["pdu"]
	if name == "sms send" {
		pdu, e = makeSMSPDU(v["number"], v["text"])
		if e != nil {
			return e
		}
	}
	data, e := hex.DecodeString(pdu)
	if e != nil || len(data) < 2 || int(data[0])+1 >= len(data) {
		return fail(2, "invalid complete SMS PDU")
	}
	length := len(data) - 1 - int(data[0])
	cmd := "AT+CMGS=" + strconv.Itoa(length)
	if e = s.write(ctx, []byte(cmd+"\r")); e != nil {
		return e
	}
	text, e := s.read(ctx, true)
	if e != nil {
		abort, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = s.write(abort, []byte{0x1b})
		return e
	}
	if parseAT(text, cmd).Terminal != "" {
		return fail(5, "modem did not accept SMS prompt")
	}
	if e = s.write(ctx, append([]byte(pdu), 0x1a)); e != nil {
		return e
	}
	text, e = s.read(ctx, false)
	if e != nil {
		return e
	}
	r := parseAT(text, "")
	if r.Terminal != "OK" {
		return fail(5, "SMS failed: %s", r.Terminal)
	}
	result = r
	return nil
}
func makeSMSPDU(number, text string) (string, error) {
	digits := strings.TrimPrefix(number, "+")
	if len(digits) == 0 || len(digits) > 20 || strings.ContainsAny(digits, "*#") {
		return "", fail(2, "SMS destination must contain at most 20 decimal digits")
	}
	for _, r := range digits {
		if r < '0' || r > '9' {
			return "", fail(2, "invalid SMS destination")
		}
	}
	units := utf16.Encode([]rune(text))
	if len(units) == 0 || len(units) > 70 {
		return "", fail(2, "SMS text must contain 1..70 UTF-16 code units; use send-pdu for multipart")
	}
	ton := byte(0x81)
	if strings.HasPrefix(number, "+") {
		ton = 0x91
	}
	b := []byte{0, 1, 0, byte(len(digits)), ton}
	if len(digits)%2 != 0 {
		digits += "F"
	}
	for i := 0; i < len(digits); i += 2 {
		v, _ := strconv.ParseUint(string([]byte{digits[i+1], digits[i]}), 16, 8)
		b = append(b, byte(v))
	}
	b = append(b, 0, 8, byte(len(units)*2))
	for _, u := range units {
		b = append(b, byte(u>>8), byte(u))
	}
	return strings.ToUpper(hex.EncodeToString(b)), nil
}
func pause(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
func positiveDuration(s string) (time.Duration, error) {
	d, e := time.ParseDuration(s)
	if e != nil || d < 10*time.Millisecond {
		return 0, fail(2, "duration must be at least 10ms")
	}
	return d, nil
}
