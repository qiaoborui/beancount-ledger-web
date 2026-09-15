package mobilecore

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDispatchCanonicalPythonPluginValuation(t *testing.T) {
	python := "../.build/beancount-ios/test-venv/bin/python"
	if _, err := os.Stat(python); err != nil {
		t.Skip("pinned Beancount test interpreter unavailable")
	}
	root := filepath.Join(t.TempDir(), "generations", "initial", "workspace")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	const source = `option "operating_currency" "USD"
plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2026-09-01 * "Plugin fixture" "Buy stock"
  file: "receipt.pdf"
  Assets:Stock  2 HOOL {10 USD}
  Assets:Cash  -20 USD
`
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(python, "-c", `import sys; sys.path.insert(0, '../../App/LedgerMobile/Runtime'); from ledger_validator import validate_json; print(validate_json(sys.argv[1]))`, root)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v %s", err, output)
	}
	var validation struct {
		Canonical json.RawMessage `json:"canonical"`
	}
	if err := json.Unmarshal(output, &validation); err != nil || len(validation.Canonical) == 0 {
		t.Fatalf("%v %s", err, output)
	}
	request, _ := json.Marshal(map[string]any{"version": 1, "operation": "request", "workspaceRoot": root, "path": "/api/ledger/bootstrap", "canonical": validation.Canonical,
		"query": map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-15", "valuationCurrency": "USD"}})
	var response dispatchResponseV1
	if err := json.Unmarshal([]byte(DispatchJSON(string(request))), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK {
		t.Fatalf("%+v", response)
	}
	var result struct {
		AccountBalances []struct {
			Account           string
			Amount            int
			Valuation         int
			Currency          string
			ValuationCurrency string
			ValuationMissing  bool
		} `json:"accountBalances"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatal(err)
	}
	for _, row := range result.AccountBalances {
		if row.Account == "Assets:Stock" {
			if row.Amount != 200 || row.Valuation != 2000 || row.ValuationMissing {
				t.Fatalf("row=%+v\ncanonical=%s\nresult=%s", row, validation.Canonical, response.Result)
			}
			return
		}
	}
	t.Fatalf("stock absent: %s", response.Result)
}
