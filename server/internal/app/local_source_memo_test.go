package app

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLocalSourceVersionSeesInPlaceEditBehindRestoredMtime(t *testing.T) {
	root := t.TempDir()
	write := func(name, text string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("main.bean", "include \"tx/*.bean\"\n2026-01-01 open Assets:Cash\n")
	write("tx/a.bean", "2026-01-02 * \"A\" \"one\"\n  Assets:Cash 1.00 CNY\n  Assets:Cash -1.00 CNY\n")
	cfg := Config{localTransport: true, localEntrypoint: "main.bean", LedgerRoot: root}

	first, err := ledgerVersion(cfg)
	if err != nil {
		t.Fatal(err)
	}
	again, err := ledgerVersion(cfg)
	if err != nil || again.Version != first.Version || again.FileCount != 2 {
		t.Fatalf("memoized version changed: %+v %+v %v", first, again, err)
	}

	// Same length and the original mtime: only the change time differs.
	path := filepath.Join(root, "tx/a.bean")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	write("tx/a.bean", "2026-01-02 * \"B\" \"one\"\n  Assets:Cash 1.00 CNY\n  Assets:Cash -1.00 CNY\n")
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	edited, err := ledgerVersion(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if edited.Version == first.Version {
		t.Fatal("an in-place edit must change the source version")
	}

	// A new file matching an existing glob is found even though main.bean
	// itself is served from the memo.
	write("tx/b.bean", "2026-01-03 * \"C\" \"two\"\n  Assets:Cash 2.00 CNY\n  Assets:Cash -2.00 CNY\n")
	grown, err := ledgerVersion(cfg)
	if err != nil || grown.FileCount != 3 || grown.Version == edited.Version {
		t.Fatalf("new included file was not observed: %+v %v", grown, err)
	}

	// Include validation still runs on memo hits.
	write("main.bean", "include \"/etc/hosts\"\n")
	if _, err := ledgerVersion(cfg); err == nil {
		t.Fatal("absolute includes must stay rejected")
	}
}
