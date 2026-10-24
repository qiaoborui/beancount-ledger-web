package app

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// BenchmarkLocalScaleStages measures the Go half of one large-ledger write:
// source-version hashing, canonical stream ingest, model registration and the
// first page (which builds the read cache/snapshot). It is opt-in and needs a
// tier prepared by the synthetic generator:
//
//	python3 scripts/large_ledger_bench.py bench --tiers 10k --no-go
//	LOCAL_LEDGER_SCALE_BENCHMARK=1 \
//	LOCAL_LEDGER_SCALE_DIR=/tmp/blw-large-ledger-XXXX/10k \
//	go test ./internal/app -run '^$' -bench '^BenchmarkLocalScaleStages$' -benchtime=1x -v
//
// The tier directory must contain "generations/bench/workspace" (the Beancount
// source) and "runtime/canonical-stream/<32 hex>.records" (the Python export).
// LOCAL_LEDGER_SCALE_RESULT optionally names a JSON file for the stage report.
// Normal `go test ./...` compiles this file but never runs it.
type localScaleStage struct {
	Name string  `json:"name"`
	MS   float64 `json:"ms"`
}

type localScaleResult struct {
	Entries         int               `json:"entries"`
	StreamBytes     int64             `json:"streamBytes"`
	SourceFiles     int               `json:"sourceFiles"`
	Stages          []localScaleStage `json:"stages"`
	HeapAllocBytes  uint64            `json:"heapAllocBytes"`
	TotalAllocBytes uint64            `json:"totalAllocBytes"`
}

func BenchmarkLocalScaleStages(b *testing.B) {
	if os.Getenv("LOCAL_LEDGER_SCALE_BENCHMARK") != "1" {
		b.Skip("opt-in large-ledger benchmark: set LOCAL_LEDGER_SCALE_BENCHMARK=1 and LOCAL_LEDGER_SCALE_DIR")
	}
	directory := os.Getenv("LOCAL_LEDGER_SCALE_DIR")
	if directory == "" {
		b.Fatal("LOCAL_LEDGER_SCALE_DIR must point at a tier prepared by scripts/large_ledger_bench.py")
	}
	root := filepath.Join(directory, "generations", "bench", "workspace")
	runtimeDir := filepath.Join(directory, "runtime")
	streamDir := filepath.Join(runtimeDir, "canonical-stream")
	streamName, streamBytes, err := localScaleStream(streamDir)
	if err != nil {
		b.Fatal(err)
	}
	input := LocalRequest{WorkspaceRoot: root, RuntimeRoot: runtimeDir, Entrypoint: "main.bean", Method: "GET"}
	var last localScaleResult
	for iteration := 0; iteration < b.N; iteration++ {
		last = measureLocalScaleStages(b, input, streamDir, streamName, streamBytes)
	}
	if path := os.Getenv("LOCAL_LEDGER_SCALE_RESULT"); path != "" {
		encoded, err := json.MarshalIndent(last, "", "  ")
		if err != nil {
			b.Fatal(err)
		}
		if err := os.WriteFile(path, encoded, 0600); err != nil {
			b.Fatal(err)
		}
	}
}

func localScaleStream(directory string) (string, int64, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return "", 0, fmt.Errorf("read canonical stream directory: %w", err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".records") || len(name) != 40 {
			continue
		}
		if info, err := entry.Info(); err == nil {
			return name, info.Size(), nil
		}
	}
	return "", 0, fmt.Errorf("no 32-hex .records canonical stream in %s", directory)
}

func measureLocalScaleStages(b *testing.B, input LocalRequest, streamDir, streamName string, streamBytes int64) localScaleResult {
	b.Helper()
	result := localScaleResult{StreamBytes: streamBytes}
	stages := make([]localScaleStage, 0, 5)
	measure := func(name string, call func() error) {
		started := time.Now()
		if err := call(); err != nil {
			b.Fatalf("%s: %v", name, err)
		}
		elapsed := time.Since(started)
		stages = append(stages, localScaleStage{Name: name, MS: float64(elapsed.Microseconds()) / 1000.0})
		b.Logf("%-26s %8.1f ms", name, float64(elapsed.Microseconds())/1000.0)
	}
	var version string
	measure("source version", func() error {
		value, err := LocalModelSourceVersion(input)
		version = value
		return err
	})
	measure("canonical stream ingest", func() error {
		stream, err := os.Open(filepath.Join(streamDir, streamName))
		if err != nil {
			return err
		}
		defer stream.Close()
		model, err := ReadLocalCanonicalStream(stream)
		if err != nil {
			return err
		}
		result.Entries = len(model.Entries)
		return nil
	})
	result.SourceFiles = localScaleSourceFiles(b, input.WorkspaceRoot)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	var handle string
	measure("model register", func() error {
		value, err := RegisterLocalModel(input, streamName, version)
		handle = value
		return err
	})
	request := input
	request.ModelHandle = handle
	request.Path = "/api/ledger/transactions"
	request.Query = map[string]string{"limit": "50"}
	measure("first page (snapshot)", func() error {
		status, body, err := DispatchLocalRequest(request)
		if status != 200 || err != nil {
			return fmt.Errorf("status=%d err=%v body=%s", status, err, body)
		}
		return nil
	})
	measure("warm page", func() error {
		status, body, err := DispatchLocalRequest(request)
		if status != 200 || err != nil {
			return fmt.Errorf("status=%d err=%v body=%s", status, err, body)
		}
		return nil
	})
	runtime.GC()
	runtime.ReadMemStats(&after)
	if handle != "" {
		ReleaseLocalModel(handle)
	}
	result.Stages = stages
	result.HeapAllocBytes = after.HeapAlloc
	result.TotalAllocBytes = after.TotalAlloc - before.TotalAlloc
	b.Logf("entries=%d live_heap=%d total_alloc=%d", result.Entries, result.HeapAllocBytes, result.TotalAllocBytes)
	return result
}

func localScaleSourceFiles(b *testing.B, root string) int {
	b.Helper()
	files := 0
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".bean") {
			files++
		}
		return nil
	})
	if err != nil {
		b.Fatal(err)
	}
	return files
}
