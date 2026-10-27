package control

import (
	"airsim.local/server/internal/push"
	"airsim.local/server/internal/wire"
	"context"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"
)

type pushRegistration struct {
	ID          string `json:"registration_id"`
	Module      string `json:"module_id"`
	Bundle      string `json:"bundle_id"`
	Environment string `json:"environment"`
	VoIP        string `json:"voip_token"`
	Alert       string `json:"alert_token"`
}
type subscription struct {
	pushRegistration
	Client     string
	Registered time.Time
}

func validPushToken(s string) bool {
	if len(s) < 64 || len(s) > 512 {
		return false
	}
	_, e := hex.DecodeString(s)
	return e == nil
}
func (s *Server) pushRegistration(w http.ResponseWriter, r *http.Request, user, client string) {
	if r.Method == "DELETE" {
		var v struct {
			ID string `json:"registration_id"`
		}
		if wire.Body(w, r, &v, 1024) != nil || !wire.UUID.MatchString(v.ID) {
			wire.Error(w, 400, "invalid_parameters")
			return
		}
		if _, e := s.db.Exec(r.Context(), "DELETE FROM push_registrations WHERE client_id=$1 AND registration_id=$2", client, v.ID); e != nil {
			wire.Error(w, 503, "database_unavailable")
			return
		}
		w.WriteHeader(204)
		return
	}
	if r.Method != "PUT" {
		w.WriteHeader(405)
		return
	}
	if s.cfg.Push == nil {
		wire.Error(w, 503, "push_unavailable")
		return
	}
	var v pushRegistration
	if wire.Body(w, r, &v, 4096) != nil || !wire.UUID.MatchString(v.ID) || !wire.UUID.MatchString(v.Module) || v.Bundle != s.cfg.PushBundle || (v.Environment != "sandbox" && v.Environment != "production") || !validPushToken(v.VoIP) || (v.Alert != "" && !validPushToken(v.Alert)) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	v.VoIP = strings.ToLower(v.VoIP)
	v.Alert = strings.ToLower(v.Alert)
	var allowed bool
	if e := s.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM modules m JOIN clients c ON c.id=$3 WHERE m.id=$1 AND m.user_id=$2 AND NOT m.revoked AND (c.module_id IS NULL OR c.module_id=m.id))", v.Module, user, client).Scan(&allowed); e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	if !allowed {
		wire.Error(w, 404, "not_found")
		return
	}
	// A new subscription domain must first delete its old registration. Token refresh preserves its starting time.
	result, e := s.db.Exec(r.Context(), `INSERT INTO push_registrations(client_id,registration_id,module_id,bundle_id,environment,voip_token,alert_token)
 VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(client_id) DO UPDATE SET voip_token=EXCLUDED.voip_token,alert_token=EXCLUDED.alert_token
 WHERE push_registrations.registration_id=EXCLUDED.registration_id AND push_registrations.module_id=EXCLUDED.module_id AND push_registrations.bundle_id=EXCLUDED.bundle_id AND push_registrations.environment=EXCLUDED.environment`, client, v.ID, v.Module, v.Bundle, v.Environment, v.VoIP, v.Alert)
	if e != nil {
		wire.Error(w, 503, "registration_unavailable")
		return
	}
	if result.RowsAffected() != 1 {
		wire.Error(w, 409, "registration_conflict")
		return
	}
	wire.JSON(w, 200, map[string]string{"server_id": s.cfg.Server, "client_installation_id": client, "registration_id": v.ID, "module_id": v.Module, "bundle_id": v.Bundle, "environment": v.Environment})
}

type pushEvent struct {
	Module, Boot, Backend, Connection, Kind, ID, Number string
}

