package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestFilesystemRuntimeFileStoreMaterializeFile(t *testing.T) {
	root := t.TempDir()
	store := newFilesystemRuntimeStore(root)
	ctx := context.Background()

	if err := store.PutFile(ctx, "imports", "preview123/original", []byte("statement")); err != nil {
		t.Fatal(err)
	}
	file, ok, err := store.GetFile(ctx, "imports", "preview123/original")
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("file was not found")
	}
	if string(file.Content) != "statement" || file.Size != int64(len("statement")) {
		t.Fatalf("file = %#v", file)
	}

	localPath := filepath.Join(t.TempDir(), "original.csv")
	ok, err = store.MaterializeFile(ctx, "imports", "preview123/original", localPath)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("materialized file was not found")
	}
	raw, err := os.ReadFile(localPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "statement" {
		t.Fatalf("materialized content = %q", string(raw))
	}
}

func TestImportMetadataFilesystemPathCompatibility(t *testing.T) {
	cfg := Config{RuntimeDir: t.TempDir()}
	server := &Server{cfg: cfg}
	ctx := context.Background()
	meta := importMeta{Provider: "alipay", OriginalFilename: "alipay.csv", InputFile: "/tmp/alipay.csv"}

	if err := server.writeImportMeta(ctx, "preview123", meta); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(cfg.RuntimeDir, "imports", "preview123", "meta.json")); err != nil {
		t.Fatal(err)
	}
	got, err := server.readImportMeta(ctx, "preview123")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != meta.Provider || got.OriginalFilename != meta.OriginalFilename || got.InputFile != meta.InputFile {
		t.Fatalf("meta = %#v", got)
	}
}
