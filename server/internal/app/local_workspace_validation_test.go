package app

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestLocalConfigDuringConcurrentSyncCleanup(t *testing.T) {
	input := localTestRequest(t)
	input.Path = "/api/ledger/summary"
	candidate := filepath.Join(filepath.Dir(input.RuntimeRoot), "sync", "candidate")
	started, stop, finished := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		close(started)
		for {
			select {
			case <-stop:
				finished <- nil
				return
			default:
			}
			if err := os.MkdirAll(filepath.Join(candidate, "nested", "objects"), 0o700); err != nil {
				finished <- err
				return
			}
			if err := os.RemoveAll(candidate); err != nil {
				finished <- err
				return
			}
		}
	}()
	<-started
	defer func() {
		close(stop)
		if err := <-finished; err != nil {
			t.Fatal(err)
		}
	}()
	for i := 0; i < 30; i++ {
		localTestDispatch(t, input)
	}
}

func TestLocalConfigIgnoresUnselectedStorage(t *testing.T) {
	// A sync candidate and historical generations can be changing while an
	// immutable selected generation serves requests. An invalid sentinel makes
	// any accidental traversal of unrelated storage fail deterministically.
	for _, relative := range []string{"sync/candidates/fetch", "generations/old/workspace", "staging/other/workspace", "git/objects"} {
		t.Run(relative, func(t *testing.T) {
			input := localTestRequest(t)
			ledger := filepath.Dir(input.RuntimeRoot)
			directory := filepath.Join(ledger, relative)
			if err := os.MkdirAll(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(t.TempDir(), filepath.Join(directory, "unrelated-link")); err != nil {
				t.Fatal(err)
			}
			input.Path = "/api/ledger/summary"
			localTestDispatch(t, input)
		})
	}
}

func TestLocalConfigRejectsManagedAncestorSymlinks(t *testing.T) {
	for _, component := range []string{"ledger", "container", "generation", "workspace", "runtime", "runtime-file", "staged-runtime"} {
		t.Run(component, func(t *testing.T) {
			input := localTestRequest(t)
			if component == "staged-runtime" {
				stage := filepath.Join(filepath.Dir(input.RuntimeRoot), "staging", "proposal", "workspace")
				if err := os.CopyFS(stage, os.DirFS(input.WorkspaceRoot)); err != nil {
					t.Fatal(err)
				}
				input.WorkspaceRoot, input.Staging = stage, true
			}
			paths := map[string]string{
				"ledger":         filepath.Dir(input.RuntimeRoot),
				"container":      filepath.Dir(filepath.Dir(input.WorkspaceRoot)),
				"generation":     filepath.Dir(input.WorkspaceRoot),
				"workspace":      input.WorkspaceRoot,
				"runtime":        input.RuntimeRoot,
				"runtime-file":   filepath.Join(input.RuntimeRoot, "notifications.json"),
				"staged-runtime": filepath.Join(filepath.Dir(input.WorkspaceRoot), "runtime"),
			}
			path := paths[component]
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(t.TempDir(), "target")
			if _, err := os.Lstat(path); err == nil {
				if err := os.Rename(path, target); err != nil {
					t.Fatal(err)
				}
			} else if err := os.MkdirAll(target, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
			if _, err := localConfig(input); err == nil {
				t.Fatalf("accepted symlink at %s", component)
			}
		})
	}
}

func TestLocalConfigRuntimeOwnershipAndMissingWorkspace(t *testing.T) {
	input := localTestRequest(t)
	input.RuntimeRoot = t.TempDir()
	if _, err := localConfig(input); err == nil {
		t.Fatal("accepted runtime owned by another ledger")
	}
	input.RuntimeRoot = ""
	input.WorkspaceRoot = filepath.Join(filepath.Dir(filepath.Dir(input.WorkspaceRoot)), "missing", "workspace")
	if _, err := localConfig(input); err == nil {
		t.Fatal("accepted missing selected workspace")
	}
}

func TestLocalTreeMissingRuntimeAndWorkspace(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "removed-preview")
	if err := scanLocalTree(missing, true); err != nil {
		t.Fatalf("runtime cleanup must tolerate missing entries: %v", err)
	}
	if err := rejectLocalSymlinks(missing); err == nil {
		t.Fatal("immutable workspace must remain present")
	}
}

func TestLocalConfigRejectsNonregularWorkspaceAndRuntimeFiles(t *testing.T) {
	for _, inRuntime := range []bool{false, true} {
		t.Run(map[bool]string{false: "workspace", true: "runtime"}[inRuntime], func(t *testing.T) {
			input := localTestRequest(t)
			directory := input.WorkspaceRoot
			if inRuntime {
				directory = input.RuntimeRoot
			}
			if err := os.MkdirAll(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(filepath.Join(directory, "fifo"), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := localConfig(input); err == nil {
				t.Fatal("accepted nonregular file")
			}
		})
	}
}
