package app

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func localTestRequest(t *testing.T) LocalRequest {
	t.Helper()
	fixture := testLedger(t)
	ledger := t.TempDir()
	root := filepath.Join(ledger, "generations", "initial", "workspace")
	if err := os.CopyFS(root, os.DirFS(fixture.LedgerRoot)); err != nil {
		t.Fatal(err)
	}
	return LocalRequest{WorkspaceRoot: root, RuntimeRoot: filepath.Join(ledger, "runtime"), Method: "GET",
		Query: map[string]string{"start": "2026-05-01", "end": "2026-06-01", "today": "2026-05-31", "month": "2026-05"}}
}

func localTestDispatch(t *testing.T, input LocalRequest) json.RawMessage {
	t.Helper()
	status, result, err := DispatchLocalRequest(input)
	if err != nil || status != 200 {
		t.Fatalf("%s %s: status=%d err=%v result=%s", input.Method, input.Path, status, err, result)
	}
	return result
}

func TestLocalTransportReadEndpointsAndNativeBQL(t *testing.T) {
	input := localTestRequest(t)
	// Even a host configured for remote storage must use the explicit local
	// configuration and must never reach the network server below.
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unexpected network request: %s", r.URL)
		w.WriteHeader(500)
	}))
	defer remote.Close()
	t.Setenv("LEDGER_STORAGE", "github_api")
	t.Setenv("LEDGER_GITHUB_API_URL", remote.URL)
	t.Setenv("DATABASE_URL", "postgres://invalid.example/database")
	for _, suffix := range []string{"bootstrap", "summary", "transactions", "income-statement", "dashboard", "home-report", "reconciliation", "version", "entries", "balances", "investments", "account-status", "accounts", "insights", "notifications", "index-info", "bql-history", "imports/providers", "imports/documents", "editor/files"} {
		t.Run(suffix, func(t *testing.T) { input.Path = "/api/ledger/" + suffix; localTestDispatch(t, input) })
	}
	input.Path = "/api/ledger/accounts/detail"
	input.Query["account"] = "Assets:Cash"
	localTestDispatch(t, input)
	input.Path = "/api/ledger/editor/file"
	input.Query["path"] = "main.bean"
	localTestDispatch(t, input)
	input.Path, input.Method = "/api/ledger/bql", "POST"
	input.Body = json.RawMessage(`{"query":"SELECT account, sum(value) FROM postings GROUP BY account"}`)
	localTestDispatch(t, input)
}

func TestLocalTransportWritesOnlyStageAndKeepsSourceStable(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/transactions"
	var transactions TransactionQueryResult
	if err := json.Unmarshal(localTestDispatch(t, input), &transactions); err != nil {
		t.Fatal(err)
	}
	if len(transactions.Transactions) == 0 {
		t.Fatal("transactions missing")
	}
	source := transactions.Transactions[0].Source
	if filepath.IsAbs(source.File) {
		t.Fatalf("source should survive generations: %s", source.File)
	}
	input.Method, input.Path = "POST", "/api/ledger/append"
	input.Body = json.RawMessage(`{"kind":"transaction","date":"2026-05-15","payee":"Local shop","narration":"Test","currency":"CNY","postings":[{"account":"Expenses:Food","amount":"3.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-3.00","currency":"CNY"}]}`)
	if status, _, err := DispatchLocalRequest(input); status != 409 || err == nil {
		t.Fatalf("generation mutation status=%d err=%v", status, err)
	}
	input.Staging = true
	if status, _, err := DispatchLocalRequest(input); status != 400 || err == nil {
		t.Fatalf("forged stage status=%d err=%v", status, err)
	}
	generation := input.WorkspaceRoot
	stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(generation))), "staging", "proposal", "workspace")
	if err := os.CopyFS(stage, os.DirFS(generation)); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot = stage
	t.Setenv("BEAN_CHECK_BIN", "/this-command-must-never-run-on-ios")
	localTestDispatch(t, input)
	if strings.Contains(string(mustRead(t, filepath.Join(generation, "transactions/2026/05.bean"))), "Local shop") {
		t.Fatal("generation was mutated")
	}
	if !strings.Contains(string(mustRead(t, filepath.Join(stage, "transactions/2026/05.bean"))), "Local shop") {
		t.Fatal("stage was not mutated")
	}
	input.Method, input.Path = "DELETE", "/api/ledger/transactions"
	input.Body, _ = json.Marshal(map[string]any{"source": source, "reason": "Test"})
	localTestDispatch(t, input)
}

func TestLocalTransportPathsAndAuthBoundary(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ai/agent/turn"
	if status, _, _ := DispatchLocalRequest(input); status != 501 {
		t.Fatalf("cloud path status=%d", status)
	}
	input.Path = "/api/ledger/summary"
	input.Entrypoint = "../main.bean"
	if status, _, _ := DispatchLocalRequest(input); status != 400 {
		t.Fatalf("entry escape status=%d", status)
	}
	input.Entrypoint = ""
	mustWrite(t, filepath.Join(input.WorkspaceRoot, "main.bean"), "include \"../../../../outside.bean\"\n")
	if status, _, _ := DispatchLocalRequest(input); status != 400 {
		t.Fatalf("include escape status=%d", status)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(input.WorkspaceRoot, "link")); err != nil {
		t.Fatal(err)
	}
	if status, _, _ := DispatchLocalRequest(input); status != 400 {
		t.Fatalf("symlink status=%d", status)
	}
	t.Setenv("AUTH_PASSWORD", "secret")
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("GET", "/api/ledger/summary", nil)
	if localRequestAuthenticated(c) {
		t.Fatal("ordinary HTTP request gained local auth")
	}
}

