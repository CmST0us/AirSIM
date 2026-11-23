package journal

import (
	"airsim.local/airsim-agent/internal/strictjson"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

const Capacity = 1024

var ErrInvalid = errors.New("journal_unavailable")
var ErrFull = errors.New("journal_full")
var ErrConflict = errors.New("command_conflict")
var idPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type Record struct {
	CommandID string    `json:"command_id"`
	Digest    string    `json:"request_digest"`
	Action    string    `json:"action"`
	State     string    `json:"state"`
	Code      string    `json:"result_code"`
	CallID    string    `json:"call_id,omitempty"`
	MessageID string    `json:"message_id,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	BootID    string    `json:"agent_boot_id"`
	Epoch     string    `json:"backend_epoch"`
}
type fileData struct {
	Schema  int      `json:"schema_version"`
	Records []Record `json:"records"`
}
type Store struct {
	mu      sync.Mutex
	dir     string
	records map[string]Record
	failed  bool
	write   func([]byte) error
}

func Open(dir string) (*Store, error) {
	s, e := open(dir)
	if e != nil && s != nil {
		s.failed = true
	}
	return s, e
}
func open(dir string) (*Store, error) {
	s := &Store{dir: dir, records: map[string]Record{}}
	s.write = s.atomicWrite
	if e := os.MkdirAll(dir, 0700); e != nil {
		return s, ErrInvalid
	}
	info, e := os.Lstat(dir)
	if e != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return s, ErrInvalid
	}
	left, e := filepath.Glob(filepath.Join(dir, ".commands-*"))
	if e != nil {
		return s, ErrInvalid
	}
	path := filepath.Join(dir, "commands.json")
	info, e = os.Lstat(path)
	if os.IsNotExist(e) {
		if len(left) != 0 {
			return s, ErrInvalid
		}
		return s, nil
	}
	if e != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 2<<20 {
		return s, ErrInvalid
	}
	// If commands.json exists and is intact, clean orphaned regular temp files
	// left by an interrupted write or sudden power loss instead of bricking.
	for _, orphan := range left {
		oi, oe := os.Lstat(orphan)
		if oe != nil || !oi.Mode().IsRegular() {
			return s, ErrInvalid
		}
		if os.Remove(orphan) != nil {
			return s, ErrInvalid
		}
	}
	if len(left) != 0 {
		if d, de := os.Open(dir); de == nil {
			_ = d.Sync()
			_ = d.Close()
		}
	}
	f, e := os.Open(path)
	if e != nil {
		return s, ErrInvalid
	}
	b, e := io.ReadAll(io.LimitReader(f, (2<<20)+1))
	f.Close()
	if e != nil || len(b) > 2<<20 {
		return s, ErrInvalid
	}
	fields, e := strictjson.Object(b, []string{"schema_version", "records"}, nil)
	if e != nil {
		return s, ErrInvalid
	}
	var schema int
	if json.Unmarshal(fields["schema_version"], &schema) != nil || schema != 1 {
		return s, ErrInvalid
	}
	var raw []json.RawMessage
	if json.Unmarshal(fields["records"], &raw) != nil || len(raw) > Capacity {
		return s, ErrInvalid
	}
	changed := false
	for _, b := range raw {
		var r Record
		if strictjson.Decode(b, []string{"command_id", "request_digest", "action", "state", "result_code", "created_at", "updated_at", "agent_boot_id", "backend_epoch"}, []string{"call_id", "message_id"}, &r) != nil || !valid(r) {
			return s, ErrInvalid
		}
		if _, ok := s.records[r.CommandID]; ok {
			return s, ErrInvalid
		}
		switch r.State {
		case "prepared":
			r.State = "expired"
			r.Code = "restart_before_dispatch"
			r.UpdatedAt = time.Now().UTC()
			changed = true
		case "dispatched":
			r.State = "outcome_unknown"
			r.Code = "restart_after_dispatch"
			r.UpdatedAt = time.Now().UTC()
			changed = true
		}
		s.records[r.CommandID] = r
	}
	if changed {
		if e = s.persist(s.records); e != nil {
			s.failed = true
			return s, ErrInvalid
		}
	}
	return s, nil
}
func valid(r Record) bool {
	if !idPattern.MatchString(r.CommandID) || !idPattern.MatchString(r.BootID) || !idPattern.MatchString(r.Epoch) || r.CreatedAt.IsZero() || r.UpdatedAt.IsZero() {
		return false
	}
	if len(r.Digest) != 64 {
		return false
	}
	if _, e := hex.DecodeString(r.Digest); e != nil {
		return false
	}
	if r.CallID != "" && !idPattern.MatchString(r.CallID) {
		return false
	}
	if r.MessageID != "" && !idPattern.MatchString(r.MessageID) {
		return false
	}
	switch r.Action {
	case "call.dial", "call.answer", "call.hangup", "call.dtmf", "sms.send":
	default:
		return false
	}
	switch r.State {
	case "prepared", "dispatched", "accepted", "observed", "failed", "outcome_unknown", "expired":
	default:
		return false
	}
	return len(r.Code) <= 64 && regexp.MustCompile(`^[a-z_]*$`).MatchString(r.Code)
}
func (s *Store) Get(id string) (Record, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.records[id]
	return r, ok
}
func (s *Store) Remaining() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed {
		return 0
	}
	return uint64(Capacity - len(s.records))
}
func terminalState(state string) bool {
	switch state {
	case "accepted", "observed", "failed", "outcome_unknown", "expired":
		return true
	default:
		return false
	}
}
func (s *Store) Put(r Record) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed || !valid(r) {
		return ErrInvalid
	}
	evictID := ""
	if old, ok := s.records[r.CommandID]; ok {
		if old.Digest != r.Digest {
			return ErrConflict
		}
	} else if len(s.records) >= Capacity {
		// Evict the oldest completed/terminal record so long-lived devices never
		// hit a permanent 1024-command wall; in-flight prepared/dispatched
		// records are never evicted.
		var oldest time.Time
		for id, rec := range s.records {
			if !terminalState(rec.State) {
				continue
			}
			if evictID == "" || rec.UpdatedAt.Before(oldest) || (rec.UpdatedAt.Equal(oldest) && id < evictID) {
				evictID = id
				oldest = rec.UpdatedAt
			}
		}
		if evictID == "" {
			return ErrFull
		}
	}
	next := make(map[string]Record, len(s.records)+1)
	for k, v := range s.records {
		if k == evictID {
			continue
		}
		next[k] = v
	}
	next[r.CommandID] = r
	if e := s.persist(next); e != nil {
		return ErrInvalid
	}
	s.records = next
	return nil
}
func (s *Store) persist(records map[string]Record) error {
	f := fileData{Schema: 1, Records: []Record{}}
	for _, r := range records {
		f.Records = append(f.Records, r)
	}
	b, e := json.Marshal(f)
	if e != nil || len(b) > 2<<20 {
		return ErrInvalid
	}
	return s.write(b)
}
func (s *Store) atomicWrite(b []byte) error {
	f, e := os.CreateTemp(s.dir, ".commands-*")
	if e != nil {
		return e
	}
	name := f.Name()
	renamed := false
	defer func() {
		if !renamed {
			_ = os.Remove(name)
		}
	}()
	defer f.Close()
	if e = f.Chmod(0600); e != nil {
		return e
	}
	if _, e = io.Copy(f, bytes.NewReader(b)); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	if e = os.Rename(name, filepath.Join(s.dir, "commands.json")); e != nil {
		return e
	}
	renamed = true
	d, e := os.Open(s.dir)
	if e != nil {
		return e
	}
	defer d.Close()
	return d.Sync()
}
