package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type RuntimeFile struct {
	Content   []byte
	Size      int64
	UpdatedAt time.Time
}

type RuntimeStore interface {
	GetJSON(ctx context.Context, scope, key string, dest any) (bool, error)
	PutJSON(ctx context.Context, scope, key string, value any) error
	GetFile(ctx context.Context, scope, key string) (RuntimeFile, bool, error)
	PutFile(ctx context.Context, scope, key string, content []byte) error
	MaterializeFile(ctx context.Context, scope, key, localPath string) (bool, error)
	WithLock(ctx context.Context, name string, fn func() error) error
}

func NewRuntimeStore(cfg Config) (RuntimeStore, error) {
	if runtimeBackend(cfg) == "postgres" {
		db, err := openPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, err
		}
		store, err := NewRuntimeStoreWithDB(db)
		if err != nil {
			_ = db.Close()
			return nil, err
		}
		return store, nil
	}
	return newFilesystemRuntimeStore(cfg.RuntimeDir), nil
}

func NewRuntimeStoreWithDB(db *sql.DB) (RuntimeStore, error) {
	store := &postgresRuntimeStore{db: db}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := store.ensureSchema(ctx); err != nil {
		return nil, err
	}
	return store, nil
}

func runtimeBackend(cfg Config) string {
	if cfg.DatabaseURL != "" {
		return "postgres"
	}
	return "filesystem"
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

func (s *errorRuntimeStore) GetFile(context.Context, string, string) (RuntimeFile, bool, error) {
	return RuntimeFile{}, false, s.err
}

func (s *errorRuntimeStore) PutFile(context.Context, string, string, []byte) error {
	return s.err
}

func (s *errorRuntimeStore) MaterializeFile(context.Context, string, string, string) (bool, error) {
	return false, s.err
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

func (s *filesystemRuntimeStore) GetFile(_ context.Context, scope, key string) (RuntimeFile, bool, error) {
	path := s.filePath(scope, key)
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return RuntimeFile{}, false, nil
	}
	if err != nil {
		return RuntimeFile{}, false, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return RuntimeFile{}, false, err
	}
	return RuntimeFile{Content: content, Size: info.Size(), UpdatedAt: info.ModTime()}, true, nil
}

func (s *filesystemRuntimeStore) PutFile(_ context.Context, scope, key string, content []byte) error {
	path := s.filePath(scope, key)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o600)
}

func (s *filesystemRuntimeStore) MaterializeFile(ctx context.Context, scope, key, localPath string) (bool, error) {
	file, ok, err := s.GetFile(ctx, scope, key)
	if err != nil || !ok {
		return ok, err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return false, err
	}
	return true, os.WriteFile(localPath, file.Content, 0o600)
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

func (s *filesystemRuntimeStore) filePath(scope, key string) string {
	return filepath.Join(s.root, filepath.FromSlash(cleanRuntimeFileStorePath(scope, key)))
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

func (s *postgresRuntimeStore) ensureSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS runtime_json (
  scope TEXT NOT NULL,
  key TEXT NOT NULL,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (scope, key)
);

CREATE TABLE IF NOT EXISTS runtime_files (
  scope TEXT NOT NULL,
  key TEXT NOT NULL,
  content BYTEA NOT NULL,
  size BIGINT NOT NULL,
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

func (s *postgresRuntimeStore) GetFile(ctx context.Context, scope, key string) (RuntimeFile, bool, error) {
	var file RuntimeFile
	err := s.db.QueryRowContext(ctx, `SELECT content, size, updated_at FROM runtime_files WHERE scope = $1 AND key = $2`, scope, key).Scan(&file.Content, &file.Size, &file.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return RuntimeFile{}, false, nil
	}
	if err != nil {
		return RuntimeFile{}, false, err
	}
	return file, true, nil
}

func (s *postgresRuntimeStore) PutFile(ctx context.Context, scope, key string, content []byte) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO runtime_files (scope, key, content, size, updated_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (scope, key)
DO UPDATE SET content = EXCLUDED.content, size = EXCLUDED.size, updated_at = now()`, scope, key, content, len(content))
	return err
}

func (s *postgresRuntimeStore) MaterializeFile(ctx context.Context, scope, key, localPath string) (bool, error) {
	file, ok, err := s.GetFile(ctx, scope, key)
	if err != nil || !ok {
		return ok, err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return false, err
	}
	return true, os.WriteFile(localPath, file.Content, 0o600)
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

func cleanRuntimeFileStorePath(scope, key string) string {
	joined := filepath.ToSlash(filepath.Clean(strings.TrimSpace(scope) + "/" + strings.TrimSpace(key)))
	if joined == "." || joined == "/" || strings.HasPrefix(joined, "../") || strings.Contains(joined, "/../") || strings.HasPrefix(joined, "/") {
		return "invalid"
	}
	parts := strings.Split(joined, "/")
	for index, part := range parts {
		parts[index] = cleanRuntimeStorePathPart(part)
	}
	return strings.Join(parts, "/")
}
