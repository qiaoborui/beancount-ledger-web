package app

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func testLedger(t *testing.T) Config {
	t.Helper()
	if os.Getenv("AUTH_SECRET") == "" {
		t.Setenv("AUTH_SECRET", "test-auth-secret-with-enough-entropy")
	}
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "commodities.bean"), "2026-01-01 commodity CNY\n")
	mustWrite(t, filepath.Join(root, "accounts.bean"), strings.Join([]string{
		"2026-01-01 open Assets:Cash CNY",
		`  alias: "现金"`,
		"2026-01-01 open Expenses:Food CNY",
		"2026-01-01 open Income:Salary CNY",
		"2026-01-01 open Equity:Opening-Balances CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(root, "budgets.bean"), `2026-01-01 custom "budget" Expenses:Food "monthly" 1000.00 CNY`+"\n")
	mustWrite(t, filepath.Join(root, "prices.bean"), "")
	mustWrite(t, filepath.Join(root, "transactions", "2026", "05.bean"), strings.Join([]string{
		`2026-05-01 * "Cafe" "Lunch" #work`,
		`  note: "noodles"`,
		"  Expenses:Food 12.00 CNY",
		"  Assets:Cash -12.00 CNY",
		"",
		`2026-05-31 * "Employer" "Salary"`,
		"  Assets:Cash 1000.00 CNY",
		"  Income:Salary -1000.00 CNY",
		"",
	}, "\n"))
	mustWrite(t, filepath.Join(root, "main.bean"), strings.Join([]string{
		`option "title" "Test Ledger"`,
		`option "operating_currency" "CNY"`,
		`include "commodities.bean"`,
		`include "accounts.bean"`,
		`include "budgets.bean"`,
		`include "prices.bean"`,
		`include "transactions/2026/05.bean"`,
		"",
	}, "\n"))
	return Config{AppRoot: root, LedgerRoot: root, RuntimeDir: filepath.Join(root, ".runtime"), StaticDir: filepath.Join(root, "dist"), Port: "0"}
}

func mustWrite(t *testing.T, file string, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}
func loginCookies(t *testing.T, router http.Handler) []*http.Cookie {
	t.Helper()
	login := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewBufferString(`{"password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(login, req)
	if login.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", login.Code, login.Body.String())
	}
	return login.Result().Cookies()
}

func requestWithCookies(router http.Handler, method, path, body string, cookies []*http.Cookie) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(recorder, req)
	return recorder
}

func mustRead(t *testing.T, file string) []byte {
	t.Helper()
	content, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return content
}

func runGit(t *testing.T, cfg Config, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-c", "safe.directory=" + cfg.LedgerRoot, "-C", cfg.LedgerRoot}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func hasGitChange(changes []GitChange, path string) bool {
	for _, change := range changes {
		if change.Path == path || change.OriginalPath == path {
			return true
		}
	}
	return false
}
