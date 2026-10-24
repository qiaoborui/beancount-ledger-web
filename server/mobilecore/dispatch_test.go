package mobilecore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime/debug"
	"testing"
)

func TestDispatchJSONContract(t *testing.T) {
	root := filepath.Join(t.TempDir(), "generations", "initial", "workspace")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte("option \"operating_currency\" \"CNY\"\n2026-01-01 open Assets:Cash CNY\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	request, _ := json.Marshal(map[string]any{"version": 1, "operation": "request", "workspaceRoot": root, "path": "/api/ledger/bootstrap"})
	var response dispatchResponseV1
	if err := json.Unmarshal([]byte(DispatchJSON(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Status != 200 || len(response.Result) == 0 || len(response.Diagnostics) != 0 {
		t.Fatalf("unexpected response: %+v", response)
	}
	for _, invalid := range []string{`{"version":2,"operation":"request"}`, `{"version":1,"operation":"request","host":"https://example.com"}`, `{} {}`} {
		if err := json.Unmarshal([]byte(DispatchJSON(invalid)), &response); err != nil {
			t.Fatal(err)
		}
		if response.OK || response.Status != 400 || len(response.Diagnostics) == 0 {
			t.Fatalf("invalid request accepted: %s", invalid)
		}
	}
}

func TestDispatchControlOperationsNeedNoLedgerRequest(t *testing.T) {
	// The shell sends these before a ledger exists, so they carry only their
	// control field and must still pass the strict decoder.
	previous := debug.SetMemoryLimit(-1)
	t.Cleanup(func() { debug.SetMemoryLimit(previous) })
	requests := []struct {
		operation string
		extra     string
		check     func(t *testing.T, response dispatchResponseV1)
	}{
		{"memory-limit", `,"availableBytes":1610612736`, func(t *testing.T, response dispatchResponseV1) {
			var result struct {
				MemoryLimit int64 `json:"memoryLimit"`
			}
			if err := json.Unmarshal(response.Result, &result); err != nil {
				t.Fatal(err)
			}
			if result.MemoryLimit != 768<<20 {
				t.Fatalf("memoryLimit = %d, want %d", result.MemoryLimit, 768<<20)
			}
		}},
		{"model-release-idle", `,"modelHandle":"missing"`, func(t *testing.T, response dispatchResponseV1) {
			var result struct {
				Released int `json:"released"`
			}
			if err := json.Unmarshal(response.Result, &result); err != nil {
				t.Fatal(err)
			}
			if result.Released != 0 {
				t.Fatalf("released = %d, want 0", result.Released)
			}
		}},
	}
	for _, request := range requests {
		t.Run(request.operation, func(t *testing.T) {
			raw := `{"version":1,"operation":"` + request.operation + `"` + request.extra + `}`
			var response dispatchResponseV1
			if err := json.Unmarshal([]byte(DispatchJSON(raw)), &response); err != nil {
				t.Fatal(err)
			}
			if !response.OK || response.Status != 200 || len(response.Result) == 0 || len(response.Diagnostics) != 0 {
				t.Fatalf("unexpected response: %+v", response)
			}
			request.check(t, response)
		})
	}
}
