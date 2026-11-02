package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

type diagnosticPort struct {
	mu       sync.Mutex
	commands []string
	gate     chan struct{}
	err      error
}

func (p *diagnosticPort) Query(ctx context.Context, command string) ([]string, error) {
	p.mu.Lock()
	p.commands = append(p.commands, command)
	p.mu.Unlock()
	select {
	case <-p.gate:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if p.err != nil {
		return nil, p.err
	}
	switch command {
	case "AT+CPMS?":
		return []string{`+CPMS: "SM",20,20,"ME",0,255,"SM",20,20`}, nil
	case "AT+CNMI?":
		return []string{`+CNMI: 2,1,0,0,0`}, nil
	default:
		return nil, errors.New("unexpected command")
	}
}
func awaitDiagnostic(t *testing.T, d *SMSDiagnostics) SMSDiagnosticReport {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		r := d.View()
		if r.State == "ready" {
			return r
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("diagnostic did not complete")
	return SMSDiagnosticReport{}
}
func TestSMSDiagnosticsReadOnlyBoundedAndPrivate(t *testing.T) {
	p := &diagnosticPort{gate: make(chan struct{})}
	d := NewSMSDiagnostics(context.Background(), p)
	for i := 0; i < 100; i++ {
		if d.View().State != "collecting" {
			t.Fatal("collection should remain pending")
		}
	}
	d.recordPoll(12, 10, 0, nil)
	close(p.gate)
	r := awaitDiagnostic(t, d)
	if r.Storage.Receive == nil || r.Storage.Receive.Used != 20 || r.Storage.Receive.Total != 20 || r.Poll.Decoded != 10 || r.Poll.Observed == nil {
		t.Fatal("lost counts")
	}
	for i := 0; i < 100; i++ {
		d.View()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if strings.Join(p.commands, ",") != "AT+CPMS?,AT+CNMI?" {
		t.Fatal("repeated collection or unexpected command")
	}
	b, err := json.Marshal(r)
	if err != nil || strings.Contains(string(b), "sender") || strings.Contains(string(b), "text") || strings.Contains(string(b), "token") {
		t.Fatal("unexpected payload")
	}
}
func TestSMSDiagnosticsRejectRawAndMalformedValues(t *testing.T) {
	for _, line := range []string{`+CPMS: "PRIVATE",1,2,"ME",0,5,"SM",1,2`, `+CPMS: "SM",3,2,"ME",0,5,"SM",1,2`, `+CPMS: "SM",-1,2,"ME",0,5,"SM",1,2`, `+CPMS: "SM",1,2`} {
		r, err := parseSMSStorage([]string{line})
		if err == nil || r.Read != nil || r.Receive != nil {
			t.Fatal("malformed storage escaped parser")
		}
	}
	for _, line := range []string{"+CNMI: 2,1,0,0,2", "+CNMI: secret", "+CNMI: 2,1,0,0,0,1"} {
		r, err := parseSMSNotification([]string{line})
		if err == nil || r.Values != nil {
			t.Fatal("invalid notification escaped parser")
		}
	}
	p := &diagnosticPort{gate: make(chan struct{}), err: errors.New("sensitive raw failure")}
	close(p.gate)
	d := NewSMSDiagnostics(context.Background(), p)
	r := awaitDiagnostic(t, d)
	b, _ := json.Marshal(r)
	if r.Storage.Error != "unavailable" || strings.Contains(string(b), "sensitive") {
		t.Fatal("raw error exposed")
	}
	d.recordPoll(0, 0, 0, at.ErrQuery)
	if d.View().Poll.Error != "query_failed" {
		t.Fatal("missing fixed poll error")
	}
}
