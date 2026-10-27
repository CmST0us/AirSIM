package store

import (
	"airsim.local/server/migrations"
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"strings"
	"time"
)

type Store struct{ *pgxpool.Pool }

func Open(ctx context.Context) (*Store, error) {
	cfg, e := pgxpool.ParseConfig("")
	if e != nil {
		return nil, errors.New("database_config")
	}
	password, e := os.ReadFile(os.Getenv("DATABASE_PASSWORD_FILE"))
	if e != nil {
		return nil, errors.New("database_secret")
	}
	cfg.ConnConfig.Host = os.Getenv("DATABASE_HOST")
	cfg.ConnConfig.Database = "airsim"
	cfg.ConnConfig.User = "airsim"
	cfg.ConnConfig.Password = strings.TrimSpace(string(password))
	cfg.ConnConfig.TLSConfig = nil
	cfg.ConnConfig.Fallbacks = nil
	cfg.MaxConns = 8
	cfg.ConnConfig.ConnectTimeout = 5 * time.Second
	p, e := pgxpool.NewWithConfig(ctx, cfg)
	if e != nil {
		return nil, errors.New("database_connect")
	}
	return &Store{p}, nil
}

func (s *Store) Migrate(ctx context.Context) error {
	tx, e := s.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(41742001)"); e != nil {
		return e
	}
	var table *string
	if e = tx.QueryRow(ctx, "SELECT to_regclass('public.schema_version')::text").Scan(&table); e != nil {
		return e
	}
	version := 0
	if table != nil {
		if e = tx.QueryRow(ctx, "SELECT COALESCE(max(version),0) FROM schema_version").Scan(&version); e != nil {
			return e
		}
		if version > 4 {
			return errors.New("schema_version_unsupported")
		}
	}
	if version < 1 {
		if _, e = tx.Exec(ctx, migrations.Initial); e != nil {
			return e
		}
	}
	if version < 2 {
		if _, e = tx.Exec(ctx, migrations.Push); e != nil {
			return e
		}
	}
	if version < 3 {
		if _, e = tx.Exec(ctx, migrations.Pairing); e != nil {
			return e
		}
	}
	if version < 4 {
		if _, e = tx.Exec(ctx, migrations.PersistentClientSessions); e != nil {
			return e
		}
	}
	return tx.Commit(ctx)
}
func (s *Store) Ready(ctx context.Context) error {
	var v int
	e := s.QueryRow(ctx, "SELECT max(version) FROM schema_version").Scan(&v)
	if e != nil || v != 4 {
		return errors.New("schema_not_ready")
	}
	return nil
}