func TestLocalTransportGlobEntrypointAndDefaultImport(t *testing.T) {
	input := localTestRequest(t)
	main := strings.ReplaceAll(string(mustRead(t, filepath.Join(input.WorkspaceRoot, "main.bean"))), `include "transactions/2026/05.bean"`, `include "transactions/*/*.bean"`)
	mustWrite(t, filepath.Join(input.WorkspaceRoot, "other.bean"), main)
	input.Entrypoint, input.Path = "other.bean", "/api/ledger/bootstrap"
	localTestDispatch(t, input)
	input.Path, input.Method = "/api/ledger/imports/preview", "POST"
	input.ImportFile = &LocalImportFile{Name: "alipay.csv", Data: base64.StdEncoding.EncodeToString(alipayCSVFixture())}
	input.Body = json.RawMessage(`{"provider":"alipay"}`)
	result := localTestDispatch(t, input)
	if !strings.Contains(string(result), `"entries":[`) {
		t.Fatalf("missing preview entries: %s", result)
	}
	if _, err := os.Stat(filepath.Join(input.WorkspaceRoot, "imports/alipay-config.yaml")); !os.IsNotExist(err) {
		t.Fatal("default import config mutated snapshot")
	}
	var preview struct {
		ImportID string        `json:"importId"`
		Entries  []ImportEntry `json:"entries"`
	}
	if err := json.Unmarshal(result, &preview); err != nil {
		t.Fatal(err)
	}
	if len(preview.Entries) != 1 {
		t.Fatalf("preview entries=%d, result=%s", len(preview.Entries), result)
	}
	original := input.WorkspaceRoot
	stage := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(original))), "staging", "import", "workspace")
	if err := os.CopyFS(stage, os.DirFS(original)); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot, input.Path, input.Staging, input.ImportFile = stage, "/api/ledger/imports/commit", true, nil
	input.Body, _ = json.Marshal(map[string]any{"importId": preview.ImportID, "provider": "alipay", "entries": preview.Entries})
	localTestDispatch(t, input)
	// Canonical validation may still reject this proposal. A fresh staging
	// attempt must retain access to the original preview until publication.
	retryStage := filepath.Join(filepath.Dir(filepath.Dir(stage)), "retry", "workspace")
	if err := os.CopyFS(retryStage, os.DirFS(original)); err != nil {
		t.Fatal(err)
	}
	input.WorkspaceRoot = retryStage
	localTestDispatch(t, input)
}

func TestLocalReconciliationSnapshotRouteMatchesLegacyAndBounds(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/reconciliation/snapshot"
	input.Query = map[string]string{"start": "2026-05-01", "end": "2026-06-01"}
	raw := localTestDispatch(t, input)
	var native localReconciliationSnapshot
	if err := json.Unmarshal(raw, &native); err != nil {
		t.Fatal(err)
	}
	if !native.SensitiveUnlocked || native.Start != "2026-05-01" || native.End != "2026-06-01" || len(native.Rows) == 0 {
		t.Fatalf("invalid snapshot: %#v", native)
	}
	status, legacyRaw, err := DispatchLocalRequest(LocalRequest{WorkspaceRoot: input.WorkspaceRoot, RuntimeRoot: input.RuntimeRoot, Entrypoint: input.Entrypoint, Method: "GET", Path: "/api/ledger/reconciliation", Query: input.Query})
	if status != 200 || err != nil {
		t.Fatal(status, err)
	}
	var legacy struct {
		Rows []ReconciliationRow `json:"rows"`
	}
	_ = json.Unmarshal(legacyRaw, &legacy)
	if !reflect.DeepEqual(native.Rows, legacy.Rows) {
		t.Fatal("snapshot differs from legacy rows")
	}
	if len(raw) > localTransactionPageBytes-4096 {
		t.Fatal("snapshot exceeds budget")
	}
}
func TestLocalReconciliationSnapshotRejectsStagingAndRanges(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/reconciliation/snapshot"
	for _, q := range []map[string]string{{"start": "bad", "end": "2026-06-01"}, {"start": "2026-06-01", "end": "2026-05-01"}, {"start": "2026-05-01", "end": "2026-06-01", "q": ""}} {
		input.Query = q
		if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil {
			t.Fatal(status, err)
		}
	}
	input.Query = map[string]string{"start": "2026-05-01", "end": "2026-06-01"}
	input.Staging = true
	if status, raw, err := DispatchLocalRequest(input); status != 400 || raw != nil || err == nil {
		t.Fatal(status, err)
	}
}
