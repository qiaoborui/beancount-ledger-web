package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func canonicalStreamFixture(t *testing.T, count int) []byte {
	t.Helper()
	var body bytes.Buffer
	write := func(v any) {
		if err := json.NewEncoder(&body).Encode(v); err != nil {
			t.Fatal(err)
		}
	}
	write(map[string]any{"type": "header", "version": 1})
	write(map[string]any{"type": "option", "key": "operating_currency", "value": "CNY"})
	write(map[string]any{"type": "commodity", "value": "CNY"})
	for i := 0; i < count; i++ {
		write(map[string]any{"type": "entry", "entry": map[string]any{"Kind": "transaction", "Date": "2026-09-01", "File": "main.bean", "Line": i + 1, "Narration": "Synthetic"}})
		for _, amount := range []string{"123.456789", "-123.456789"} {
			write(map[string]any{"type": "posting", "posting": map[string]any{"account": "Assets:Cash", "Quantity": map[string]string{"Number": amount, "Currency": "CNY"}}})
		}
		write(map[string]any{"type": "end_entry"})
	}
	sum := sha256.Sum256(body.Bytes())
	write(map[string]any{"type": "footer", "entries": count, "sha256": hex.EncodeToString(sum[:])})
	return body.Bytes()
}

func TestCanonicalStream100kExceedsBridgeBudgetWithoutWholeJSONDecode(t *testing.T) {
	raw := canonicalStreamFixture(t, 100000)
	if len(raw) <= 16<<20 {
		t.Fatal("fixture does not exceed legacy bridge request limit")
	}
	model, err := ReadLocalCanonicalStream(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(model.Entries) != 100000 || model.Options["operating_currency"] != "CNY" {
		t.Fatal("incomplete model")
	}
	for _, entry := range model.Entries {
		if len(entry.Postings) != 2 || entry.Postings[0].Quantity.Number != "123.456789" || entry.Postings[1].Quantity.Number != "-123.456789" {
			t.Fatal("posting precision/order changed")
		}
	}
}

func TestCanonicalStreamRejectsTruncationCorruptionAndOversizedRecords(t *testing.T) {
	raw := canonicalStreamFixture(t, 2)
	for name, input := range map[string][]byte{
		"empty":                 nil,
		"truncated":             raw[:len(raw)-1],
		"no-footer":             raw[:bytes.LastIndex(raw[:len(raw)-1], []byte("\n"))+1],
		"changed":               bytes.Replace(raw, []byte("Synthetic"), []byte("Corrupted"), 1),
		"trailing":              append(append([]byte{}, raw...), []byte("{}\n")...),
		"oversized":             []byte(strings.Repeat("x", localCanonicalRecordLimit+1) + "\n"),
		"posting-outside-entry": []byte("{\"type\":\"header\",\"version\":1}\n{\"type\":\"posting\"}\n"),
		"unsupported":           []byte("{\"type\":\"header\",\"version\":2}\n"),
		"unknown":               []byte("{\"type\":\"header\",\"version\":1,\"surprise\":true}\n"),
	} {
		t.Run(name, func(t *testing.T) {
			if model, err := ReadLocalCanonicalStream(bytes.NewReader(input)); err == nil || model != nil {
				t.Fatal("invalid stream accepted")
			}
		})
	}
}

func TestCanonicalStreamPythonParity(t *testing.T) {
	cfg := canonicalTestConfig(t, `plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2026-01-01 * "Buy"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
`)
	expected := canonicalPythonModel(t, cfg)
	python := os.Getenv("LOCAL_BEANCOUNT_PYTHON")
	if python == "" {
		python = "../../.build/beancount-ios/test-venv/bin/python"
	}
	output := filepath.Join(t.TempDir(), "canonical.records")
	// Resolve macOS /var alias, matching the exporter no-symlink policy.
	parent, err := filepath.EvalSymlinks(filepath.Dir(output))
	if err != nil {
		t.Fatal(err)
	}
	output = filepath.Join(parent, "canonical.records")
	cmd := exec.Command(python, "-c", `import sys,json; sys.path.insert(0, '../../../App/LedgerMobile/Runtime'); from ledger_validator import export_canonical_json; r=json.loads(export_canonical_json(sys.argv[1], 'main.bean',sys.argv[2])); assert not r['errors'], 'synthetic export failed'`, cfg.LedgerRoot, output)
	if raw, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("synthetic export: %v %s", err, raw)
	}
	file, err := os.Open(output)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	actual, err := ReadLocalCanonicalStream(file)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatal("stream model differs from legacy canonical")
	}
}
