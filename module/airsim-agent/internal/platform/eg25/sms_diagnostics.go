package eg25

import (
	"airsim.local/airsim-agent/internal/at"
	"airsim.local/airsim-agent/internal/platform/atmodem"
	"context"
	"encoding/csv"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"
)

type SMSStorage struct {
	Name  string `json:"name"`
	Used  int    `json:"used"`
	Total int    `json:"total"`
}
type SMSStorageReport struct {
	Error   string      `json:"error"`
	Read    *SMSStorage `json:"read"`
	Write   *SMSStorage `json:"write"`
	Receive *SMSStorage `json:"receive"`
}
type SMSNotificationReport struct {
	Error  string `json:"error"`
	Values []int  `json:"values"`
}
type SMSPollReport struct {
	Observed     *time.Time `json:"observed_at"`
	Error        string     `json:"error"`
	Entries      int        `json:"stored_entries"`
	Decoded      int        `json:"decoded_messages"`
	Emitted      int        `json:"new_messages"`
	CleanupError string     `json:"cleanup_error"`
}
type SMSDiagnosticReport struct {
	Schema       int                   `json:"schema_version"`
	State        string                `json:"state"`
	Observed     *time.Time            `json:"observed_at"`
	Storage      SMSStorageReport      `json:"storage"`
	Notification SMSNotificationReport `json:"notification"`
	Poll         SMSPollReport         `json:"poll"`
}

// SMSDiagnostics keeps counts and fixed error codes only. Queries use the
// Agent's existing serialized AT manager; no second port owner is introduced.
type SMSDiagnostics struct {
	mu     sync.Mutex
	ctx    context.Context
	port   atmodem.Querier
	report SMSDiagnosticReport
}

func NewSMSDiagnostics(ctx context.Context, port atmodem.Querier) *SMSDiagnostics {
	return &SMSDiagnostics{ctx: ctx, port: port, report: SMSDiagnosticReport{Schema: 1, State: "idle"}}
}

// View starts at most one read-only collection every 15 seconds. The HTTP
// request never owns an AT transaction: closing the browser cannot interrupt
// an in-flight command or leave the transaction fence unresolved.
func (d *SMSDiagnostics) View() SMSDiagnosticReport {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.report.State != "collecting" && (d.report.Observed == nil || time.Since(*d.report.Observed) >= 15*time.Second) {
		d.report.State = "collecting"
		go d.collect()
	}
	return d.report
}

func smsDiagnosticError(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, at.ErrQuery):
		return "query_failed"
	case errors.Is(err, at.ErrInvalid):
		return "invalid_response"
	case errors.Is(err, at.ErrDesynchronized):
		return "at_desynchronized"
	default:
		return "unavailable"
	}
}

func diagnosticFields(lines []string, prefix string, count int) ([]string, error) {
	if len(lines) != 1 || !strings.HasPrefix(lines[0], prefix) {
		return nil, at.ErrInvalid
	}
	r := csv.NewReader(strings.NewReader(strings.TrimSpace(strings.TrimPrefix(lines[0], prefix))))
	r.TrimLeadingSpace = true
	fields, err := r.Read()
	if err != nil || len(fields) != count {
		return nil, at.ErrInvalid
	}
	return fields, nil
}

func parseSMSStorage(lines []string) (SMSStorageReport, error) {
	var result SMSStorageReport
	f, err := diagnosticFields(lines, "+CPMS:", 9)
	if err != nil {
		return result, err
	}
	stores := make([]SMSStorage, 3)
	for i := range stores {
		name := f[i*3]
		if name != "SM" && name != "ME" && name != "MT" {
			return result, at.ErrInvalid
		}
		used, e1 := strconv.Atoi(strings.TrimSpace(f[i*3+1]))
		total, e2 := strconv.Atoi(strings.TrimSpace(f[i*3+2]))
		if e1 != nil || e2 != nil || used < 0 || total < used || total > 1000000 {
			return result, at.ErrInvalid
		}
		stores[i] = SMSStorage{name, used, total}
	}
	result.Read, result.Write, result.Receive = &stores[0], &stores[1], &stores[2]
	return result, nil
}

func parseSMSNotification(lines []string) (SMSNotificationReport, error) {
	var result SMSNotificationReport
	f, err := diagnosticFields(lines, "+CNMI:", 5)
	if err != nil {
		return result, err
	}
	values := make([]int, 5)
	limits := []int{3, 3, 3, 2, 1}
	for i := range values {
		v, err := strconv.Atoi(strings.TrimSpace(f[i]))
		if err != nil || v < 0 || v > limits[i] {
			return result, at.ErrInvalid
		}
		values[i] = v
	}
	result.Values = values
	return result, nil
}

func (d *SMSDiagnostics) collect() {
	storage := SMSStorageReport{Error: "unavailable"}
	notification := SMSNotificationReport{Error: "unavailable"}
	if d.port != nil {
		lines, err := d.port.Query(d.ctx, "AT+CPMS?")
		if err == nil {
			storage, err = parseSMSStorage(lines)
		}
		storage.Error = smsDiagnosticError(err)
		lines, err = d.port.Query(d.ctx, "AT+CNMI?")
		if err == nil {
			notification, err = parseSMSNotification(lines)
		}
		notification.Error = smsDiagnosticError(err)
	}
	now := time.Now().UTC()
	d.mu.Lock()
	d.report.Storage, d.report.Notification = storage, notification
	d.report.Observed, d.report.State = &now, "ready"
	d.mu.Unlock()
}

func (d *SMSDiagnostics) recordPoll(entries, decoded, emitted int, err error) {
	if d == nil {
		return
	}
	now := time.Now().UTC()
	d.mu.Lock()
	d.report.Poll = SMSPollReport{Observed: &now, Error: smsDiagnosticError(err), Entries: entries, Decoded: decoded, Emitted: emitted}
	d.mu.Unlock()
}

func (d *SMSDiagnostics) recordCleanupError(err error) {
	if d == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.report.Poll.CleanupError = smsDiagnosticError(err)
}
