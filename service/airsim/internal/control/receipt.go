package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"encoding/json"
	"regexp"
	"time"
)

type Receipt struct {
	ID      string    `json:"command_id"`
	Action  string    `json:"action"`
	State   string    `json:"state"`
	Code    string    `json:"result_code"`
	Call    string    `json:"call_id,omitempty"`
	Message string    `json:"message_id,omitempty"`
	Updated time.Time `json:"updated_at"`
}

func (s *Server) receipt(p *peer, b []byte) bool {
	var payload struct {
		ID      string          `json:"command_id"`
		Status  int             `json:"status_code"`
		Receipt json.RawMessage `json:"receipt"`
	}
	if wire.DecodeNullable(b, &payload, "receipt") != nil || !wire.UUID.MatchString(payload.ID) || payload.Status < 100 || payload.Status > 599 {
		return false
	}
	ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
	defer cancel()
	var action, epoch string
	if s.db.QueryRow(ctx, "SELECT action,connection_epoch FROM commands WHERE id=$1 AND module_id=$2", payload.ID, p.module).Scan(&action, &epoch) != nil {
		return false
	}
	var r Receipt
	state := "outcome_unknown"
	if string(payload.Receipt) != "null" {
		if wire.Decode(payload.Receipt, &r, "command_id", "action", "state", "result_code", "updated_at") != nil || r.ID != payload.ID || r.Action != action || len(r.Code) > 64 || !regexp.MustCompile(`^[a-z_]*$`).MatchString(r.Code) || (r.Message != "" && !wire.UUID.MatchString(r.Message)) {
			return false
		}
		switch r.State {
		case "prepared", "dispatched":
			state = "dispatched"
		case "accepted", "failed", "observed", "expired":
			state = "completed"
		case "outcome_unknown":
			state = "outcome_unknown"
		default:
			return false
		}
	}
	tx, e := s.db.Begin(ctx)
	if e != nil {
		return false
	}
	defer tx.Rollback(ctx)
	if r.Call != "" {
		if !wire.UUID.MatchString(r.Call) {
			return false
		}
		_, e = tx.Exec(ctx, "UPDATE reservations SET call_id=$1 WHERE module_id=$2 AND command_id=$3 AND (call_id IS NULL OR call_id=$1)", r.Call, p.module, payload.ID)
		if e != nil {
			return false
		}
	}
	if r.State == "failed" || r.State == "expired" {
		if _, e = tx.Exec(ctx, "DELETE FROM reservations WHERE module_id=$1 AND command_id=$2", p.module, payload.ID); e != nil {
			return false
		}
	}
	if _, e = tx.Exec(ctx, "UPDATE commands SET state=$1,receipt=$2 WHERE id=$3 AND module_id=$4", state, payload.Receipt, payload.ID, p.module); e != nil {
		return false
	}
	return tx.Commit(ctx) == nil
}
func (s *Server) releaseDisconnected(p *peer) {
	ctx, cancel := context.WithTimeout(p.ctx, time.Second)
	defer cancel()
	for _, c := range p.snapshot.Calls.Calls {
		if c.State == "disconnected" {
			_, _ = s.db.Exec(ctx, "DELETE FROM reservations WHERE module_id=$1 AND call_id=$2 AND agent_boot_id=$3 AND backend_epoch=$4", p.module, c.ID, p.boot, p.backend)
		}
	}
}
func (s *Server) queryReceipts(p *peer) {
	ctx, cancel := context.WithTimeout(p.ctx, time.Second)
	defer cancel()
	rows, e := s.db.Query(ctx, "SELECT id FROM commands WHERE module_id=$1 AND state='outcome_unknown' ORDER BY created_at DESC LIMIT 64", p.module)
	if e != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			s.enqueue(p, "receipt_query", map[string]string{"command_id": id})
		}
	}
}
