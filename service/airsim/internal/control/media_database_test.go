package control

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"airsim.local/server/internal/media"
	"airsim.local/server/internal/store"
	"airsim.local/server/internal/wire"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAnswerOwnershipCreatesLC3Media(t *testing.T) {
	databaseURL := os.Getenv("AIRSIM_MEDIA_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("isolated empty PostgreSQL URL required")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	db := &store.Store{Pool: pool}
	var table *string
	if err = db.QueryRow(ctx, "SELECT to_regclass('public.schema_version')::text").Scan(&table); err != nil {
		t.Fatal(err)
	}
	if table != nil {
		t.Fatal("test requires empty database")
	}
	if err = db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	for _, transition := range []string{"initial", "boot", "backend"} {
		t.Run(transition, func(t *testing.T) {
			server, user, client, module := wire.ID(), wire.ID(), wire.ID(), wire.ID()
			clientToken, mediaToken := wire.Token(), wire.Token()
			exec := func(sql string, args ...any) {
				t.Helper()
				if _, err := db.Exec(ctx, sql, args...); err != nil {
					t.Fatal(err)
				}
			}
			exec("INSERT INTO identity(server_id,user_id) VALUES($1,$2) ON CONFLICT (singleton) DO UPDATE SET server_id=EXCLUDED.server_id,user_id=EXCLUDED.user_id", server, user)
			exec("INSERT INTO clients(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)", client, user, wire.Hash(clientToken), time.Now().Add(time.Hour))
			exec("INSERT INTO modules(id,user_id,server_id,public_key,serial,certificate) VALUES($1,$2,$3,'test','test','test')", module, user, server)
			backend := httptest.NewServer(media.New(mediaToken).Handler())
			defer backend.Close()
			s := New(db, Config{Server: server, Media: "https://media.invalid", MediaInternal: backend.URL, MediaToken: mediaToken, HMAC: wire.Token()})
			defer s.mediaHTTP.CloseIdleConnections()
			call, command := wire.ID(), wire.ID()
			pctx, cancel := context.WithCancel(ctx)
			defer cancel()
			p := &peer{module: module, epoch: wire.ID(), boot: wire.ID(), backend: wire.ID(), mediaCodec: "lc3", ctx: pctx, cancel: cancel, queue: make(chan Envelope, 32), queried: true, last: time.Now()}
			snap := Snapshot{Boot: p.boot, Backend: p.backend, Observed: time.Now().UTC(), Control: Status{Schema: 1, Boot: p.boot, Backend: p.backend, Ready: true}, Calls: Calls{Boot: p.boot, Backend: p.backend, Available: true, Calls: []Call{{ID: call, State: "incoming", Ownership: "managed", Observed: time.Now().UTC()}}}, Audio: json.RawMessage(`{"available":true,"implementation":"native","verification":"unverified","voice_ready":true,"reason":""}`)}
			p.snapshot = &snap
			s.peers[module] = p
			s.last[module] = p

			if transition != "initial" {
				oldCommand, oldGeneration, oldCall := wire.ID(), wire.ID(), wire.ID()
				oldBoot, oldBackend := p.boot, p.backend
				if transition == "boot" {
					oldBoot = wire.ID()
				} else {
					oldBackend = wire.ID()
				}
				exec("INSERT INTO commands(id,module_id,user_id,client_id,connection_epoch,generation,request_hmac,action,state) VALUES($1,$2,$3,$4,$5,$6,'test','call.answer','completed')", oldCommand, module, user, client, wire.ID(), oldGeneration)
				exec("INSERT INTO reservations(module_id,client_id,generation,agent_boot_id,backend_epoch,call_id,command_id) VALUES($1,$2,$3,$4,$5,$6,$7)", module, client, oldGeneration, oldBoot, oldBackend, oldCall, oldCommand)
				for _, variant := range []string{"stale", "future", "unavailable", "invalid"} {
					invalid := snap
					switch variant {
					case "stale":
						invalid.Observed = time.Now().UTC().Add(-9 * time.Second)
					case "future":
						invalid.Observed = time.Now().UTC().Add(4 * time.Second)
					case "unavailable":
						invalid.Calls.Available = false
					case "invalid":
						invalid.Control.Schema = 2
					}
					raw, _ := json.Marshal(invalid)
					accepted := s.consume(p, Envelope{Type: "snapshot", Payload: raw})
					if accepted == (variant == "invalid") {
						t.Fatalf("snapshot %s validation mismatch", variant)
					}
					var count int
					if err = db.QueryRow(ctx, "SELECT count(*) FROM reservations WHERE module_id=$1", module).Scan(&count); err != nil || count != 1 {
						t.Fatalf("%s snapshot released owner", variant)
					}
				}
				raw, _ := json.Marshal(snap)
				if !s.consume(p, Envelope{Type: "snapshot", Payload: raw}) {
					t.Fatal("fresh epoch snapshot rejected")
				}
				var count int
				if err = db.QueryRow(ctx, "SELECT count(*) FROM reservations WHERE module_id=$1", module).Scan(&count); err != nil || count != 0 {
					t.Fatal("confirmed epoch retained old reservation")
				}
				if err = db.QueryRow(ctx, "SELECT count(*) FROM commands WHERE id=$1", oldCommand).Scan(&count); err != nil || count != 1 {
					t.Fatal("epoch cleanup removed command history")
				}
			}
			status, data := pairingRequest(t, s.Handler(), "POST", "/v2/modules/"+module+"/commands", map[string]any{"connection_epoch": p.epoch, "command": map[string]any{"command_id": command, "agent_boot_id": p.boot, "backend_epoch": p.backend, "deadline": time.Now().UTC().Add(30 * time.Second).Format(time.RFC3339Nano), "action": "call.answer", "args": map[string]string{"call_id": call}}}, clientToken)
			if status != 202 {
				t.Fatalf("answer status %d", status)
			}
			var record Record
			if json.Unmarshal(data, &record) != nil || !wire.UUID.MatchString(record.Generation) {
				t.Fatal("answer generation missing")
			}
			env := <-p.queue
			var directed struct {
				Client     string  `json:"client_installation_id"`
				Generation string  `json:"generation"`
				Command    Request `json:"command"`
			}
			if env.Type != "command" || wire.Decode(env.Payload, &directed) != nil || directed.Client != client || directed.Generation != record.Generation || directed.Command.Boot != p.boot || directed.Command.Backend != p.backend {
				t.Fatal("answer ownership fields changed")
			}
			receipt := Receipt{ID: command, Action: "call.answer", State: "observed", Call: call, Updated: time.Now().UTC()}
			payload, _ := json.Marshal(map[string]any{"command_id": command, "status_code": 200, "receipt": receipt})
			if !s.consume(p, Envelope{Type: "receipt", Payload: payload}) {
				t.Fatal("observed answer rejected")
			}
			snap.Calls.Calls[0].State = "active"
			payload, _ = json.Marshal(snap)
			if !s.consume(p, Envelope{Type: "snapshot", Payload: payload}) {
				t.Fatal("active snapshot rejected")
			}
			var matching bool
			if err = db.QueryRow(ctx, "SELECT client_id=$2 AND generation=$3 AND agent_boot_id=$4 AND backend_epoch=$5 AND call_id=$6 FROM reservations WHERE module_id=$1", module, client, record.Generation, p.boot, p.backend, call).Scan(&matching); err != nil || !matching {
				t.Fatal("answer ownership not retained on active snapshot")
			}

			p.epoch = wire.ID()
			payload, _ = json.Marshal(snap)
			if !s.consume(p, Envelope{Type: "snapshot", Payload: payload}) {
				t.Fatal("connection-only snapshot rejected")
			}
			if err = db.QueryRow(ctx, "SELECT client_id=$2 AND generation=$3 AND agent_boot_id=$4 AND backend_epoch=$5 AND call_id=$6 FROM reservations WHERE module_id=$1", module, client, record.Generation, p.boot, p.backend, call).Scan(&matching); err != nil || !matching {
				t.Fatal("connection-only reconnect lost ownership")
			}
			request := map[string]string{"request_id": wire.ID(), "connection_epoch": p.epoch, "generation": record.Generation, "codec": "lc3"}
			path := "/v2/modules/" + module + "/calls/" + call + "/media-sessions"
			status, data = pairingRequest(t, s.Handler(), "POST", path, request, clientToken)
			if status != 201 {
				t.Fatalf("media create status %d", status)
			}
			var created struct {
				ID      string            `json:"session_id"`
				Ticket  string            `json:"ticket"`
				Expires time.Time         `json:"expires_at"`
				URL     string            `json:"media_url"`
				Format  media.AudioFormat `json:"format"`
			}
			if wire.Decode(data, &created) != nil || created.Format != media.Format {
				t.Fatal("media response format mismatch")
			}
			env = <-p.queue
			var start struct {
				Request    string            `json:"request_id"`
				Session    string            `json:"session_id"`
				Call       string            `json:"call_id"`
				Boot       string            `json:"agent_boot_id"`
				Backend    string            `json:"backend_epoch"`
				Client     string            `json:"client_installation_id"`
				Generation string            `json:"generation"`
				Ticket     string            `json:"ticket"`
				Expires    time.Time         `json:"expires_at"`
				Format     media.AudioFormat `json:"format"`
			}
			if env.Type != "media_start" || wire.Decode(env.Payload, &start) != nil {
				t.Fatal("media_start schema mismatch")
			}
			if start.Request != request["request_id"] || start.Session != created.ID || start.Call != call || start.Boot != directed.Command.Boot || start.Backend != directed.Command.Backend || start.Client != directed.Client || start.Generation != directed.Generation || start.Format != created.Format || !start.Expires.Equal(created.Expires) {
				t.Fatal("media_start ownership or format differs from answer")
			}
			if status, _ = pairingRequest(t, s.Handler(), "POST", path, request, clientToken); status != 200 || len(p.queue) != 0 {
				t.Fatal("idempotent create changed session or resent media_start")
			}
			if status, _ = pairingRequest(t, s.Handler(), "DELETE", path+"/"+created.ID, nil, clientToken); status != 204 {
				t.Fatal("media release failed")
			}
			snap.Calls.Calls[0].State = "disconnected"
			payload, _ = json.Marshal(snap)
			if !s.consume(p, Envelope{Type: "snapshot", Payload: payload}) {
				t.Fatal("disconnected snapshot rejected")
			}
			var count int
			if err = db.QueryRow(ctx, "SELECT count(*) FROM reservations WHERE module_id=$1", module).Scan(&count); err != nil || count != 0 {
				t.Fatal("disconnected call retained ownership")
			}
		})
	}
}
