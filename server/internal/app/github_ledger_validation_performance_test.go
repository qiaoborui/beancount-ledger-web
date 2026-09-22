package app

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const validationPerformanceIncludeCount = 120

func validationPerformanceLedger() map[string]string {
	files := make(map[string]string, validationPerformanceIncludeCount+1)
	files["main.bean"] = "option \"operating_currency\" \"CNY\"\n2020-01-01 open Assets:Cash CNY\n2020-01-01 open Expenses:Food CNY\ninclude \"transactions/*.bean\"\n"
	for file := 0; file < validationPerformanceIncludeCount; file++ {
		var content strings.Builder
		for transaction := 0; transaction < 100; transaction++ {
			fmt.Fprintf(&content, "2026-01-%02d * \"Fixture-%03d-%03d\" \"Synthetic test purchase\"\n  Expenses:Food 10.00 CNY\n  Assets:Cash -10.00 CNY\n\n", transaction%28+1, file, transaction)
		}
		files[fmt.Sprintf("transactions/%03d.bean", file)] = content.String()
	}
	return files
}

func TestGitHubWriteValidationLargeLedgerPerformance(t *testing.T) {
	binary, err := exec.LookPath("bean-check")
	if err != nil {
		if os.Getenv("LEDGER_VALIDATION_PERFORMANCE_REQUIRED") == "1" {
			t.Fatal("LEDGER_VALIDATION_PERFORMANCE_REQUIRED=1 requires real bean-check on PATH")
		}
		t.Skip("real bean-check is required for the large-ledger validation performance test")
	}
	t.Setenv("BEAN_CHECK_BIN", binary)
	files := validationPerformanceLedger()
	metrics := &validationDownloadMetrics{}
	metrics.installDefaultTransport(t)
	fake := &fakeGitHubLedgerAPI{
		t: t, files: files, blobs: map[string]string{}, treeBlobs: map[string]string{}, contentReads: map[string]int{},
	}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Model content latency outside the fake's state mutex. Handler cleanup
		// can outlive a client download, so measure at the transport instead.
		if isValidationContentDownload(r) {
			time.Sleep(20 * time.Millisecond)
		}
		fake.handle(w, r)
	}))
	t.Cleanup(fake.server.Close)
	cfg := githubAPITestConfig(t, fake)
	writer := NewLedgerWriter(cfg, nil)
	target := "transactions/000.bean"
	baseContent := files[target]
	var total time.Duration
	for write := 0; write < 3; write++ {
		started := time.Now()
		err := writer.ReplaceLedgerFile(filepath.Join(cfg.LedgerRoot, filepath.FromSlash(target)), []byte(fmt.Sprintf("%s; edit %d\n", baseContent, write+1)))
		elapsed := time.Since(started)
		total += elapsed
		if err != nil {
			t.Fatalf("write %d failed: %v", write+1, err)
		}
		requests, maxActive := metrics.take(t)
		t.Logf("write=%d includes=%d transactions=12000 elapsed=%s content_GETs=%d max_client_content_concurrency=%d", write+1, validationPerformanceIncludeCount, elapsed.Round(time.Millisecond), requests, maxActive)
		if write == 0 {
			if elapsed > 5*time.Second {
				t.Errorf("cold validated write took %s, budget is 5s", elapsed)
			}
			if maxActive <= 1 || maxActive > 6 {
				t.Errorf("cold content download concurrency=%d, want 2..6", maxActive)
			}
			if requests > validationPerformanceIncludeCount+1 {
				t.Errorf("cold content GETs=%d, want at most one per ledger file (%d)", requests, validationPerformanceIncludeCount+1)
			}
		} else {
			if elapsed > 2*time.Second {
				t.Errorf("warm validated write %d took %s, budget is 2s", write+1, elapsed)
			}
			if requests > 1 {
				t.Errorf("warm write %d downloaded %d files; unchanged validation content must be cached (only the edited file may need a writer read)", write+1, requests)
			}
		}
	}
	t.Logf("three consecutive validated writes: total=%s", total.Round(time.Millisecond))
	if fake.commitCount != 3 {
		t.Fatalf("commits=%d, want 3 validated edits", fake.commitCount)
	}
}
