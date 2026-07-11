package app

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLedgerEditorFilesReadAndSave(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	mustWrite(t, filepath.Join(cfg.RuntimeDir, "state.bean"), "should not show\n")

	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	files := requestWithCookies(router, http.MethodGet, "/api/ledger/editor/files", "", cookies)
	if files.Code != http.StatusOK {
		t.Fatalf("files status=%d body=%s", files.Code, files.Body.String())
	}
	var filesBody struct {
		Files []LedgerEditorFile `json:"files"`
	}
	if err := json.Unmarshal(files.Body.Bytes(), &filesBody); err != nil {
		t.Fatal(err)
	}
	if !containsEditorPath(filesBody.Files, "main.bean") || !containsEditorPath(filesBody.Files, "transactions/2026/05.bean") {
		t.Fatalf("expected ledger files in editor list: %#v", filesBody.Files)
	}
	if containsEditorPath(filesBody.Files, ".runtime/state.bean") {
		t.Fatalf("runtime file should not be editable: %#v", filesBody.Files)
	}

	file := requestWithCookies(router, http.MethodGet, "/api/ledger/editor/file?path=main.bean", "", cookies)
	if file.Code != http.StatusOK {
		t.Fatalf("file status=%d body=%s", file.Code, file.Body.String())
	}
	var fileBody struct {
		Content string `json:"content"`
		Hash    string `json:"hash"`
	}
	if err := json.Unmarshal(file.Body.Bytes(), &fileBody); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fileBody.Content, `option "title" "Test Ledger"`) || fileBody.Hash == "" {
		t.Fatalf("unexpected editor file body: %#v", fileBody)
	}

	next := strings.TrimRight(fileBody.Content, "\n") + "\n; edited online\n"
	saveBody := `{"path":"main.bean","content":` + quoteJSON(next) + `,"previousHash":"` + fileBody.Hash + `"}`
	save := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", saveBody, cookies)
	if save.Code != http.StatusOK {
		t.Fatalf("save status=%d body=%s", save.Code, save.Body.String())
	}
	if text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))); !strings.Contains(text, "; edited online") {
		t.Fatalf("file was not saved:\n%s", text)
	}
}

func TestLedgerEditorRejectsUnsafeAndStaleWrites(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	traversal := requestWithCookies(router, http.MethodGet, "/api/ledger/editor/file?path=../secret.bean", "", cookies)
	if traversal.Code != http.StatusBadRequest {
		t.Fatalf("traversal status=%d body=%s", traversal.Code, traversal.Body.String())
	}

	stale := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", `{"path":"main.bean","content":"; stale\n","previousHash":"not-current"}`, cookies)
	if stale.Code != http.StatusConflict {
		t.Fatalf("stale status=%d body=%s", stale.Code, stale.Body.String())
	}
	if text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean"))); strings.Contains(text, "; stale") {
		t.Fatalf("stale write should not change file:\n%s", text)
	}
}

func TestLedgerEditorRollsBackOnBeanCheckFailure(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 1\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	before := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean")))
	save := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", `{"path":"main.bean","content":"; invalid\n"}`, cookies)
	if save.Code != http.StatusBadRequest {
		t.Fatalf("save status=%d body=%s", save.Code, save.Body.String())
	}
	after := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "main.bean")))
	if after != before {
		t.Fatalf("failed editor save should rollback:\nbefore=%s\nafter=%s", before, after)
	}
}

func TestGitHubLedgerEditorReturnsSuccessWithoutPostCommitRead(t *testing.T) {
	initial := "option \"title\" \"Test\"\n"
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": initial})
	fake.failNextContentReadAfterCommit = true
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	next := "option \"title\" \"Updated\"\n"
	body := `{"path":"main.bean","content":` + quoteJSON(next) + `,"previousHash":"` + sha256Hex([]byte(initial))[:16] + `"}`

	res := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", body, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("save status=%d body=%s", res.Code, res.Body.String())
	}
	if fake.commitCount != 1 {
		t.Fatalf("commit count=%d, want 1", fake.commitCount)
	}
}

func TestGitHubLedgerEditorRetryWithSameContentIsIdempotent(t *testing.T) {
	initial := "option \"title\" \"Test\"\n"
	fake := newFakeGitHubLedgerAPI(t, map[string]string{"main.bean": initial})
	defer fake.server.Close()

	cfg := githubAPITestConfig(t, fake)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)
	next := "option \"title\" \"Updated\"\n"
	body := `{"path":"main.bean","content":` + quoteJSON(next) + `,"previousHash":"` + sha256Hex([]byte(initial))[:16] + `"}`

	first := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", body, cookies)
	if first.Code != http.StatusOK {
		t.Fatalf("first save status=%d body=%s", first.Code, first.Body.String())
	}
	second := requestWithCookies(router, http.MethodPut, "/api/ledger/editor/file", body, cookies)
	if second.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", second.Code, second.Body.String())
	}
	if fake.commitCount != 1 {
		t.Fatalf("retry created duplicate commit count=%d", fake.commitCount)
	}
}

func containsEditorPath(files []LedgerEditorFile, path string) bool {
	for _, file := range files {
		if file.Path == path {
			return true
		}
	}
	return false
}

func quoteJSON(value string) string {
	bytes, _ := json.Marshal(value)
	return string(bytes)
}
