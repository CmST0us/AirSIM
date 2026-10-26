package control

import (
	"airsim.local/server/internal/admin"
	"airsim.local/server/internal/push"
	"airsim.local/server/internal/store"
	"airsim.local/server/internal/wire"
	"airsim.local/server/migrations"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type mockPush struct {
	mu     sync.Mutex
	sent   []push.Notification
	result push.Result
	err    error
	hook   func()
}

func (p *mockPush) Send(_ context.Context, n push.Notification) (push.Result, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sent = append(p.sent, n)
	if p.hook != nil {
		p.hook()
	}
	return p.result, p.err
}
func TestPushTokenLengths(t *testing.T) {
	for _, n := range []int{32, 48, 64, 256} {
		if !validPushToken(strings.Repeat("AB", n)) {
			t.Fatal(n)
		}
	}
	for _, s := range []string{"", strings.Repeat("a", 63), strings.Repeat("a", 513), strings.Repeat("zz", 32)} {
		if validPushToken(s) {
			t.Fatal("bad token accepted")
		}
	}
}
func TestPushDatabaseContract(t *testing.T) {
	url := os.Getenv("AIRSIM_PUSH_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("isolated PostgreSQL URL required")
	}
	ctx := context.Background()
	pool, e := pgxpool.New(ctx, url)
	if e != nil {
		t.Fatal(e)
	}
	defer pool.Close()
	db := &store.Store{Pool: pool}
	var exists *string
	_ = db.QueryRow(ctx, "SELECT to_regclass('public.schema_version')::text").Scan(&exists)
	if exists != nil {
		t.Fatal("test requires empty database")
	}
	if _, e = db.Exec(ctx, migrations.Initial); e != nil {
		t.Fatal(e)
	}
	user, server, client, module, token := wire.ID(), wire.ID(), wire.ID(), wire.ID(), wire.Token()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, q, args...); e != nil {
			t.Fatal(e)
		}
	}
	exec("INSERT INTO identity(server_id,user_id) VALUES($1,$2)", server, user)
	exec("INSERT INTO clients(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", client, user, wire.Hash(token))
	exec("INSERT INTO modules(id,user_id,server_id,public_key,serial,certificate) VALUES($1,$2,$3,'x','test','test')", module, user, server)
	command, generation := wire.ID(), wire.ID()
	exec("INSERT INTO commands(id,module_id,user_id,client_id,connection_epoch,generation,request_hmac,action,state) VALUES($1,$2,$3,$4,$5,$6,'synthetic','call.dial','completed')", command, module, user, client, wire.ID(), generation)
	exec("INSERT INTO reservations(module_id,client_id,generation,agent_boot_id,backend_epoch,command_id) VALUES($1,$2,$3,$4,$5,$6)", module, client, generation, wire.ID(), wire.ID(), command)
	if e = db.Migrate(ctx); e != nil {
		t.Fatal(e)
	}
	if e = db.Migrate(ctx); e != nil {
		t.Fatal(e)
	}
	if e = db.Ready(ctx); e != nil {
		t.Fatal(e)
	}
	var preserved string
	if db.QueryRow(ctx, "SELECT id FROM modules").Scan(&preserved) != nil || preserved != module {
		t.Fatal("migration lost module")
	}
	for _, table := range []string{"identity", "clients", "modules", "commands", "reservations"} {
		var count int
		if db.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&count) != nil || count != 1 {
			t.Fatal("migration lost rows", table)
		}
	}
	issued := filepath.Join(t.TempDir(), "issued-client.json")
	if e = admin.ClientTTL(ctx, db, issued, 30*24*time.Hour); e != nil {
		t.Fatal(e)
	}
	data, e := os.ReadFile(issued)
	if e != nil {
		t.Fatal(e)
	}
	var issuedClient struct {
		Expires time.Time `json:"expires_at"`
	}
	if json.Unmarshal(data, &issuedClient) != nil || time.Until(issuedClient.Expires) < 30*24*time.Hour-time.Minute {
		t.Fatal("30 day TTL")
	}
	provider := &mockPush{}
	cfg := Config{Server: server, Push: provider, PushBundle: "com.example.test"}
	s := New(db, cfg)
	discovery := httptest.NewRecorder()
	s.Handler().ServeHTTP(discovery, httptest.NewRequest("GET", "/.well-known/airsim", nil))
	var advertised struct {
		Profile      string          `json:"profile"`
		Capabilities map[string]bool `json:"capabilities"`
	}
	if json.Unmarshal(discovery.Body.Bytes(), &advertised) != nil || advertised.Profile != "airsim-v2-callkit" || !advertised.Capabilities["apns"] {
		t.Fatal("discovery contract")
	}
	request := func(method string, value any, auth string) *httptest.ResponseRecorder {
		t.Helper()
		b, _ := json.Marshal(value)
		r := httptest.NewRequest(method, "/v2/push/registration", bytes.NewReader(b))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+auth)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w
	}
	reg := pushRegistration{ID: wire.ID(), Module: module, Bundle: cfg.PushBundle, Environment: "sandbox", VoIP: strings.Repeat("a", 96), Alert: strings.Repeat("b", 64)}
	if w := request("PUT", reg, wire.Token()); w.Code != 401 {
		t.Fatal("authentication")
	}
	bad := reg
	bad.Module = wire.ID()
	if w := request("PUT", bad, token); w.Code != 404 {
		t.Fatal("module authorization", w.Code)
	}
	bad = reg
	bad.Bundle = "other.bundle"
	if w := request("PUT", bad, token); w.Code != 400 {
		t.Fatal("bundle validation")
	}
	if w := request("PUT", reg, token); w.Code != 200 || strings.Contains(w.Body.String(), reg.VoIP) {
		t.Fatal("registration response", w.Code)
	}
	bad = reg
	bad.ID = wire.ID()
	if w := request("PUT", bad, token); w.Code != 409 {
		t.Fatal("domain replacement")
	}
	if w := request("DELETE", map[string]string{"registration_id": wire.ID()}, token); w.Code != 204 {
		t.Fatal("late delete")
	}
	for _, v := range []any{map[string]string{"registration_id": reg.ID}, map[string]any{"registration_id": reg.ID, "module_id": reg.Module, "bundle_id": reg.Bundle, "environment": "sandbox", "voip_token": reg.VoIP, "alert_token": nil}} {
		if w := request("PUT", v, token); w.Code != 400 {
			t.Fatal("required fields")
		}
	}
	if w := request("DELETE", map[string]string{}, token); w.Code != 400 {
		t.Fatal("delete required fields")
	}
	boot, backend, call := wire.ID(), wire.ID(), wire.ID()
	p := &peer{module: module, boot: boot, backend: backend, epoch: wire.ID(), last: time.Now(), snapshot: &Snapshot{Observed: time.Now(), Calls: Calls{Calls: []Call{{ID: call, State: "incoming", Direction: "incoming"}}}}}
	s.peers[module] = p
	p.messages = Messages{Messages: []Message{{ID: wire.ID(), Direction: "incoming", Observed: time.Now().Add(-time.Hour), Text: "never include message body"}}}
	s.pushCycle(ctx)
	if len(provider.sent) != 1 {
		t.Fatal("incoming delivery", len(provider.sent))
	}
	payload := provider.sent[0].Payload.(map[string]any)
	uuid := payload["call_uuid"]
	if payload["protocol_version"] != 2 || payload["module_id"] != module || payload["registration_id"] != reg.ID || payload["connection_epoch"] != p.epoch || payload["call_id"] != call {
		t.Fatal("v2 payload")
	}
	encoded, _ := json.Marshal(payload)
	if bytes.Contains(encoded, []byte("token")) || bytes.Contains(encoded, []byte("secret")) {
		t.Fatal("credential in payload")
	}
	s.pushCycle(ctx)
	if len(provider.sent) != 1 {
		t.Fatal("duplicate snapshot")
	}
	s = New(db, cfg)
	p.epoch = wire.ID()
	s.peers[module] = p
	s.pushCycle(ctx)
	if len(provider.sent) != 1 {
		t.Fatal("restart/reconnect duplicate")
	}
	oldID := reg.ID
	if w := request("DELETE", map[string]string{"registration_id": oldID}, token); w.Code != 204 {
		t.Fatal("delete")
	}
	reg.ID = wire.ID()
	if w := request("PUT", reg, token); w.Code != 200 {
		t.Fatal("reregister")
	}
	if w := request("DELETE", map[string]string{"registration_id": oldID}, token); w.Code != 204 {
		t.Fatal("late old delete")
	}
	s.pushCycle(ctx)
	if len(provider.sent) != 2 || provider.sent[1].Payload.(map[string]any)["call_uuid"] != uuid {
		t.Fatal("unstable CallKit UUID or late delete")
	}
	p.messages.Messages = append(p.messages.Messages, Message{ID: wire.ID(), Direction: "incoming", Observed: time.Now(), Text: "private body", Sender: "private sender"})
	s.pushCycle(ctx)
	if len(provider.sent) != 3 || provider.sent[2].Kind != "alert" {
		t.Fatal("SMS push")
	}
	encoded, _ = json.Marshal(provider.sent[2].Payload)
	if bytes.Contains(encoded, []byte("private")) {
		t.Fatal("SMS privacy")
	}
	s.pushCycle(ctx)
	if len(provider.sent) != 3 {
		t.Fatal("SMS duplicate")
	}
	p.snapshot.Calls.Calls[0].ID = wire.ID()
	provider.result = push.Result{Retry: true}
	provider.err = errors.New("temporary")
	s.pushCycle(ctx)
	count := len(provider.sent)
	exec("UPDATE push_deliveries SET next_attempt=now()")
	p.snapshot.Calls.Calls = nil
	s.pushCycle(ctx)
	if len(provider.sent) != count {
		t.Fatal("ended call retried")
	}
	p.snapshot.Calls.Calls = []Call{{ID: wire.ID(), State: "incoming", Direction: "incoming"}}
	provider.result = push.Result{InvalidToken: true}
	provider.hook = func() {
		exec("UPDATE push_registrations SET voip_token=$1 WHERE client_id=$2", strings.Repeat("c", 64), client)
	}
	s.pushCycle(ctx)
	provider.hook = nil
	var saved string
	_ = db.QueryRow(ctx, "SELECT voip_token FROM push_registrations WHERE client_id=$1", client).Scan(&saved)
	if saved != strings.Repeat("c", 64) {
		t.Fatal("new token cleared")
	}
	// Retry count persists across cycles and is bounded to the first attempt plus two retries.
	provider.hook = nil
	provider.result = push.Result{Retry: true}
	provider.err = errors.New("temporary")
	p.snapshot.Calls.Calls[0].ID = wire.ID()
	count = len(provider.sent)
	for i := 0; i < 5; i++ {
		exec("UPDATE push_deliveries SET next_attempt=now()")
		s.pushCycle(ctx)
	}
	if len(provider.sent) != count+3 {
		t.Fatal("retry limit", len(provider.sent)-count)
	}
	provider.err = nil
	provider.result = push.Result{}
	p.snapshot.Calls.Calls[0].ID = wire.ID()
	count = len(provider.sent)
	p.snapshot.Observed = time.Now().Add(-9 * time.Second)
	s.pushCycle(ctx)
	p.snapshot.Observed = time.Now().Add(4 * time.Second)
	s.pushCycle(ctx)
	if len(provider.sent) != count {
		t.Fatal("stale/future snapshot notified")
	}
	p.snapshot.Observed = time.Now()
	delete(s.peers, module)
	s.pushCycle(ctx)
	if len(provider.sent) != count {
		t.Fatal("offline notification")
	}
	s.peers[module] = p
	exec("UPDATE clients SET expires_at=now()-interval '1 second' WHERE id=$1", client)
	s.pushCycle(ctx)
	if len(provider.sent) != count {
		t.Fatal("expired client notified")
	}
	exec("UPDATE clients SET expires_at=now()+interval '1 hour' WHERE id=$1", client)
	exec("UPDATE clients SET revoked=true WHERE id=$1", client)
	s.pushCycle(ctx)
	if len(provider.sent) != count {
		t.Fatal("revoked client notified")
	}
}

func TestClientTTLBounds(t *testing.T) {
	for _, ttl := range []time.Duration{time.Hour - time.Nanosecond, 30*24*time.Hour + time.Nanosecond} {
		if admin.ClientTTL(context.Background(), nil, filepath.Join(t.TempDir(), "client.json"), ttl) == nil {
			t.Fatal("invalid TTL accepted")
		}
	}
}
