package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"strings"
	"time"
)

func (s *Server) client(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		wire.Error(w, 401, "unauthorized")
		return
	}
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !wire.Hex.MatchString(auth) {
		wire.Error(w, 401, "unauthorized")
		return
	}
	var user, client string
	if s.db.QueryRow(ctx, "SELECT c.user_id,c.id FROM clients c WHERE c.token_hash=$1 AND "+sessionAuthorization, wire.Hash(auth)).Scan(&user, &client) != nil {
		wire.Error(w, 401, "unauthorized")
		return
	}
	if r.URL.Path == "/v2/push/registration" {
		s.pushRegistration(w, r, user, client)
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/v2/modules"), "/"), "/")
	if parts[0] == "" && r.Method == "GET" {
		s.list(w, r, user, client)
		return
	}
	module := parts[0]
	var exists bool
	if !wire.UUID.MatchString(module) || s.db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM modules m JOIN clients c ON c.id=$3 WHERE m.id=$1 AND m.user_id=$2 AND NOT m.revoked AND (c.module_id IS NULL OR c.module_id=m.id))", module, user, client).Scan(&exists) != nil || !exists {
		wire.Error(w, 404, "not_found")
		return
	}
	if len(parts) == 2 && parts[1] == "usb-authorization" && r.Method == "POST" {
		s.usbAuthorization(w, r, client, module)
		return
	}
	if len(parts) == 2 && parts[1] == "commands" && r.Method == "POST" {
		s.command(w, r, user, client, module)
		return
	}
	if len(parts) == 3 && parts[1] == "commands" && r.Method == "GET" {
		var rec Record
		if !wire.UUID.MatchString(parts[2]) || s.db.QueryRow(ctx, "SELECT id,state,generation,receipt FROM commands WHERE id=$1 AND module_id=$2 AND user_id=$3", parts[2], module, user).Scan(&rec.ID, &rec.State, &rec.Generation, &rec.Receipt) != nil {
			wire.Error(w, 404, "not_found")
			return
		}
		wire.JSON(w, 200, rec)
		return
	}
	if len(parts) >= 4 && parts[1] == "calls" && parts[3] == "media-sessions" {
		s.mediaAPI(w, r, user, client, module, parts)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.last[module]
	online := s.peers[module] != nil
	var last any
	epoch, boot, backend := "", "", ""
	var snap any
	if p != nil {
		last = p.last.UTC()
		epoch = p.epoch
		boot = p.boot
		backend = p.backend
		snap = visibleSnapshot(p, online)
	}
	if len(parts) == 2 && r.Method == "GET" {
		switch parts[1] {
		case "snapshot":
			wire.JSON(w, 200, map[string]any{"server_id": s.cfg.Server, "module_id": module, "online": online, "last_seen": last, "connection_epoch": epoch, "snapshot": snap})
			return
		case "messages":
			msg := Messages{Messages: []Message{}}
			if p != nil {
				msg = p.messages
				if msg.Messages == nil {
					msg.Messages = []Message{}
				}
			}
			wire.JSON(w, 200, map[string]any{"server_id": s.cfg.Server, "module_id": module, "agent_boot_id": boot, "backend_epoch": backend, "online": online, "inbox_gap": msg.Gap, "inbox_dropped": msg.Dropped, "messages": msg.Messages})
			return
		}
	}
	wire.Error(w, 404, "not_found")
}
func (s *Server) list(w http.ResponseWriter, r *http.Request, user, client string) {
	rows, e := s.db.Query(r.Context(), "SELECT m.id FROM modules m JOIN clients c ON c.id=$2 WHERE m.user_id=$1 AND NOT m.revoked AND (c.module_id IS NULL OR c.module_id=m.id) ORDER BY m.id", user, client)
	if e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer rows.Close()
	out := []any{}
	s.mu.Lock()
	defer s.mu.Unlock()
	for rows.Next() {
		var id string
		if rows.Scan(&id) != nil {
			wire.Error(w, 503, "database_unavailable")
			return
		}
		v := s.moduleSummary(id)
		out = append(out, v)
	}
	wire.JSON(w, 200, map[string]any{"server_id": s.cfg.Server, "modules": out})
}
func (s *Server) command(w http.ResponseWriter, r *http.Request, user, client, module string) {
	var b struct {
		Epoch   string          `json:"connection_epoch"`
		Command json.RawMessage `json:"command"`
	}
	if wire.Body(w, r, &b, 8192, "connection_epoch", "command") != nil || !wire.UUID.MatchString(b.Epoch) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	req, args, e := parse(b.Command)
	if e != nil {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	canonical, _ := json.Marshal(req)
	h := hmac.New(sha256.New, []byte(s.cfg.HMAC))
	h.Write([]byte(strings.Join([]string{user, client, module, b.Epoch}, "\n")))
	h.Write(canonical)
	digest := hex.EncodeToString(h.Sum(nil))
	ctx := r.Context()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, e := s.db.Begin(ctx)
	if e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	// A short global advisory lock enforces the finite receipt table bound and global ID uniqueness.
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(41742002)"); e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	var existing Record
	var oldDigest, oldUser string
	e = tx.QueryRow(ctx, "SELECT id,state,generation,receipt,request_hmac,user_id FROM commands WHERE id=$1", req.ID).Scan(&existing.ID, &existing.State, &existing.Generation, &existing.Receipt, &oldDigest, &oldUser)
	if e == nil {
		if oldUser != user {
			wire.Error(w, 404, "not_found")
		} else if oldDigest != digest {
			wire.Error(w, 409, "command_conflict")
		} else {
			wire.JSON(w, 200, existing)
		}
		return
	}
	if e != pgx.ErrNoRows {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	var locked string
	if tx.QueryRow(ctx, "SELECT id FROM modules WHERE id=$1 FOR UPDATE", module).Scan(&locked) != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	p := s.peers[module]
	if p == nil || p.snapshot == nil || !p.snapshot.Control.Ready {
		wire.Error(w, 503, "module_offline")
		return
	}
	if p.epoch != b.Epoch || p.boot != req.Boot || p.backend != req.Backend {
		wire.Error(w, 409, "epoch_conflict")
		return
	}
	deadline, e := time.Parse(time.RFC3339Nano, req.Deadline)
	if e != nil || !deadline.After(time.Now()) || time.Until(deadline) > 60*time.Second {
		wire.Error(w, 400, "invalid_deadline")
		return
	}
	var count, pending int
	if tx.QueryRow(ctx, "SELECT count(*) FROM commands").Scan(&count) != nil || tx.QueryRow(ctx, "SELECT count(*) FROM commands WHERE module_id=$1 AND state IN ('pending','dispatched')", module).Scan(&pending) != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	if count >= 10000 || pending >= 32 {
		wire.Error(w, 429, "capacity_exceeded")
		return
	}
	generation := wire.ID()
	newOwner := false
	var owner, oldGeneration, ownerBoot, ownerBackend string
	var call *string
	e = tx.QueryRow(ctx, "SELECT client_id,generation,agent_boot_id,backend_epoch,call_id FROM reservations WHERE module_id=$1", module).Scan(&owner, &oldGeneration, &ownerBoot, &ownerBackend, &call)
	if e != nil && e != pgx.ErrNoRows {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	hasOwner := e == nil
	if req.Action != "sms.send" {
		idle := true
		var target *Call
		for i := range p.snapshot.Calls.Calls {
			c := &p.snapshot.Calls.Calls[i]
			if c.State != "disconnected" {
				idle = false
			}
			if c.ID == args.Call {
				target = c
			}
		}
		switch req.Action {
		case "call.dial":
			if !idle || hasOwner {
				wire.Error(w, 409, "call_conflict")
				return
			}
			newOwner = true
		case "call.answer", "call.hangup", "call.dtmf":
			if target == nil || target.State == "disconnected" {
				wire.Error(w, 409, "call_conflict")
				return
			}
			if !hasOwner && (req.Action == "call.answer" || req.Action == "call.hangup") && target.State == "incoming" {
				newOwner = true
			} else if !hasOwner || owner != client || call == nil || *call != args.Call || ownerBoot != req.Boot || ownerBackend != req.Backend {
				wire.Error(w, 409, "call_conflict")
				return
			} else {
				generation = oldGeneration
			}
		}
	}
	if _, e = tx.Exec(ctx, "INSERT INTO commands(id,module_id,user_id,client_id,connection_epoch,generation,request_hmac,action,state) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'pending')", req.ID, module, user, client, b.Epoch, generation, digest, req.Action); e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	if newOwner {
		var callID any
		if args.Call != "" {
			callID = args.Call
		}
		if _, e = tx.Exec(ctx, "INSERT INTO reservations(module_id,client_id,generation,agent_boot_id,backend_epoch,call_id,command_id) VALUES($1,$2,$3,$4,$5,$6,$7)", module, client, generation, req.Boot, req.Backend, callID, req.ID); e != nil {
			wire.Error(w, 503, "database_unavailable")
			return
		}
	}
	if e = tx.Commit(ctx); e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	if _, e = s.db.Exec(ctx, "UPDATE commands SET state='dispatched' WHERE id=$1 AND state='pending'", req.ID); e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	if !s.enqueue(p, "command", map[string]any{"client_installation_id": client, "generation": generation, "command": req}) {
		_, _ = s.db.Exec(ctx, "UPDATE commands SET state='outcome_unknown' WHERE id=$1", req.ID)
	}
	wire.JSON(w, 202, Record{ID: req.ID, State: "pending", Generation: generation})
}
