package mobileagent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/MichaelKinsy/PiG/ai"
)

// fakeLinux stands in for the shell's runner: it runs a tiny Go function
// against the workspace instead of a guest.
type fakeLinux struct {
	mu        sync.Mutex
	requests  []linuxRunRequest
	cancelled []string
	act       func(request linuxRunRequest) linuxRunResult
	block     chan struct{}
}

func (f *fakeLinux) Run(requestJSON string) string {
	var request linuxRunRequest
	_ = json.Unmarshal([]byte(requestJSON), &request)
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	if f.block != nil {
		<-f.block
		return `{"exitCode":137,"cancelled":true}`
	}
	encoded, _ := json.Marshal(f.act(request))
	return string(encoded)
}

func (f *fakeLinux) Cancel(id string) {
	f.mu.Lock()
	f.cancelled = append(f.cancelled, id)
	block := f.block
	f.mu.Unlock()
	if block != nil {
		close(block)
	}
}

func TestBashIsOfferedOnlyWithARunner(t *testing.T) {
	dir := scratchCopy(t)
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	for _, tool := range files.tools() {
		if tool.Name() == "bash" {
			t.Fatal("bash offered without a runner")
		}
	}
	SetLinuxRunner(&fakeLinux{})
	t.Cleanup(func() { SetLinuxRunner(nil) })
	tools := files.tools()
	if last := tools[len(tools)-1]; last.Name() != "bash" {
		t.Fatalf("last tool = %s, want bash", last.Name())
	}
}

func TestBashRunsInTheDraftAndReportsChanges(t *testing.T) {
	runner := &fakeLinux{act: func(request linuxRunRequest) linuxRunResult {
		// What a guest command might do: edit a ledger file, and leave a
		// link that points out of the draft.
		data, _ := os.ReadFile(filepath.Join(request.Workspace, "main.bean"))
		_ = os.WriteFile(filepath.Join(request.Workspace, "main.bean"), append(data, []byte("; touched\n")...), 0o600)
		_ = os.Symlink("/etc/passwd", filepath.Join(request.Workspace, "passwd.bean"))
		return linuxRunResult{ExitCode: 0, Output: "ok\n", OutputBytes: 3}
	}}
	SetLinuxRunner(runner)
	t.Cleanup(func() { SetLinuxRunner(nil) })
	committed, dir := committedWorkspace(t), scratchCopy(t)
	var output string
	useFaux(t,
		toolStep("bash", map[string]any{"command": "echo '; touched' >> main.bean", "timeout_seconds": 9999}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			output = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好了")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committed, "scratchRoot": dir,
		"provider": "faux", "model": "faux-1", "message": "跑一下"})
	if !response.OK || !response.Edited || len(response.ToolCalls) != 1 || response.ToolCalls[0].IsError {
		t.Fatalf("unexpected response: %+v (%s)", response, output)
	}
	if len(runner.requests) != 1 {
		t.Fatalf("requests = %+v", runner.requests)
	}
	request := runner.requests[0]
	if request.Workspace != dir || request.TimeoutSeconds != maxBashTimeout || request.MaxOutputBytes != maxBashOutput || request.ID == "" {
		t.Fatalf("request = %+v", request)
	}
	if !strings.Contains(output, `"changed_files":["main.bean"]`) || !strings.Contains(output, `"removed_links":["passwd.bean"]`) ||
		!strings.Contains(output, `"exit_code":0`) {
		t.Fatalf("output = %s", output)
	}
	if _, err := os.Lstat(filepath.Join(dir, "passwd.bean")); !os.IsNotExist(err) {
		t.Fatal("the link was left in the draft")
	}
}

func TestBashErrorAndTimeoutReachTheModel(t *testing.T) {
	dir := scratchCopy(t)
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	runner := &fakeLinux{act: func(linuxRunRequest) linuxRunResult {
		return linuxRunResult{ExitCode: 137, TimedOut: true, Output: "partial", OutputBytes: 99_999, Truncated: true}
	}}
	out, err := files.bash(context.Background(), runner, json.RawMessage(`{"command":"sleep 999","timeout_seconds":1}`))
	if err != nil {
		t.Fatal(err)
	}
	result := out.(map[string]any)
	if result["timed_out"] != true || !strings.Contains(result["note"].(string), "1 秒") {
		t.Fatalf("result = %+v", result)
	}
	if files.wasEdited() {
		t.Fatal("an untouched draft was marked edited")
	}
	runner.act = func(linuxRunRequest) linuxRunResult { return linuxRunResult{Error: "内置 Linux 还没有安装"} }
	if _, err := files.bash(context.Background(), runner, json.RawMessage(`{"command":"true"}`)); err == nil || !strings.Contains(err.Error(), "没有安装") {
		t.Fatalf("err = %v", err)
	}
	if _, err := files.bash(context.Background(), runner, json.RawMessage(`{"command":"  "}`)); err == nil {
		t.Fatal("an empty command was run")
	}
}

