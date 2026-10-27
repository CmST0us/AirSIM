package control

import (
	"airsim.local/server/internal/wire"
	"context"
	"github.com/jackc/pgx/v5"
	"net/http"
	"time"
)

// Module-scoped device sessions remain valid until revoked. Administrator
// compatibility clients retain their explicit expiry.
const sessionAuthorization = `NOT c.revoked AND (c.module_id IS NOT NULL OR (c.refresh_hash IS NULL AND c.expires_at IS NOT NULL AND c.expires_at>now()) OR (c.refresh_hash IS NOT NULL AND (c.refresh_expires_at IS NULL OR c.refresh_expires_at>now())))`

type sessionResponse struct {
	Schema            int        `json:"schema_version"`
	API               string     `json:"api_origin"`
	Media             string     `json:"media_origin"`
	Server            string     `json:"server_id"`
	Module            string     `json:"module_id"`
	Client            string     `json:"client_installation_id"`
	Token             string     `json:"token"`
	Expires           *time.Time `json:"expires_at"`
	RefreshExpires    *time.Time `json:"refresh_expires_at"`
	PersistentSession bool       `json:"persistent_session"`
}

func (s *Server) issueAccess(ctx context.Context, tx pgx.Tx, client, module string) (sessionResponse, error) {
	v := sessionResponse{Schema: 3, API: s.cfg.API, Media: s.cfg.Media, Server: s.cfg.Server, Module: module, Client: client, Token: wire.Token(), PersistentSession: true}
	_, e := tx.Exec(ctx, "UPDATE clients SET token_hash=$2,expires_at=NULL,refresh_expires_at=NULL WHERE id=$1", client, wire.Hash(v.Token))
	return v, e
}

// Older App builds require schema 2 and two timestamp fields. Keep the refresh
// response shape compatible while the server treats module authorization as
// permanent. The returned timestamps only pace those builds' refresh loop.
func (s *Server) issueLegacyCompatibleAccess(ctx context.Context, tx pgx.Tx, client, module string) (sessionResponse, error) {
	now := time.Now().UTC()
	access, refresh := now.Add(time.Hour), now.Add(90*24*time.Hour)
	v := sessionResponse{
		Schema: 2, API: s.cfg.API, Media: s.cfg.Media, Server: s.cfg.Server,
		Module: module, Client: client, Token: wire.Token(),
		Expires: &access, RefreshExpires: &refresh, PersistentSession: true,
	}
	_, e := tx.Exec(ctx, "UPDATE clients SET token_hash=$2,expires_at=NULL,refresh_expires_at=NULL WHERE id=$1", client, wire.Hash(v.Token))
	return v, e
}
func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var v struct {
		Client  string `json:"client_installation_id"`
		Refresh string `json:"refresh_token"`
	}
	if wire.Body(w, r, &v, 16384) != nil || !wire.UUID.MatchString(v.Client) || !wire.Hex.MatchString(v.Refresh) {
		wire.Error(w, 400, "invalid_parameters")
		return
	}
	tx, e := s.db.Begin(ctx)
	if e != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	defer tx.Rollback(ctx)
	var module string
	e = tx.QueryRow(ctx, `SELECT c.module_id FROM clients c JOIN modules m ON m.id=c.module_id WHERE c.id=$1 AND c.refresh_hash=$2 AND NOT c.revoked AND (c.refresh_expires_at IS NULL OR c.refresh_expires_at>now()) AND NOT m.revoked AND m.server_id=$3 AND m.user_id=c.user_id FOR UPDATE OF c`, v.Client, wire.Hash(v.Refresh), s.cfg.Server).Scan(&module)
	if e != nil {
		wire.Error(w, 401, "unauthorized")
		return
	}
	response, e := s.issueLegacyCompatibleAccess(ctx, tx, v.Client, module)
	if e != nil || tx.Commit(ctx) != nil {
		wire.Error(w, 503, "database_unavailable")
		return
	}
	wire.JSON(w, 200, response)
}
