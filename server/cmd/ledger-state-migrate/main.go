package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

type migration struct {
	sourceDir string
	write     bool
	store     app.RuntimeStore
	jsonCount int
	fileCount int
}

func main() {
	sourceDir := flag.String("runtime-dir", strings.TrimSpace(os.Getenv("RUNTIME_DIR")), "legacy runtime directory")
	databaseURL := flag.String("database-url", strings.TrimSpace(os.Getenv("DATABASE_URL")), "Postgres DATABASE_URL")
	write := flag.Bool("write", false, "write migrated state; without this flag the command is a dry run")
	flag.Parse()

	if strings.TrimSpace(*sourceDir) == "" {
		log.Fatal("runtime-dir or RUNTIME_DIR is required")
	}
	if strings.TrimSpace(*databaseURL) == "" {
		log.Fatal("database-url or DATABASE_URL is required")
	}

	store, err := app.NewRuntimeStore(app.Config{DatabaseURL: *databaseURL})
	if err != nil {
		log.Fatal(err)
	}
	m := migration{sourceDir: filepath.Clean(*sourceDir), write: *write, store: store}
	if err := m.run(context.Background()); err != nil {
		log.Fatal(err)
	}
	mode := "dry-run"
	if m.write {
		mode = "write"
	}
	log.Printf("ledger state migration complete mode=%s json=%d files=%d", mode, m.jsonCount, m.fileCount)
}

func (m *migration) run(ctx context.Context) error {
	if err := m.migrateJSON(ctx, filepath.Join(m.sourceDir, "passkeys.json"), "auth", "passkeys"); err != nil {
		return err
	}
	if err := m.migrateJSON(ctx, filepath.Join(m.sourceDir, "webpush-subscriptions.json"), "push", "subscriptions"); err != nil {
		return err
	}
	if err := m.migrateJSON(ctx, filepath.Join(m.sourceDir, "notifications.json"), "notifications", "store"); err != nil {
		return err
	}
	return m.migrateImports(ctx, filepath.Join(m.sourceDir, "imports"))
}

func (m *migration) migrateJSON(ctx context.Context, path, scope, key string) error {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !json.Valid(raw) {
		return fmt.Errorf("%s is not valid JSON", path)
	}
	m.jsonCount++
	log.Printf("json %s/%s <= %s", scope, key, path)
	if !m.write {
		return nil
	}
	var value json.RawMessage = raw
	return m.store.PutJSON(ctx, scope, key, value)
}

func (m *migration) migrateImports(ctx context.Context, importsDir string) error {
	entries, err := os.ReadDir(importsDir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		importID := entry.Name()
		if err := m.migrateImport(ctx, importID, filepath.Join(importsDir, importID)); err != nil {
			return err
		}
	}
	return nil
}

func (m *migration) migrateImport(ctx context.Context, importID, dir string) error {
	metaPath := filepath.Join(dir, "meta.json")
	raw, err := os.ReadFile(metaPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var meta map[string]any
	if err := json.Unmarshal(raw, &meta); err != nil {
		return fmt.Errorf("%s is not valid JSON: %w", metaPath, err)
	}
	for _, candidate := range []struct {
		field string
		key   string
	}{
		{"inputFile", "original"},
		{"documentFile", "document"},
	} {
		path, _ := meta[candidate.field].(string)
		if path == "" {
			continue
		}
		if !isPathInside(dir, path) {
			log.Printf("skip %s outside legacy import directory: %s", candidate.field, path)
			continue
		}
		key, err := m.migrateImportFile(ctx, importID, candidate.key, path)
		if err != nil {
			return err
		}
		if key != "" {
			meta[candidate.field+"Key"] = key
		}
	}
	if err := m.migrateImportDirectoryFiles(ctx, importID, dir, meta); err != nil {
		return err
	}
	m.jsonCount++
	log.Printf("json imports/%s/meta <= %s", importID, metaPath)
	if !m.write {
		return nil
	}
	return m.store.PutJSON(ctx, "imports", importID+"/meta", meta)
}

func (m *migration) migrateImportDirectoryFiles(ctx context.Context, importID, dir string, meta map[string]any) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == "meta.json" {
			continue
		}
		keyName := importRuntimeFileName(entry.Name())
		if keyName == "" {
			continue
		}
		key, err := m.migrateImportFile(ctx, importID, keyName, filepath.Join(dir, entry.Name()))
		if err != nil {
			return err
		}
		switch keyName {
		case "original":
			setDefault(meta, "inputFileKey", key)
		case "document":
			setDefault(meta, "documentFileKey", key)
		case "generated":
			setDefault(meta, "generatedFileKey", key)
		case "deduped":
			setDefault(meta, "dedupedFileKey", key)
		}
	}
	return nil
}

func (m *migration) migrateImportFile(ctx context.Context, importID, name, path string) (string, error) {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	key := importID + "/" + name
	m.fileCount++
	log.Printf("file imports/%s <= %s", key, path)
	if !m.write {
		return key, nil
	}
	return key, m.store.PutFile(ctx, "imports", key, raw)
}

func importRuntimeFileName(filename string) string {
	name := strings.TrimSuffix(filename, filepath.Ext(filename))
	lower := strings.ToLower(name)
	switch {
	case lower == "original":
		return "original"
	case lower == "document":
		return "document"
	case strings.Contains(lower, "dedup"):
		return "deduped"
	case strings.HasSuffix(strings.ToLower(filename), ".bean"):
		return "generated"
	default:
		return ""
	}
}

func setDefault(meta map[string]any, key, value string) {
	if value == "" {
		return
	}
	if existing, _ := meta[key].(string); existing == "" {
		meta[key] = value
	}
}

func isPathInside(root, path string) bool {
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	pathAbs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(rootAbs, pathAbs)
	return err == nil && rel != "." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && rel != ".."
}