func TestBashCancelsTheRunWhenTheTurnStops(t *testing.T) {
	dir := scratchCopy(t)
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	runner := &fakeLinux{block: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	if _, err := files.bash(ctx, runner, json.RawMessage(`{"command":"sleep 100"}`)); err != context.Canceled {
		t.Fatalf("err = %v", err)
	}
	if len(runner.cancelled) != 1 || runner.cancelled[0] != runner.requests[0].ID {
		t.Fatalf("cancelled = %v, requests = %+v", runner.cancelled, runner.requests)
	}
}

func writeTarGz(t *testing.T, entries []tar.Header, contents map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, header := range entries {
		body := contents[header.Name]
		header.Size = int64(len(body))
		if header.Typeflag != tar.TypeReg {
			header.Size = 0
		}
		if err := tw.WriteHeader(&header); err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg {
			if _, err := tw.Write([]byte(body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(t.TempDir(), "rootfs.tar.gz")
	if err := os.WriteFile(archive, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	return archive
}

func TestExtractRootfsKeepsLinksAndModes(t *testing.T) {
	archive := writeTarGz(t, []tar.Header{
		{Name: "./", Typeflag: tar.TypeDir, Mode: 0o755},
		{Name: "./bin/", Typeflag: tar.TypeDir, Mode: 0o755},
		{Name: "./bin/busybox", Typeflag: tar.TypeReg, Mode: 0o4755},
		{Name: "./bin/sh", Typeflag: tar.TypeSymlink, Linkname: "/bin/busybox"},
		{Name: "./etc/alpine-release", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: "./etc/release", Typeflag: tar.TypeLink, Linkname: "./etc/alpine-release"},
		{Name: "./dev/null", Typeflag: tar.TypeChar, Mode: 0o666},
		{Name: "./root/", Typeflag: tar.TypeDir, Mode: 0o700},
	}, map[string]string{"./bin/busybox": "ELF", "./etc/alpine-release": "3.22.8\n"})
	destination := filepath.Join(t.TempDir(), "alpine")
	if message := ExtractRootfsJSON(`{"archive":` + quote(archive) + `,"destination":` + quote(destination) + `}`); message != "" {
		t.Fatal(message)
	}
	info, err := os.Stat(filepath.Join(destination, "bin", "busybox"))
	if err != nil || info.Mode()&os.ModeSetuid != 0 || info.Mode().Perm() != 0o755 {
		t.Fatalf("busybox = %v %v", info, err)
	}
	if target, err := os.Readlink(filepath.Join(destination, "bin", "sh")); err != nil || target != "/bin/busybox" {
		t.Fatalf("sh -> %q %v", target, err)
	}
	if data, err := os.ReadFile(filepath.Join(destination, "etc", "release")); err != nil || string(data) != "3.22.8\n" {
		t.Fatalf("hard link = %q %v", data, err)
	}
	if _, err := os.Lstat(filepath.Join(destination, "dev", "null")); !os.IsNotExist(err) {
		t.Fatal("a device node was created")
	}
	if message := ExtractRootfsJSON(`{"archive":` + quote(archive) + `,"destination":` + quote(destination) + `}`); !strings.Contains(message, "already exists") {
		t.Fatalf("second extraction = %q", message)
	}
}

func TestExtractRootfsRefusesPathsOutsideTheRoot(t *testing.T) {
	for _, header := range []tar.Header{
		{Name: "../escape", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: "a/../../escape", Typeflag: tar.TypeReg, Mode: 0o644},
		{Name: "link", Typeflag: tar.TypeLink, Linkname: "../../etc/passwd"},
	} {
		archive := writeTarGz(t, []tar.Header{header}, map[string]string{})
		destination := filepath.Join(t.TempDir(), "alpine")
		if message := ExtractRootfsJSON(`{"archive":` + quote(archive) + `,"destination":` + quote(destination) + `}`); !strings.Contains(message, "unsafe") {
			t.Fatalf("%s: %q", header.Name, message)
		}
	}
	// A symlink's target is the guest's business: kept, never followed.
	archive := writeTarGz(t, []tar.Header{{Name: "etc/passwd", Typeflag: tar.TypeSymlink, Linkname: "../../../etc/passwd"},
		{Name: "etc/passwd", Typeflag: tar.TypeReg, Mode: 0o644}}, map[string]string{"etc/passwd": "root:x:0:0\n"})
	destination := filepath.Join(t.TempDir(), "alpine")
	outside := filepath.Join(filepath.Dir(destination), "etc")
	if message := ExtractRootfsJSON(`{"archive":` + quote(archive) + `,"destination":` + quote(destination) + `}`); message == "" {
		// Writing a regular file over a symlink must not go through it.
		if _, err := os.Stat(outside); err == nil {
			t.Fatal("a write followed a symlink out of the root")
		}
	}
}

func quote(s string) string {
	encoded, _ := json.Marshal(s)
	return string(encoded)
}
