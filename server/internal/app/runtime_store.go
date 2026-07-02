package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

type RuntimeStore interface {
	GetJSON(ctx context.Context, scope, key string, dest any) (bool, error)
	PutJSON(ctx context.Context, scope, key string, value any) error
	WithLock(ctx context.Context, name string, fn func() error) error
}

func NewRuntimeStore(cfg Config) (RuntimeStore, error) {
	switch cfg.RuntimeStore {
	case "", "filesystem", "file":
		return newFilesystemRuntimeStore(cfg.RuntimeDir), nil
	case "postgres", "pg":
		if cfg.DatabaseURL == "" {
			return nil, errors.New("DATABASE_URL is required when RUNTIME_STORE=postgres")
		}
		return newPostgresRuntimeStore(cfg.DatabaseURL)
	default:
		return nil, fmt.Errorf("unsupported RUNTIME_STORE: %s", cfg.RuntimeStore)
	}
}

func MustRuntimeStore(cfg Config) RuntimeStore {
	store, err := NewRuntimeStore(cfg)
	if err != nil {
		return &errorRuntimeStore{err: err}
	}
	return store
}

func (s *Server) runtime() RuntimeStore {
	if s.runtimeStore == nil {
		s.runtimeStore = MustRuntimeStore(s.cfg)
	}
	return s.runtimeStore
}

type errorRuntimeStore struct {
	err error
}

func (s *errorRuntimeStore) GetJSON(context.Context, string, string, any) (bool, error) {
	return false, s.err
}

func (s *errorRuntimeStore) PutJSON(context.Context, string, string, any) error {
	return s.err
}

func (s *errorRuntimeStore) WithLock(_ context.Context, _ string, _ func() error) error {
	return s.err
}

type filesystemRuntimeStore struct {
	root string
	mu   sync.Mutex
}

func newFilesystemRuntimeStore(root string) *filesystemRuntimeStore {
	return &filesystemRuntimeStore{root: root}
}

func (s *filesystemRuntimeStore) GetJSON(_ context.Context, scope, key string, dest any) (bool, error) {
	content, err := os.ReadFile(s.path(scope, key))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(content, dest); err != nil {
		return false, err
	}
	return true, nil
}

func (s *filesystemRuntimeStore) PutJSON(_ context.Context, scope, key string, value any) error {
	content, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	path := s.path(scope, key)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o600)
}

func (s *filesystemRuntimeStore) WithLock(_ context.Context, _ string, fn func() error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return fn()
}

func (s *filesystemRuntimeStore) path(scope, key string) string {
	switch scope + "/" + key {
	case "auth/passkeys":
		return filepath.Join(s.root, "passkeys.json")
	case "push/subscriptions":
		return filepath.Join(s.root, "webpush-subscriptions.json")
	case "notifications/store":
		return filepath.Join(s.root, "notifications.json")
	default:
		if scope == "imports" {
			return filepath.Join(s.root, filepath.FromSlash(cleanRuntimeFileStorePath(scope, key)+".json"))
		}
		return filepath.Join(s.root, cleanRuntimeStorePathPart(scope), cleanRuntimeStorePathPart(key)+".json")
	}
}

var runtimeStorePathPartRe = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)

func cleanRuntimeStorePathPart(part string) string {
	cleaned := runtimeStorePathPartRe.ReplaceAllString(part, "-")
	if cleaned == "" || cleaned == "." || cleaned == ".." {
		return "default"
	}
	return cleaned
}

type postgresRuntimeStore struct {
	db *sql.DB
}

func newPostgresRuntimeStore(databaseURL string) (*postgresRuntimeStore, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	db.SetConnMaxIdleTime(5 * time.Minute)
	store := &postgresRuntimeStore{db: db}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := store.ensureSchema(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (s *postgresRuntimeStore) ensureSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS runtime_json (
  scope TEXT NOT NULL,
  key TEXT NOT NULL,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (scope, key)
)`)
	return err
}

func (s *postgresRuntimeStore) GetJSON(ctx context.Context, scope, key string, dest any) (bool, error) {
	var raw []byte
	err := s.db.QueryRowContext(ctx, `SELECT value FROM runtime_json WHERE scope = $1 AND key = $2`, scope, key).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(raw, dest); err != nil {
		return false, err
	}
	return true, nil
}

func (s *postgresRuntimeStore) PutJSON(ctx context.Context, scope, key string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO runtime_json (scope, key, value, updated_at)
VALUES ($1, $2, $3, now())
ON CONFLICT (scope, key)
DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, scope, key, raw)
	return err
}

func (s *postgresRuntimeStore) WithLock(ctx context.Context, name string, fn func() error) error {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `SELECT pg_advisory_lock(hashtext($1))`, name); err != nil {
		return err
	}
	defer conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock(hashtext($1))`, name)
	return fn()
}
