package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Registers a large multi-file ledger once, then measures what every later
// request through the model handle pays: handle resolution plus a query.
func BenchmarkLocalRegisteredModelRequest(b *testing.B) {
	const files, perFile = 200, 250 // 50k transactions
	gin.SetMode(gin.ReleaseMode)
	ledger := b.TempDir()
	root := filepath.Join(ledger, "generations", "bench", "workspace")
	if err := os.MkdirAll(filepath.Join(root, "transactions"), 0700); err != nil {
		b.Fatal(err)
	}
	var main strings.Builder
	main.WriteString("option \"operating_currency\" \"CNY\"\n2020-01-01 open Assets:Cash CNY\n2020-01-01 open Expenses:Food CNY\n")
	var stream bytes.Buffer
	write := func(v any) {
		if err := json.NewEncoder(&stream).Encode(v); err != nil {
			b.Fatal(err)
		}
	}
	write(map[string]any{"type": "header", "version": 1})
	write(map[string]any{"type": "option", "key": "operating_currency", "value": "CNY"})
	write(map[string]any{"type": "commodity", "value": "CNY"})
	for f := 0; f < files; f++ {
		name := fmt.Sprintf("transactions/%04d.bean", f)
		fmt.Fprintf(&main, "include \"%s\"\n", name)
		var src strings.Builder
		line := 1
		for i := 0; i < perFile; i++ {
			date := fmt.Sprintf("2026-%02d-%02d", (f+i)%9+1, i%28+1)
			fmt.Fprintf(&src, "%s * \"Shop\" \"Expense %d\"\n  Expenses:Food  10.00 CNY\n  Assets:Cash  -10.00 CNY\n\n", date, i)
			write(map[string]any{"type": "entry", "entry": map[string]any{"Kind": "transaction", "Date": date, "Flag": "*", "File": name, "Line": line, "Narration": "Expense"}})
			for _, amount := range []string{"10.00", "-10.00"} {
				account := "Expenses:Food"
				if amount[0] == '-' {
					account = "Assets:Cash"
				}
				write(map[string]any{"type": "posting", "posting": map[string]any{"account": account, "Quantity": map[string]string{"Number": amount, "Currency": "CNY"}}})
			}
			write(map[string]any{"type": "end_entry"})
			line += 4
		}
		if err := os.WriteFile(filepath.Join(root, name), []byte(src.String()), 0600); err != nil {
			b.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(main.String()), 0600); err != nil {
		b.Fatal(err)
	}
	sum := sha256.Sum256(stream.Bytes())
	write(map[string]any{"type": "footer", "entries": files * perFile, "sha256": hex.EncodeToString(sum[:])})
	streamDir := filepath.Join(ledger, "runtime", "canonical-stream")
	if err := os.MkdirAll(streamDir, 0700); err != nil {
		b.Fatal(err)
	}
	streamName := strings.Repeat("b", 32) + ".records"
	if err := os.WriteFile(filepath.Join(streamDir, streamName), stream.Bytes(), 0600); err != nil {
		b.Fatal(err)
	}
	input := LocalRequest{WorkspaceRoot: root, RuntimeRoot: filepath.Join(ledger, "runtime"), Method: "GET"}
	version, err := LocalModelSourceVersion(input)
	if err != nil {
		b.Fatal(err)
	}
	handle, err := RegisterLocalModel(input, streamName, version)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { ReleaseLocalModel(handle) })
	input.ModelHandle = handle
	input.Path = "/api/ledger/transactions"
	input.Query = map[string]string{"limit": "50"}
	// The first request builds the snapshot; steady state is what users feel.
	if status, body, err := DispatchLocalRequest(input); status != http.StatusOK || err != nil {
		b.Fatalf("warmup status=%d err=%v body=%s", status, err, body)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if status, _, err := DispatchLocalRequest(input); status != http.StatusOK || err != nil {
			b.Fatalf("status=%d err=%v", status, err)
		}
	}
}
