package mobileagent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGlobRegexp(t *testing.T) {
	cases := []struct {
		pattern, name string
		want          bool
	}{
		{"*.bean", "main.bean", true},
		{"*.bean", "2026/10.bean", true},
		{"2026/*.bean", "2026/10.bean", true},
		{"2026/*.bean", "2026/q4/10.bean", false},
		{"documents/**/*.pdf", "documents/a.pdf", true},
		{"documents/**/*.pdf", "documents/x/y/a.pdf", true},
		{"documents/**/*.pdf", "other/a.pdf", false},
		{"*.{csv,xlsx}", "imports/b.xlsx", true},
		{"0?.bean", "2026/01.bean", true},
	}
	for _, c := range cases {
		re, err := globRegexp(c.pattern)
		if err != nil {
			t.Fatalf("%s: %v", c.pattern, err)
		}
		if got := re.MatchString(c.name); got != c.want {
			t.Errorf("%s ~ %s = %v, want %v", c.pattern, c.name, got, c.want)
		}
	}
	if _, err := globRegexp("{a,b"); err == nil {
		t.Error("unclosed brace was accepted")
	}
}

func writeTree(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, text := range files {
		target := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func call(t *testing.T, run func(json.RawMessage) (any, error), args map[string]any) (string, error) {
	t.Helper()
	raw, _ := json.Marshal(args)
	out, err := run(raw)
	if err != nil {
		return "", err
	}
	data, _ := json.Marshal(out)
	return string(data), nil
}

func TestGrepListCopyAndMoveWorkLikeACodingAgent(t *testing.T) {
	dir := scratchCopy(t)
	writeTree(t, dir, map[string]string{
		"2026/10.bean":          "2026-10-01 * \"午饭\"\n  Expenses:Food  30 CNY\n  Assets:Cash\n",
		"2026/11.bean":          "2026-11-01 * \"地铁\"\n  Expenses:Transport  4 CNY\n  Assets:Cash\n",
		".git/config":           "Expenses:Food secret\n",
		"documents/a/x.pdf":     "%PDF\x00binary",
		"documents/a/notes.md":  "food notes\n",
		"importers/config.yaml": "food: Expenses:Food\n",
	})
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()

	out, err := call(t, files.grepFiles, map[string]any{"pattern": "Expenses:Food", "glob": "*.bean"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `2026/10.bean:2:  Expenses:Food  30 CNY`) || strings.Contains(out, ".git") || strings.Contains(out, "config.yaml") {
		t.Fatalf("grep = %s", out)
	}
	out, _ = call(t, files.grepFiles, map[string]any{"pattern": "FOOD", "ignore_case": true, "path": "documents"})
	if !strings.Contains(out, "documents/a/notes.md:1:food notes") || strings.Contains(out, "x.pdf") {
		t.Fatalf("grep in folder = %s", out)
	}
	out, _ = call(t, files.grepFiles, map[string]any{"pattern": "午饭", "context": 1})
	if !strings.Contains(out, `2026/10.bean-2-  Expenses:Food`) {
		t.Fatalf("grep context = %s", out)
	}
	if _, err := call(t, files.grepFiles, map[string]any{"pattern": "("}); err == nil {
		t.Fatal("an invalid regexp was accepted")
	}

	out, _ = call(t, files.listFiles, map[string]any{"pattern": "2026/*.bean"})
	if !strings.Contains(out, "2026/10.bean") || strings.Contains(out, `"path":"main.bean"`) {
		t.Fatalf("list pattern = %s", out)
	}

	if _, err := call(t, files.copyFile, map[string]any{"from": "documents/a/x.pdf", "to": "archive/x.pdf"}); err != nil {
		t.Fatal(err)
	}
	if _, err := call(t, files.copyFile, map[string]any{"from": "2026/10.bean", "to": "2026/11.bean"}); err == nil {
		t.Fatal("copy overwrote without overwrite")
	}
	if _, err := call(t, files.moveFile, map[string]any{"from": "documents/a", "to": "documents/2026-10"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "documents/2026-10/x.pdf")); err != nil {
		t.Fatal("folder was not moved")
	}
	if _, err := call(t, files.moveFile, map[string]any{"from": "documents", "to": "documents/inner"}); err == nil {
		t.Fatal("a folder moved into itself")
	}
	if !files.wasEdited() {
		t.Fatal("copy and move did not mark the draft edited")
	}
}

func TestDraftChangesDiffsTheDraftAgainstTheLedger(t *testing.T) {
	committed := committedWorkspace(t)
	writeTree(t, committed, map[string]string{"old.bean": "; gone\n", "doc.pdf": "%PDF\x00a"})
	dir := scratchCopy(t)
	writeTree(t, dir, map[string]string{"doc.pdf": "%PDF\x00a", "new.bean": "; new\n"})
	main, _ := os.ReadFile(filepath.Join(committed, "main.bean"))
	edited := strings.Replace(string(main), "25.00 CNY", "26.00 CNY", 1)
	writeTree(t, dir, map[string]string{"main.bean": edited, "statement.pdf": "%PDF\x00b"})
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	files.committed = committed
	out, err := call(t, files.draftChanges, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"path":"main.bean","change":"modified","added":1,"removed":1`,
		`"path":"new.bean","change":"added"`, `"path":"old.bean","change":"deleted"`,
		`"path":"statement.pdf","change":"added","binary":true`, `-  Expenses:Food  25.00 CNY`, `+  Expenses:Food  26.00 CNY`,
		`--- /dev/null\n+++ new.bean`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
	if strings.Contains(out, "doc.pdf") {
		t.Errorf("an unchanged file was listed: %s", out)
	}
	out, _ = call(t, files.draftChanges, map[string]any{"path": "new.bean"})
	if strings.Contains(out, "main.bean") || !strings.Contains(out, "new.bean") {
		t.Errorf("path filter = %s", out)
	}
}

func TestUnifiedDiffHunks(t *testing.T) {
	old := []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}
	updated := []string{"a", "B", "c", "d", "e", "f", "g", "h", "i", "j", "k"}
	hunks, added, removed := unifiedDiff(old, updated, 1)
	got := strings.Join(hunks, "\n")
	want := "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n@@ -10,1 +10,2 @@\n j\n+k"
	if got != want || added != 2 || removed != 1 {
		t.Fatalf("diff =\n%s\n(+%d -%d)", got, added, removed)
	}
}
