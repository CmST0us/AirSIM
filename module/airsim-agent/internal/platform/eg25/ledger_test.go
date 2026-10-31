package eg25

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSMSLedgerSurvivesRestartWithoutStoringContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eg25-sms-seen")
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	l := OpenSMSLedger(path)
	if got := l.Reconcile([]string{"pdu-a:", "pdu-b:"}); len(got) != 2 {
		t.Fatal("first listing must report every message")
	}
	if got := l.Reconcile([]string{"pdu-a:", "pdu-b:"}); len(got) != 0 {
		t.Fatal("repeated listing reported again")
	}
	// A transient short listing does not make the omitted message new again.
	l.Reconcile(nil)
	restarted := OpenSMSLedger(path)
	got := restarted.Reconcile([]string{"pdu-a:", "pdu-b:", "pdu-c:"})
	if len(got) != 1 || got[0] != "pdu-c:" {
		t.Fatalf("restart reported %v", got)
	}
	data, err := os.ReadFile(path)
	if err != nil || strings.Contains(string(data), "pdu-") || len(strings.Fields(string(data))) != 3 {
		t.Fatal("ledger must hold only digests")
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0600 {
		t.Fatal("ledger permissions")
	}
}

func TestSMSLedgerFirstStartRecordsExistingMessagesOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eg25-sms-seen")
	l := OpenSMSLedger(path)
	if got := l.Reconcile([]string{"pdu-a:"}); len(got) != 0 {
		t.Fatal("existing SIM messages reported again on first start")
	}
	if got := l.Reconcile([]string{"pdu-a:", "pdu-b:"}); len(got) != 1 || got[0] != "pdu-b:" {
		t.Fatalf("new message after baseline: %v", got)
	}
	if got := OpenSMSLedger(path).Reconcile([]string{"pdu-a:", "pdu-b:"}); len(got) != 0 {
		t.Fatal("baseline not persisted")
	}
}
