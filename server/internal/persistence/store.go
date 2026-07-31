// Package persistence owns relational persistence infrastructure.
//
// Application services depend on their domain repositories, rather than a
// generic JSON key/value abstraction. This package wires the generated Ent
// client to the application's shared PostgreSQL pool after versioned migrations
// have completed.
package persistence

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	entsql "entgo.io/ent/dialect/sql"
	"github.com/borui/beancount-ledger-web/server/internal/persistence/ent"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// Store exposes the shared Ent client. It does not own the SQL pool; the
// application composition root closes that pool after all services stop.
type Store struct {
	Client *ent.Client
	db     *sql.DB
}

// NewStore applies every checked-in migration transactionally before exposing
// the ORM client. It intentionally never calls Ent's automatic schema create:
// production schema changes must remain versioned and reviewable.
func NewStore(ctx context.Context, db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, errors.New("database is required")
	}
	if err := ApplyMigrations(ctx, db); err != nil {
		return nil, err
	}
	return &Store{Client: ent.NewClient(ent.Driver(entsql.OpenDB("postgres", db))), db: db}, nil
}

// RunBackfillOnce records success only after the caller has completed its
// idempotent copy. Concurrent startup is safe because importers use unique
// constraints plus DO NOTHING; this deliberately avoids holding a database
// connection while the callback uses Ent (important for one-connection pools).
// It is for upgrade bridges only; normal request paths never call it.
func (s *Store) RunBackfillOnce(ctx context.Context, name string, fn func(context.Context) error) error {
	if s == nil || s.db == nil {
		return errors.New("persistence store is not initialized")
	}
	var complete bool
	if err := s.db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM relational_backfills WHERE name = $1)`, name).Scan(&complete); err != nil {
		return fmt.Errorf("check backfill %s: %w", name, err)
	}
	if complete {
		return nil
	}
	if err := fn(ctx); err != nil {
		return fmt.Errorf("backfill %s: %w", name, err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO relational_backfills (name) VALUES ($1) ON CONFLICT (name) DO NOTHING`, name); err != nil {
		return fmt.Errorf("record backfill %s: %w", name, err)
	}
	return nil
}

// ApplyMigrations applies embedded SQL files in lexical order and records each
// filename only after its transaction commits. Migration SQL must be safe to
// run once; the tracker prevents re-executing an already applied version.
func ApplyMigrations(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)`); err != nil {
		return fmt.Errorf("create migration tracker: %w", err)
	}
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return fmt.Errorf("read migrations: %w", err)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		var applied bool
		if err := db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, entry.Name()).Scan(&applied); err != nil {
			return fmt.Errorf("check migration %s: %w", entry.Name(), err)
		}
		if applied {
			continue
		}
		body, err := migrationFiles.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return fmt.Errorf("read migration %s: %w", entry.Name(), err)
		}
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("begin migration %s: %w", entry.Name(), err)
		}
		if _, err := tx.ExecContext(ctx, string(body)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("apply migration %s: %w", entry.Name(), err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, entry.Name()); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("record migration %s: %w", entry.Name(), err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit migration %s: %w", entry.Name(), err)
		}
	}
	return nil
}
