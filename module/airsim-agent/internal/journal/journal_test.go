package journal

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func record(n int, state string) Record {
	return Record{CommandID: fmt.Sprintf("%08x-1111-4111-8111-111111111111", n), Digest: strings.Repeat("a", 64), Action: "sms.send", State: state, Code: "", CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC(), BootID: "b1111111-1111-4111-8111-111111111111", Epoch: "c1111111-1111-4111-8111-111111111111"}
}
func TestCrashRecoveryNeverReplays(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	for i, state := range []string{"prepared", "dispatched", "accepted", "observed", "outcome_unknown"} {
		if e = s.Put(record(i, state)); e != nil {
			t.Fatal(e)
		}
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	for i, want := range []string{"expired", "outcome_unknown", "accepted", "observed", "outcome_unknown"} {
		r, ok := s.Get(record(i, "").CommandID)
		if !ok || r.State != want {
			t.Fatal("incorrect recovered state")
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, "commands.json"))
	for _, forbidden := range []string{"number", "text", "tones", "recipient", "sender"} {
		if strings.Contains(string(b), `"`+forbidden+`"`) {
			t.Fatal("private payload persisted")
		}
	}
}
func TestInvalidJournalFailsClosed(t *testing.T) {
	for _, kind := range []string{"corrupt", "symlink", "partial", "case"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			os.Chmod(dir, 0700)
			p := filepath.Join(dir, "commands.json")
			switch kind {
			case "corrupt":
				os.WriteFile(p, []byte(`{`), 0600)
			case "symlink":
				target := filepath.Join(t.TempDir(), "target")
				os.WriteFile(target, []byte(`{"schema_version":1,"records":[]}`), 0600)
				os.Symlink(target, p)
			case "partial":
				os.WriteFile(filepath.Join(dir, ".commands-partial"), []byte("x"), 0600)
			case "case":
				os.WriteFile(p, []byte(`{"Schema_version":1,"records":[]}`), 0600)
			}
			s, e := Open(dir)
			if e == nil {
				t.Fatal("invalid journal accepted")
			}
			if e = s.Put(record(1, "prepared")); e == nil {
				t.Fatal("invalid journal allowed writes")
			}
		})
	}
}
func TestCapacityAndWriteFailure(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.write = func([]byte) error { return nil }
	for i := 0; i < Capacity; i++ {
		if e = s.Put(record(i, "prepared")); e != nil {
			t.Fatal(e)
		}
	}
	if e = s.Put(record(Capacity, "prepared")); e != ErrFull {
		t.Fatal("capacity not enforced")
	}
	if _, ok := s.Get(record(0, "").CommandID); !ok {
		t.Fatal("old record evicted")
	}
	s, e = Open(filepath.Join(t.TempDir(), "state"))
	if e != nil {
		t.Fatal(e)
	}
	s.write = func([]byte) error { return errors.New("injected") }
	if e = s.Put(record(1, "dispatched")); e != ErrInvalid {
		t.Fatal("write failure accepted")
	}
	if _, ok := s.Get(record(1, "").CommandID); ok {
		t.Fatal("failed write published")
	}
	if s.Remaining() != 0 {
		t.Fatal("failed store not closed")
	}
}
func TestConcurrentPersistenceAndDigestConflict(t *testing.T) {
	s, e := Open(filepath.Join(t.TempDir(), "state"))
	if e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			if e := s.Put(record(n, "prepared")); e != nil {
				t.Error(e)
			}
		}(i)
	}
	wg.Wait()
	b, e := os.ReadFile(filepath.Join(s.dir, "commands.json"))
	if e != nil {
		t.Fatal(e)
	}
	var f fileData
	if json.Unmarshal(b, &f) != nil || len(f.Records) != 16 {
		t.Fatal("concurrent records lost")
	}
	r := record(0, "prepared")
	r.Digest = strings.Repeat("b", 64)
	if e = s.Put(r); e != ErrConflict {
		t.Fatal("digest conflict accepted")
	}
}