// events copies only notification data while holding the control lock.
func (s *Server) pushEvents(sub subscription) []pushEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.peers[sub.Module]
	now := time.Now()
	if p == nil || p.snapshot == nil || now.Sub(p.last) > 15*time.Second {
		return nil
	}
	snap := p.snapshot
	if now.Sub(snap.Observed) > 8*time.Second || snap.Observed.After(now.Add(3*time.Second)) {
		return nil
	}
	base := pushEvent{Module: p.module, Boot: p.boot, Backend: p.backend, Connection: p.epoch}
	var out []pushEvent
	if sub.VoIP != "" {
		for _, c := range snap.Calls.Calls {
			if (c.State == "incoming" || c.State == "ringing") && c.Direction == "incoming" {
				v := base
				v.Kind = "incoming_call"
				v.ID = c.ID
				v.Number = c.Number
				out = append(out, v)
			}
		}
	}
	if sub.Alert != "" {
		for _, m := range p.messages.Messages {
			if m.Direction == "incoming" && m.Observed.After(sub.Registered) {
				v := base
				v.Kind = "incoming_sms"
				v.ID = m.ID
				out = append(out, v)
			}
		}
	}
	return out
}
func (s *Server) currentPush(ctx context.Context, sub subscription, event pushEvent) (pushEvent, bool) {
	var valid bool
	e := s.db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM push_registrations r JOIN clients c ON c.id=r.client_id JOIN modules m ON m.id=r.module_id
 WHERE r.client_id=$1 AND r.registration_id=$2 AND r.module_id=$3 AND r.voip_token=$4 AND r.alert_token=$5
 AND `+sessionAuthorization+` AND NOT m.revoked AND m.user_id=c.user_id AND (c.module_id IS NULL OR c.module_id=m.id))`, sub.Client, sub.ID, sub.Module, sub.VoIP, sub.Alert).Scan(&valid)
	if e != nil || !valid {
		return pushEvent{}, false
	}
	for _, v := range s.pushEvents(sub) {
		if v.Kind == event.Kind && v.ID == event.ID && v.Boot == event.Boot && v.Backend == event.Backend {
			return v, true
		}
	}
	return pushEvent{}, false
}
func (s *Server) deliverPush(ctx context.Context, sub subscription, event pushEvent) bool {
	key := []any{sub.ID, event.Module, event.Boot, event.Backend, event.Kind, event.ID}
	_, e := s.db.Exec(ctx, `INSERT INTO push_deliveries(registration_id,module_id,agent_boot_id,backend_epoch,event,event_id) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`, key...)
	if e != nil {
		return false
	}
	var expires time.Time
	e = s.db.QueryRow(ctx, `UPDATE push_deliveries SET attempts=attempts+1,next_attempt=now()+interval '2 seconds'
 WHERE registration_id=$1 AND module_id=$2 AND agent_boot_id=$3 AND backend_epoch=$4 AND event=$5 AND event_id=$6 AND NOT finished AND attempts<3 AND expires_at>now() AND next_attempt<=now() RETURNING expires_at`, key...).Scan(&expires)
	if e != nil {
		return false
	}
	current, ok := s.currentPush(ctx, sub, event)
	if !ok {
		return false
	}
	payload := map[string]any{"protocol_version": 2, "event": event.Kind, "server_id": s.cfg.Server, "client_installation_id": sub.Client, "registration_id": sub.ID, "module_id": event.Module, "connection_epoch": current.Connection, "agent_boot_id": event.Boot, "backend_epoch": event.Backend, "expires_at": expires.UTC().Format(time.RFC3339)}
	n := push.Notification{Environment: sub.Environment, Topic: sub.Bundle, Kind: "alert", Token: sub.Alert, Payload: payload}
	if event.Kind == "incoming_call" {
		var uuid string
		e = s.db.QueryRow(ctx, `INSERT INTO push_calls(module_id,agent_boot_id,backend_epoch,call_id,call_uuid) VALUES($1,$2,$3,$4,$5)
 ON CONFLICT(module_id,agent_boot_id,backend_epoch,call_id) DO UPDATE SET last_seen=now() RETURNING call_uuid`, event.Module, event.Boot, event.Backend, event.ID, wire.ID()).Scan(&uuid)
		if e != nil {
			return false
		}
		payload["aps"] = map[string]int{"content-available": 1}
		payload["call_id"] = event.ID
		payload["call_uuid"] = uuid
		payload["number"] = current.Number
		n.Kind = "voip"
		n.Topic += ".voip"
		n.Token = sub.VoIP
	} else {
		payload["aps"] = map[string]any{"alert": "收到一条新短信，打开 AirSIM 查看"}
		payload["message_id"] = event.ID
	}
	// Revalidate after database work and before entering the network provider.
	if current, ok = s.currentPush(ctx, sub, event); !ok || !time.Now().Before(expires) {
		return false
	}
	payload["connection_epoch"] = current.Connection
	if event.Kind == "incoming_call" {
		payload["number"] = current.Number
	}
	result, err := s.cfg.Push.Send(ctx, n)
	if err == nil || !result.Retry {
		_, _ = s.db.Exec(ctx, `UPDATE push_deliveries SET finished=true WHERE registration_id=$1 AND module_id=$2 AND agent_boot_id=$3 AND backend_epoch=$4 AND event=$5 AND event_id=$6`, key...)
	}
	if result.InvalidToken {
		column := "alert_token"
		if n.Kind == "voip" {
			column = "voip_token"
		}
		_, _ = s.db.Exec(ctx, "UPDATE push_registrations SET "+column+"='' WHERE client_id=$1 AND registration_id=$2 AND "+column+"=$3", sub.Client, sub.ID, n.Token)
	}
	return true
}
func (s *Server) pushCycle(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	rows, e := s.db.Query(ctx, `SELECT r.client_id,r.registration_id,r.module_id,r.bundle_id,r.environment,r.voip_token,r.alert_token,r.registered_at
 FROM push_registrations r JOIN clients c ON c.id=r.client_id JOIN modules m ON m.id=r.module_id
 WHERE `+sessionAuthorization+` AND NOT m.revoked AND m.user_id=c.user_id AND (c.module_id IS NULL OR c.module_id=m.id) LIMIT 16`)
	if e != nil {
		return
	}
	var subscriptions []subscription
	for rows.Next() {
		var v subscription
		if rows.Scan(&v.Client, &v.ID, &v.Module, &v.Bundle, &v.Environment, &v.VoIP, &v.Alert, &v.Registered) != nil {
			rows.Close()
			return
		}
		subscriptions = append(subscriptions, v)
	}
	rows.Close()
	var wg sync.WaitGroup
	for _, sub := range subscriptions {
		wg.Add(1)
		go func(sub subscription) {
			defer wg.Done()
			for _, event := range s.pushEvents(sub) {
				if ctx.Err() != nil {
					return
				}
				if s.deliverPush(ctx, sub, event) && event.Kind == "incoming_sms" {
					break
				}
			}
		}(sub)
	}
	wg.Wait()
}
func (s *Server) RunPush(ctx context.Context) {
	if s.cfg.Push == nil {
		return
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	cleanup := time.NewTicker(time.Hour)
	defer cleanup.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.pushCycle(ctx)
		case <-cleanup.C:
			_, _ = s.db.Exec(ctx, `DELETE FROM push_registrations r USING clients c WHERE r.client_id=c.id AND (c.revoked OR (c.refresh_hash IS NULL AND c.expires_at<=now()) OR (c.refresh_hash IS NOT NULL AND c.refresh_expires_at IS NOT NULL AND c.refresh_expires_at<=now()))`)
			_, _ = s.db.Exec(ctx, `DELETE FROM push_calls WHERE last_seen<now()-interval '31 days'`)
		}
	}
}
