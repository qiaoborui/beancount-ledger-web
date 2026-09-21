package mobilecore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/borui/beancount-ledger-web/server/internal/app"
	"github.com/gin-gonic/gin"
)

// Opt-in read-only baseline on an explicitly prepared disposable snapshot.
// Never logs response bodies, ledger paths, financial values, or diagnostics.
func TestDisposablePerformanceBaseline(t *testing.T) {
	if os.Getenv("LEDGER_PERF_DISPOSABLE_COPY") != "1" {
		t.Skip("disposable performance fixture not configured")
	}
	root, modelFile, output := os.Getenv("LEDGER_PERF_INPUT"), os.Getenv("LEDGER_PERF_CANONICAL"), os.Getenv("LEDGER_PERF_OUTPUT")
	if root == "" || modelFile == "" || output == "" {
		t.Fatal("missing performance configuration")
	}
	inputRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal("invalid input path")
	}
	outputParent, err := filepath.EvalSymlinks(filepath.Dir(output))
	if err != nil {
		t.Fatal("invalid output path")
	}
	outputPath := filepath.Join(outputParent, filepath.Base(output))
	rel, err := filepath.Rel(inputRoot, outputPath)
	if err != nil || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))) {
		t.Fatal("output must be outside input snapshot")
	}
	file, err := os.OpenFile(outputPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		t.Fatal("metrics output must be a new file")
	}
	gin.SetMode(gin.ReleaseMode)
	type metric struct {
		Name              string    `json:"name"`
		Milliseconds      []float64 `json:"milliseconds"`
		BytesPerOperation uint64    `json:"allocated_bytes_per_operation"`
		RequestBytes      int       `json:"request_bytes"`
	}
	var metrics []metric
	stage := "canonical_load"
	capacityCode := ""
	t.Cleanup(func() {
		defer file.Close()
		encoded, err := json.MarshalIndent(map[string]any{"schema": 1, "succeeded": !t.Failed(), "last_stage": stage, "capacity_code": capacityCode,
			"environment": "host Go; prebuilt canonical; warm filesystem/model; no Python/Swift/UI; bridge includes response verification; process-wide allocated bytes", "metrics": metrics}, "", "  ")
		if err != nil {
			t.Error("cannot encode numeric metrics")
			return
		}
		if _, err := file.Write(encoded); err != nil {
			t.Error("cannot write numeric metrics")
		}
	})
	raw, err := os.ReadFile(modelFile)
	if err != nil {
		t.Fatal("cannot read canonical fixture")
	}
	var model app.LocalCanonicalModel
	if json.Unmarshal(raw, &model) != nil {
		t.Fatal("invalid canonical fixture")
	}
	if len(raw) > 16<<20 {
		stage = "capacity_boundary"
		response := DispatchJSON(`{"version":1,"operation":"request","canonical":` + string(raw) + `}`)
		var envelope dispatchResponseV1
		if json.Unmarshal([]byte(response), &envelope) != nil || envelope.OK || envelope.Status != 400 ||
			len(envelope.Diagnostics) != 1 || envelope.Diagnostics[0].Code != "request.too_large" {
			t.Fatal("unexpected capacity response; diagnostics suppressed")
		}
		capacityCode = "request.too_large"
		return
	}
	measure := func(name string, requestBytes int, operation func() bool) {
		stage = name
		for i := 0; i < 3; i++ {
			if !operation() {
				t.Fatalf("baseline warmup rejected: %s; diagnostics suppressed", name)
			}
		}
		m := metric{Name: name, RequestBytes: requestBytes, Milliseconds: make([]float64, 0, 30)}
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		for i := 0; i < 30; i++ {
			start := time.Now()
			ok := operation()
			m.Milliseconds = append(m.Milliseconds, float64(time.Since(start).Nanoseconds())/1e6)
			if !ok {
				t.Fatalf("baseline request rejected: %s; diagnostics suppressed", name)
			}
		}
		runtime.ReadMemStats(&after)
		m.BytesPerOperation = (after.TotalAlloc - before.TotalAlloc) / 30
		metrics = append(metrics, m)
	}
	for _, page := range []string{"bootstrap", "dashboard", "income-statement", "investments", "transactions"} {
		request := app.LocalRequest{WorkspaceRoot: root, Entrypoint: "main.bean", Method: "GET", Path: "/api/ledger/" + page, Canonical: &model, Query: map[string]string{"start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-21", "valuationCurrency": "CNY"}}
		measure("transport/"+page, 0, func() bool { status, _, err := app.DispatchLocalRequest(request); return status == 200 && err == nil })
		// Swift splices the canonical loader JSON, not a Go struct re-encoding.
		encoded, err := json.Marshal(map[string]any{
			"version": 1, "operation": "request", "workspaceRoot": root,
			"entrypoint": "main.bean", "method": "GET", "path": request.Path,
			"query": request.Query, "canonical": json.RawMessage(raw),
		})
		if err != nil {
			t.Fatal("cannot encode fixture request")
		}
		requestJSON := string(encoded)
		measure("json_bridge/"+page, len(encoded), func() bool {
			response := DispatchJSON(requestJSON)
			var header struct {
				OK     bool `json:"ok"`
				Status int  `json:"status"`
			}
			return json.Unmarshal([]byte(response), &header) == nil && header.OK && header.Status == 200
		})
	}
	stage = "completed"
}
