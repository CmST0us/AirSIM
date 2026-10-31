package eg25

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sort"
	"strings"
	"sync"
)

// SMSLedger remembers which stored SIM messages were already reported, across
// control sessions and Agent restarts. It keeps only PDU digests, never content.
type SMSLedger struct {
	mu       sync.Mutex
	path     string
	seen     map[string]bool
	baseline bool
}

// OpenSMSLedger loads the ledger at path; an empty path keeps it in memory.
func OpenSMSLedger(path string) *SMSLedger {
	l := &SMSLedger{path: path, seen: map[string]bool{}}
	if path == "" {
		return l
	}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		// First start with a ledger: messages already on the SIM were reported
		// by earlier runs, so the first listing only records them.
		l.baseline = true
		return l
	}
	if err != nil {
		return l
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if line := strings.TrimSpace(scanner.Text()); len(line) == sha256.Size*2 {
			l.seen[line] = true
		}
	}
	return l
}

func smsDigest(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

// ledgerLimit is far above SIM and module storage, so pruning never forgets a
// message that a transient short listing temporarily omitted.
const ledgerLimit = 2048

// Reconcile returns the keys not reported before and records them.
func (l *SMSLedger) Reconcile(keys []string) []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	current := map[string]bool{}
	var fresh []string
	for _, key := range keys {
		d := smsDigest(key)
		if !l.seen[d] && !current[d] {
			fresh = append(fresh, key)
		}
		current[d] = true
	}
	if l.baseline {
		l.baseline = false
		l.seen = current
		l.save()
		return nil
	}
	if len(fresh) == 0 {
		return nil
	}
	if len(l.seen)+len(fresh) > ledgerLimit {
		l.seen = current
	} else {
		for d := range current {
			l.seen[d] = true
		}
	}
	l.save()
	return fresh
}

func (l *SMSLedger) save() {
	if l.path == "" {
		return
	}
	lines := make([]string, 0, len(l.seen))
	for d := range l.seen {
		lines = append(lines, d)
	}
	sort.Strings(lines)
	tmp := l.path + ".tmp"
	data := strings.Join(lines, "\n")
	if len(lines) > 0 {
		data += "\n"
	}
	if os.WriteFile(tmp, []byte(data), 0600) != nil {
		return
	}
	if os.Rename(tmp, l.path) != nil {
		os.Remove(tmp)
	}
}
