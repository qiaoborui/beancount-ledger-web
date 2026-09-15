package mobilegit

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/transport/client"
	"github.com/go-git/go-git/v5/plumbing/transport/server"
)

func init() {
	// All test pushes use an embedded server backed by temporary bare repos.
	// The normal file transport starts Git processes, so it is never installed.
	client.InstallProtocol("file", guardedTransport{server.NewClient(server.DefaultLoader)})
}

func call(t *testing.T, input request) map[string]any {
	t.Helper()
	result, err := dispatch(context.Background(), input, true)
	if err != nil {
		t.Fatalf("%s failed: %v", input.Operation, err)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

func write(t *testing.T, root, relative, value string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(relative))
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func localCommit(t *testing.T, cache, directory, parent string) string {
	t.Helper()
	return call(t, request{Operation: "commit", StorageRoot: cache, Directory: directory, Parent: parent, Message: "Local test commit", AuthorName: "Fixture", AuthorEmail: "fixture@example.invalid"})["commit"].(string)
}

func fileRemote(path string) string { return (&url.URL{Scheme: "file", Path: path}).String() }
func ptr(value string) *string      { return &value }

func TestTwoIndependentReplicasFetchExportCommitPushAndRemoteRace(t *testing.T) {
	root := t.TempDir()
	remotePath := filepath.Join(root, "remote.git")
	remoteRepository, err := git.PlainInit(remotePath, true)
	if err != nil {
		t.Fatal(err)
	}
	remoteURL := fileRemote(remotePath)
	initial := filepath.Join(root, "initial")
	write(t, initial, "main.bean", "; initial\n")
	write(t, initial, "obsolete.bean", "; remove on replica A\n")
	write(t, initial, ".github/settings.txt", "preserve remote auxiliary files\n")
	seedCache := filepath.Join(root, "seed-cache")
	seed := localCommit(t, seedCache, initial, "")
	base := request{Operation: "push", StorageRoot: seedCache, URL: remoteURL, Branch: "main", Commit: seed, ExpectedRemoteHead: ptr(""), Username: "ephemeral-user", Password: "ephemeral-token-never-persist"}
	call(t, base)
	cacheA, cacheB := filepath.Join(root, "cache-a"), filepath.Join(root, "cache-b")
	for _, cache := range []string{cacheA, cacheB} {
		fetchRequest := base
		fetchRequest.Operation, fetchRequest.StorageRoot = "fetch", cache
		result := call(t, fetchRequest)
		if result["remoteHead"] != seed || result["branchExists"] != true {
			t.Fatalf("unexpected fetch: %v", result)
		}
	}
	candidateA, candidateB := filepath.Join(root, "candidate-a"), filepath.Join(root, "candidate-b")
	call(t, request{Operation: "export", StorageRoot: cacheA, Commit: seed, Directory: candidateA})
	call(t, request{Operation: "export", StorageRoot: cacheB, Commit: seed, Directory: candidateB})
	write(t, candidateA, "main.bean", "; replica A edit\n")
	if err := os.Remove(filepath.Join(candidateA, "obsolete.bean")); err != nil {
		t.Fatal(err)
	}
	commitA := localCommit(t, cacheA, candidateA, seed)
	pushA := base
	pushA.StorageRoot, pushA.Commit, pushA.ExpectedRemoteHead = cacheA, commitA, ptr(seed)
	call(t, pushA)
	write(t, candidateB, "transactions/2026.bean", "; replica B edit\n")
	staleB := localCommit(t, cacheB, candidateB, seed)
	pushB := base
	pushB.StorageRoot, pushB.Commit, pushB.ExpectedRemoteHead = cacheB, staleB, ptr(seed)
	_, err = dispatch(context.Background(), pushB, true)
	assertCode(t, err, "git.remote_changed")
	remoteHead, err := remoteRepository.Reference(plumbing.NewBranchReferenceName("main"), true)
	if err != nil || remoteHead.Hash().String() != commitA {
		t.Fatalf("rejected push changed remote: %v %v", remoteHead, err)
	}
	fetchB := pushB
	fetchB.Operation = "fetch"
	if result := call(t, fetchB); result["remoteHead"] != commitA {
		t.Fatalf("fetch did not see A: %v", result)
	}
	merged := filepath.Join(root, "merged-b")
	call(t, request{Operation: "export", StorageRoot: cacheB, Commit: commitA, Directory: merged})
	write(t, merged, "transactions/2026.bean", "; replica B edit\n")
	commitB := localCommit(t, cacheB, merged, commitA)
	pushB.Commit, pushB.ExpectedRemoteHead = commitB, ptr(commitA)
	call(t, pushB)
	fetchA := pushA
	fetchA.Operation = "fetch"
	if result := call(t, fetchA); result["remoteHead"] != commitB {
		t.Fatalf("A did not see B: %v", result)
	}
	final := filepath.Join(root, "final-a")
	call(t, request{Operation: "export", StorageRoot: cacheA, Commit: commitB, Directory: final})
	for path, expected := range map[string]string{"main.bean": "; replica A edit\n", "transactions/2026.bean": "; replica B edit\n", ".github/settings.txt": "preserve remote auxiliary files\n"} {
		content, err := os.ReadFile(filepath.Join(final, filepath.FromSlash(path)))
		if err != nil || string(content) != expected {
			t.Fatalf("final %s = %q, %v", path, content, err)
		}
	}
	if _, err := os.Stat(filepath.Join(final, "obsolete.bean")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("deleted file returned")
	}
	for _, cache := range []string{seedCache, cacheA, cacheB} {
		repository, err := git.PlainOpen(cache)
		if err != nil {
			t.Fatal(err)
		}
		configuration, err := repository.Config()
		if err != nil {
			t.Fatal(err)
		}
		if len(configuration.Remotes) != 0 {
			t.Fatal("request remote config persisted")
		}
		if err := filepath.WalkDir(cache, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				return nil
			}
			content, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if strings.Contains(string(content), base.Password) || strings.Contains(string(content), base.Username) {
				t.Errorf("credentials persisted in %s", path)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestEmptyBranchExpectedHeadAndNonFastForwardProtection(t *testing.T) {
	root := t.TempDir()
	remotePath := filepath.Join(root, "remote.git")
	if _, err := git.PlainInit(remotePath, true); err != nil {
		t.Fatal(err)
	}
	cache := filepath.Join(root, "cache")
	input := request{Operation: "fetch", StorageRoot: cache, URL: fileRemote(remotePath), Branch: "main"}
	result := call(t, input)
	if result["branchExists"] != false || result["remoteHead"] != "" {
		t.Fatalf("empty branch result: %v", result)
	}
	snapshot := filepath.Join(root, "snapshot")
	write(t, snapshot, "main.bean", "; initial\n")
	first := localCommit(t, cache, snapshot, "")
	input.Operation, input.Commit = "push", first
	_, err := dispatch(context.Background(), input, true)
	assertCode(t, err, "git.invalid_request")
	input.ExpectedRemoteHead = ptr("")
	call(t, input)
	input.ExpectedRemoteHead = ptr("")
	_, err = dispatch(context.Background(), input, true)
	assertCode(t, err, "git.remote_changed")
	write(t, snapshot, "main.bean", "; unrelated history\n")
	unrelated := localCommit(t, cache, snapshot, "")
	input.Commit, input.ExpectedRemoteHead = unrelated, ptr(first)
	_, err = dispatch(context.Background(), input, true)
	assertCode(t, err, "git.non_fast_forward")
}

func TestExportRejectsUnsafeTreesAndExistingCandidates(t *testing.T) {
	for _, test := range []struct {
		name    string
		entries []object.TreeEntry
	}{
		{"symlink", []object.TreeEntry{{Name: "linked", Mode: filemode.Symlink}}},
		{"submodule", []object.TreeEntry{{Name: "module", Mode: filemode.Submodule}}},
		{"dotgit", []object.TreeEntry{{Name: ".git", Mode: filemode.Dir}}},
		{"dotgit-alias", []object.TreeEntry{{Name: ".GIT.", Mode: filemode.Dir}}},
		{"traversal", []object.TreeEntry{{Name: "../escape", Mode: filemode.Regular}}},
		{"case-collision", []object.TreeEntry{{Name: "MAIN.bean", Mode: filemode.Regular}, {Name: "main.bean", Mode: filemode.Regular}}},
		{"unicode-collision", []object.TreeEntry{{Name: "e\u0301.bean", Mode: filemode.Regular}, {Name: "é.bean", Mode: filemode.Regular}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			cache := filepath.Join(root, "cache")
			repository, err := openStorage(cache)
			if err != nil {
				t.Fatal(err)
			}
			blob := repository.Storer.NewEncodedObject()
			blob.SetType(plumbing.BlobObject)
			writer, _ := blob.Writer()
			_, _ = writer.Write([]byte("test"))
			_ = writer.Close()
			blobHash, err := repository.Storer.SetEncodedObject(blob)
			if err != nil {
				t.Fatal(err)
			}
			for index := range test.entries {
				test.entries[index].Hash = blobHash
			}
			hash := rawCommit(t, repository, test.entries)
			candidate := filepath.Join(root, "candidate")
			_, err = dispatch(context.Background(), request{Operation: "export", StorageRoot: cache, Commit: hash, Directory: candidate}, true)
			assertCode(t, err, "git.unsafe_path")
			if _, err := os.Stat(candidate); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("failed export left candidate")
			}
		})
	}
	root := t.TempDir()
	snapshot := filepath.Join(root, "source")
	write(t, snapshot, "main.bean", "; retain\n")
	cache := filepath.Join(root, "cache")
	hash := localCommit(t, cache, snapshot, "")
	_, err := dispatch(context.Background(), request{Operation: "export", StorageRoot: cache, Commit: hash, Directory: snapshot}, true)
	assertCode(t, err, "git.unsafe_path")
	content, _ := os.ReadFile(filepath.Join(snapshot, "main.bean"))
	if string(content) != "; retain\n" {
		t.Fatal("existing candidate overwritten")
	}
}

func rawCommit(t *testing.T, repository *git.Repository, entries []object.TreeEntry) string {
	t.Helper()
	tree := object.Tree{Entries: entries}
	encoded := repository.Storer.NewEncodedObject()
	if err := tree.Encode(encoded); err != nil {
		t.Fatal(err)
	}
	hash, err := repository.Storer.SetEncodedObject(encoded)
	if err != nil {
		t.Fatal(err)
	}
	commit := object.Commit{TreeHash: hash, Author: object.Signature{Name: "Fixture", Email: "fixture@example.invalid", When: time.Now()}, Committer: object.Signature{Name: "Fixture", Email: "fixture@example.invalid", When: time.Now()}, Message: "Fixture\n"}
	encoded = repository.Storer.NewEncodedObject()
	if err := commit.Encode(encoded); err != nil {
		t.Fatal(err)
	}
	hash, err = repository.Storer.SetEncodedObject(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return hash.String()
}

func TestCommitRejectsSymlinksDotGitAndOversizeFiles(t *testing.T) {
	for _, kind := range []string{"symlink", "dotgit", "oversize", "depth"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			source := filepath.Join(root, "source")
			write(t, source, "main.bean", "; test\n")
			want := "git.unsafe_path"
			switch kind {
			case "symlink":
				if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(source, "link")); err != nil {
					t.Fatal(err)
				}
			case "dotgit":
				write(t, source, ".git/config", "sensitive git config")
			case "oversize":
				file, err := os.Create(filepath.Join(source, "large"))
				if err != nil {
					t.Fatal(err)
				}
				if err := file.Truncate(maxFileBytes + 1); err != nil {
					t.Fatal(err)
				}
				_ = file.Close()
				want = "git.limit_exceeded"
			case "depth":
				write(t, source, strings.Repeat("d/", maxDepth)+"nested.bean", "test")
				want = "git.limit_exceeded"
			}
			_, err := dispatch(context.Background(), request{Operation: "commit", StorageRoot: filepath.Join(root, "cache"), Directory: source, Message: "Test"}, true)
			assertCode(t, err, want)
		})
	}
}

func TestPublicAPIHTTPSValidationCancellationTimeoutAndRedaction(t *testing.T) {
	for _, remote := range []string{"http://example.com/repo.git", "ssh://example.com/repo.git", "file:///tmp/fixture", "https://user:token@example.com/repo.git", "https://example.com/repo.git?token=secret"} {
		input := request{Version: 1, Operation: "fetch", StorageRoot: filepath.Join(t.TempDir(), "cache"), URL: remote, Branch: "main"}
		raw, _ := json.Marshal(input)
		var result response
		if err := json.Unmarshal([]byte(DispatchJSON(string(raw))), &result); err != nil {
			t.Fatal(err)
		}
		if result.OK || result.Error == nil || result.Error.Code != "git.invalid_request" {
			t.Fatalf("unsupported URL accepted: %s", remote)
		}
	}
	root, err := privateDirectory(filepath.Join(t.TempDir(), "cache"))
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := lockStorage(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	input := request{Version: 1, Operation: "commit", RequestID: "cancel-fixture", StorageRoot: root, TimeoutSeconds: 30}
	raw, _ := json.Marshal(input)
	finished := make(chan string, 1)
	go func() { finished <- DispatchJSON(string(raw)) }()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if requestCancellations.isActive(input.RequestID) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("request did not register cancellation")
		}
		time.Sleep(time.Millisecond)
	}
	DispatchJSON(`{"version":1,"operation":"cancel","requestID":"cancel-fixture"}`)
	select {
	case raw := <-finished:
		var result response
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if result.Error == nil || result.Error.Code != "git.cancelled" {
			t.Fatalf("cancel result: %s", raw)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not stop operation")
	}
	input.RequestID, input.TimeoutSeconds = "timeout-fixture", 1
	raw, _ = json.Marshal(input)
	var result response
	if err := json.Unmarshal([]byte(DispatchJSON(string(raw))), &result); err != nil {
		t.Fatal(err)
	}
	if result.Error == nil || result.Error.Code != "git.timeout" {
		t.Fatalf("timeout result: %+v", result)
	}
	redacted := encodeFailure(request{Password: "temporary-token", Username: "private-user"}, errors.New("temporary-token private-user"))
	if strings.Contains(redacted, "temporary-token") || strings.Contains(redacted, "private-user") {
		t.Fatal("credentials escaped error response")
	}
}

func assertCode(t *testing.T, err error, code string) {
	t.Helper()
	var detail *bridgeError
	if !errors.As(err, &detail) || detail.Code != code {
		t.Fatalf("expected %s, got %v", code, err)
	}
}
