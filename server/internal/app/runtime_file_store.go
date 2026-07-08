package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type RuntimeFile struct {
	Content   []byte
	Size      int64
	UpdatedAt time.Time
}

type RuntimeFileStore interface {
	GetFile(ctx context.Context, scope, key string) (RuntimeFile, bool, error)
	PutFile(ctx context.Context, scope, key string, content []byte) error
	MaterializeFile(ctx context.Context, scope, key, localPath string) (bool, error)
}

func NewRuntimeFileStore(cfg Config) (RuntimeFileStore, error) {
	switch cfg.RuntimeFileStore {
	case "", "filesystem", "file":
		return newFilesystemRuntimeFileStore(cfg.RuntimeDir), nil
	case "postgres", "pg":
		if cfg.DatabaseURL == "" {
			return nil, errors.New("DATABASE_URL is required when RUNTIME_FILE_STORE=postgres")
		}
		return newPostgresRuntimeFileStore(cfg.DatabaseURL)
	default:
		return nil, fmt.Errorf("unsupported RUNTIME_FILE_STORE: %s", cfg.RuntimeFileStore)
	}
}

func MustRuntimeFileStore(cfg Config) RuntimeFileStore {
	store, err := NewRuntimeFileStore(cfg)
	if err != nil {
		return &errorRuntimeFileStore{err: err}
	}
	return store
}

func (s *Server) runtimeFiles() RuntimeFileStore {
	if s.runtimeFileStore == nil {
		s.runtimeFileStore = MustRuntimeFileStore(s.cfg)
	}
	return s.runtimeFileStore
}

type errorRuntimeFileStore struct {
	err error
}

func (s *errorRuntimeFileStore) GetFile(context.Context, string, string) (RuntimeFile, bool, error) {
	return RuntimeFile{}, false, s.err
}

func (s *errorRuntimeFileStore) PutFile(context.Context, string, string, []byte) error {
	return s.err
}

func (s *errorRuntimeFileStore) MaterializeFile(context.Context, string, string, string) (bool, error) {
	return false, s.err
}

type filesystemRuntimeFileStore struct {
	root string
}

func newFilesystemRuntimeFileStore(root string) *filesystemRuntimeFileStore {
	return &filesystemRuntimeFileStore{root: root}
}

func (s *filesystemRuntimeFileStore) GetFile(_ context.Context, scope, key string) (RuntimeFile, bool, error) {
	path := s.path(scope, key)
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

func (s *filesystemRuntimeFileStore) PutFile(_ context.Context, scope, key string, content []byte) error {
	path := s.path(scope, key)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o600)
}

func (s *filesystemRuntimeFileStore) MaterializeFile(_ context.Context, scope, key, localPath string) (bool, error) {
	source := s.path(scope, key)
	if source == localPath {
		if _, err := os.Stat(localPath); errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return true, nil
	}
	content, err := os.ReadFile(source)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return false, err
	}
	return true, os.WriteFile(localPath, content, 0o600)
}

func (s *filesystemRuntimeFileStore) path(scope, key string) string {
	return filepath.Join(s.root, filepath.FromSlash(cleanRuntimeFileStorePath(scope, key)))
}

type postgresRuntimeFileStore struct {
	db *sql.DB
}

func newPostgresRuntimeFileStore(databaseURL string) (*postgresRuntimeFileStore, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, err
	}
	configurePostgresPool(db)
	store := &postgresRuntimeFileStore{db: db}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := store.ensureSchema(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (s *postgresRuntimeFileStore) ensureSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
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

func (s *postgresRuntimeFileStore) GetFile(ctx context.Context, scope, key string) (RuntimeFile, bool, error) {
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

func (s *postgresRuntimeFileStore) PutFile(ctx context.Context, scope, key string, content []byte) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO runtime_files (scope, key, content, size, updated_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (scope, key)
DO UPDATE SET content = EXCLUDED.content, size = EXCLUDED.size, updated_at = now()`, scope, key, content, len(content))
	return err
}

func (s *postgresRuntimeFileStore) MaterializeFile(ctx context.Context, scope, key, localPath string) (bool, error) {
	file, ok, err := s.GetFile(ctx, scope, key)
	if err != nil || !ok {
		return ok, err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return false, err
	}
	return true, os.WriteFile(localPath, file.Content, 0o600)
}

func cleanRuntimeFileStorePath(scope, key string) string {
	joined := filepath.ToSlash(filepath.Clean(strings.TrimSpace(scope) + "/" + strings.TrimSpace(key)))
	if joined == "." || joined == "/" || strings.HasPrefix(joined, "../") || strings.Contains(joined, "/../") || strings.HasPrefix(joined, "/") {
		return "invalid"
	}
	parts := strings.Split(joined, "/")
	for i, part := range parts {
		parts[i] = cleanRuntimeStorePathPart(part)
	}
	return strings.Join(parts, "/")
}
