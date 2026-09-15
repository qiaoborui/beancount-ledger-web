package mobilecore

import (
	"encoding/json"
	"os"
	"path/filepath"
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
