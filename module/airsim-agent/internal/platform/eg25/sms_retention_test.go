package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/hal"
	"context"
	"encoding/hex"
	"fmt"
	"github.com/warthog618/sms"
	"strings"
	"testing"
	"time"
)

type retentionPort struct {
	lines   []string
	storage string
	deletes []string
	fail    bool
}

func (p *retentionPort) Done() <-chan struct{} { return nil }
func (p *retentionPort) Query(_ context.Context, cmd string) ([]string, error) {
	if cmd != "AT+CPMS?" {
		return nil, at.ErrInvalid
	}
	return []string{p.storage}, nil
}
func (p *retentionPort) Command(_ context.Context, cmd, payload string) ([]string, error) {
	if cmd == "AT+CMGL=4" {
		return p.lines, nil
	}
	if !strings.HasPrefix(cmd, "AT+CMGD=") || payload != "" {
		panic("unexpected write")
	}
	p.deletes = append(p.deletes, cmd)
	if p.fail {
		return nil, at.ErrQuery
	}
	return nil, nil
}
func incomingLines(t *testing.T, text string, indices []int, received time.Time) []string {
	t.Helper()
	parts, err := sms.Encode([]byte(text), sms.AsDeliver, sms.From("+12025550123"))
	if err != nil || len(parts) != len(indices) {
		t.Fatal("bad fixture segments")
	}
	var lines []string
	for i, p := range parts {
		p.SCTS.Time = received
		raw, err := p.MarshalBinary()
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, fmt.Sprintf("+CMGL: %d,1,,%d", indices[i], len(raw)), "00"+hex.EncodeToString(raw))
	}
	return lines
}
func TestFullSMSStoreReclaimsOldestCompleteGroupAfterPriorPoll(t *testing.T) {
	old := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	// Slot numbers deliberately disagree with timestamp order. Old multipart
	// must be deleted as a whole, keeping the newer single-segment message.
	lines := incomingLines(t, "new", []int{1}, old.Add(time.Hour))
	lines = append(lines, incomingLines(t, strings.Repeat("你", 80), []int{9, 10}, old)...)
	p := &retentionPort{lines: lines, storage: `+CPMS: "ME",3,3,"ME",3,3,"ME",3,3`}
	s := &Session{at: p, sms: OpenSMSLedger(""), events: make(chan hal.ControlEvent, 10), overflow: make(chan struct{}, 1)}
	if err := s.refreshSMS(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(p.deletes) != 0 || len(s.events) != 2 {
		t.Fatal("first observation was deleted or failed to emit")
	}
	if err := s.refreshSMS(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Join(p.deletes, ",") != "AT+CMGD=9,AT+CMGD=10" || len(s.events) != 2 {
		t.Fatal("wrong group deleted or incoming duplicated")
	}
}
func TestSMSRetentionKeepsNonFullNewIncompleteAndUndecodableRecords(t *testing.T) {
	stamp := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	partial := incomingLines(t, strings.Repeat("你", 80), []int{1, 2}, stamp)[:2]
	lines := append(partial, "+CMGL: 3,1,,3", "000400")
	lines = append(lines, incomingLines(t, "old", []int{4}, stamp.Add(time.Hour))...)
	lines = append(lines, incomingLines(t, "delayed-new", []int{5}, stamp.Add(-time.Hour))...)
	messages, err := decodeSMS(lines)
	if err != nil || len(messages) != 2 {
		t.Fatal("fixture decode")
	}
	p := &retentionPort{storage: `+CPMS: "ME",4,5,"ME",4,5,"ME",4,5`}
	s := &Session{at: p, previousSMS: map[string]bool{messages[0].key: true}}
	if n, err := s.reclaimSMS(context.Background(), messages); err != nil || n != 0 || len(p.deletes) != 0 {
		t.Fatal("non-full store deleted")
	}
	p.storage = `+CPMS: "ME",4,4,"ME",4,4,"ME",4,4`
	if n, err := s.reclaimSMS(context.Background(), messages); err != nil || n != 1 || strings.Join(p.deletes, ",") != "AT+CMGD=4" {
		t.Fatal("new or incomplete message deleted")
	}
	p.deletes = nil
	p.fail = true
	if n, err := s.reclaimSMS(context.Background(), messages); err == nil || n != 0 || len(p.deletes) != 1 {
		t.Fatal("failed deletion retried")
	}
}
