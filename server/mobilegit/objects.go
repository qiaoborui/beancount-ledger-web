package mobilegit

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
	"golang.org/x/sys/unix"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

const maxEntries = 10000
const maxDepth = 32
const maxFileBytes = 64 << 20
const maxTotalBytes = 256 << 20

type treeBudget struct {
	entries int
	bytes   int64
}

func (b *treeBudget) add(size int64, depth int) error {
	b.entries++
	b.bytes += size
	if depth > maxDepth || b.entries > maxEntries || size < 0 || size > maxFileBytes || b.bytes > maxTotalBytes {
		return fail("limit_exceeded", "Git tree exceeds 10000 entries, 32 levels, 64 MiB per file, or 256 MiB total")
	}
	return nil
}

func parseCommit(raw string, allowEmpty bool) (plumbing.Hash, error) {
	if raw == "" && allowEmpty {
		return plumbing.ZeroHash, nil
	}
	decoded, err := hex.DecodeString(raw)
	if err != nil || len(raw) != 40 || len(decoded) != 20 {
		return plumbing.ZeroHash, fail("invalid_request", "Commit must be a full 40-character Git object ID")
	}
	hash := plumbing.NewHash(raw)
	if hash.IsZero() {
		return hash, fail("invalid_request", "Use an empty string for an absent commit")
	}
	return hash, nil
}

func safeName(name string) (string, error) {
	if name == "" || name == "." || name == ".." || !utf8.ValidString(name) || len(name) > 255 || strings.ContainsAny(name, "/\\:") {
		return "", fail("unsafe_path", "Git tree contains an unsafe path component")
	}
	for _, character := range name {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			return "", fail("unsafe_path", "Git path contains control or format characters")
		}
	}
	canonical := cases.Fold().String(norm.NFC.String(name))
	if strings.TrimRight(canonical, " .") == ".git" {
		return "", fail("unsafe_path", "Git metadata directories are excluded from ledger snapshots")
	}
	return canonical, nil
}

func disjointDirectory(raw, storageRoot string) (string, error) {
	directory, err := privateDirectory(raw)
	if err != nil {
		return "", err
	}
	if pathWithin(directory, storageRoot) || pathWithin(storageRoot, directory) {
		return "", fail("unsafe_path", "Ledger directory and Git cache must be separate")
	}
	return directory, nil
}
func pathWithin(child, parent string) bool {
	relative, err := filepath.Rel(parent, child)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

type exportFile struct {
	path string
	hash plumbing.Hash
	mode filemode.FileMode
	size int64
}

func exportCommit(ctx context.Context, repository *git.Repository, input request) (_ any, err error) {
	hash, err := parseCommit(input.Commit, false)
	if err != nil {
		return nil, err
	}
	commit, err := repository.CommitObject(hash)
	if err != nil {
		return nil, err
	}
	directory, err := disjointDirectory(input.Directory, input.StorageRoot)
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(directory); !errors.Is(err, os.ErrNotExist) {
		return nil, fail("unsafe_path", "Export requires a new candidate directory")
	}
	var files []exportFile
	budget := treeBudget{}
	var collect func(plumbing.Hash, string, int) error
	collect = func(hash plumbing.Hash, prefix string, depth int) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		tree, err := repository.TreeObject(hash)
		if err != nil {
			return err
		}
		names := map[string]bool{}
		for _, entry := range tree.Entries {
			name, err := safeName(entry.Name)
			if err != nil {
				return err
			}
			if names[name] {
				return fail("unsafe_path", "Git paths collide on a case-insensitive or Unicode-normalizing filesystem")
			}
			names[name] = true
			path := filepath.Join(prefix, entry.Name)
			switch entry.Mode {
			case filemode.Dir:
				if err := budget.add(0, depth+1); err != nil {
					return err
				}
				if err := collect(entry.Hash, path, depth+1); err != nil {
					return err
				}
			case filemode.Regular, filemode.Deprecated, filemode.Executable:
				blob, err := repository.BlobObject(entry.Hash)
				if err != nil {
					return err
				}
				if err := budget.add(blob.Size, depth+1); err != nil {
					return err
				}
				files = append(files, exportFile{path: path, hash: entry.Hash, mode: entry.Mode, size: blob.Size})
			default:
				return fail("unsafe_path", "Git symlinks, submodules, and special files are unsupported")
			}
		}
		return nil
	}
	if err := collect(commit.TreeHash, "", 0); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(directory)
		}
	}()
	for _, file := range files {
		if err := writeExportFile(ctx, repository, directory, file); err != nil {
			return nil, err
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return map[string]any{"commit": hash.String(), "directory": directory, "fileCount": len(files)}, nil
}

func writeExportFile(ctx context.Context, repository *git.Repository, root string, file exportFile) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	path := filepath.Join(root, file.path)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if file.mode == filemode.Executable {
		mode = 0o700
	}
	output, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, output.Close()) }()
	blob, err := repository.BlobObject(file.hash)
	if err != nil {
		return err
	}
	reader, err := blob.Reader()
	if err != nil {
		return err
	}
	defer reader.Close()
	written, err := io.Copy(output, io.LimitReader(contextReader{ctx, reader}, file.size+1))
	if err != nil {
		return err
	}
	if written != file.size {
		return fail("failed", "Git blob size changed during export")
	}
	return output.Sync()
}

func createCommit(ctx context.Context, repository *git.Repository, input request) (any, error) {
	parent, err := parseCommit(input.Parent, true)
	if err != nil {
		return nil, err
	}
	if !parent.IsZero() {
		if _, err := repository.CommitObject(parent); err != nil {
			return nil, err
		}
	}
	directory, err := disjointDirectory(input.Directory, input.StorageRoot)
	if err != nil {
		return nil, err
	}
	if info, err := os.Lstat(directory); err != nil || !info.IsDir() {
		return nil, fail("unsafe_path", "Commit requires an existing snapshot directory")
	}
	message := strings.TrimSpace(input.Message)
	if message == "" || len(message) > 4096 || strings.ContainsRune(message, '\x00') {
		return nil, fail("invalid_request", "Commit message must contain 1–4096 bytes")
	}
	name, email := input.AuthorName, input.AuthorEmail
	if name == "" {
		name = "Local Ledger"
	}
	if email == "" {
		email = "local-ledger@device.invalid"
	}
	if len(name) > 200 || len(email) > 254 || strings.ContainsAny(name+email, "\r\n\x00<>") || !strings.Contains(email, "@") {
		return nil, fail("invalid_request", "Invalid local commit author")
	}
	budget := treeBudget{}
	tree, err := commitDirectory(ctx, repository, directory, 0, &budget)
	if err != nil {
		return nil, err
	}
	signature := object.Signature{Name: name, Email: email, When: time.Now().UTC()}
	commit := &object.Commit{Author: signature, Committer: signature, Message: message + "\n", TreeHash: tree}
	if !parent.IsZero() {
		commit.ParentHashes = []plumbing.Hash{parent}
	}
	encoded := repository.Storer.NewEncodedObject()
	if err := commit.Encode(encoded); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	hash, err := repository.Storer.SetEncodedObject(encoded)
	if err != nil {
		return nil, err
	}
	if err := repository.Storer.SetReference(plumbing.NewHashReference("refs/heads/mobilegit-local", hash)); err != nil {
		return nil, err
	}
	return map[string]string{"commit": hash.String(), "parent": input.Parent}, nil
}

func commitDirectory(ctx context.Context, repository *git.Repository, directory string, depth int, budget *treeBudget) (plumbing.Hash, error) {
	if err := ctx.Err(); err != nil {
		return plumbing.ZeroHash, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return plumbing.ZeroHash, err
	}
	tree := object.Tree{}
	names := map[string]bool{}
	for _, entry := range entries {
		name, err := safeName(entry.Name())
		if err != nil {
			return plumbing.ZeroHash, err
		}
		if names[name] {
			return plumbing.ZeroHash, fail("unsafe_path", "Snapshot paths collide on a case-insensitive or Unicode-normalizing filesystem")
		}
		names[name] = true
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			return plumbing.ZeroHash, err
		}
		item := object.TreeEntry{Name: entry.Name()}
		if info.IsDir() {
			if err := budget.add(0, depth+1); err != nil {
				return plumbing.ZeroHash, err
			}
			item.Mode = filemode.Dir
			item.Hash, err = commitDirectory(ctx, repository, path, depth+1, budget)
		} else if info.Mode().IsRegular() {
			if err := budget.add(info.Size(), depth+1); err != nil {
				return plumbing.ZeroHash, err
			}
			item.Mode = filemode.Regular
			if info.Mode().Perm()&0o111 != 0 {
				item.Mode = filemode.Executable
			}
			item.Hash, err = commitFile(ctx, repository, path, info.Size())
		} else {
			return plumbing.ZeroHash, fail("unsafe_path", "Snapshot contains a symlink or special file")
		}
		if err != nil {
			return plumbing.ZeroHash, err
		}
		tree.Entries = append(tree.Entries, item)
	}
	sort.Sort(object.TreeEntrySorter(tree.Entries))
	encoded := repository.Storer.NewEncodedObject()
	if err := tree.Encode(encoded); err != nil {
		return plumbing.ZeroHash, err
	}
	return repository.Storer.SetEncodedObject(encoded)
}

func commitFile(ctx context.Context, repository *git.Repository, path string, size int64) (_ plumbing.Hash, err error) {
	file, err := os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return plumbing.ZeroHash, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return plumbing.ZeroHash, fail("unsafe_path", "Snapshot file changed during commit")
	}
	encoded := repository.Storer.NewEncodedObject()
	encoded.SetType(plumbing.BlobObject)
	writer, err := encoded.Writer()
	if err != nil {
		return plumbing.ZeroHash, err
	}
	written, copyErr := io.Copy(writer, io.LimitReader(contextReader{ctx, file}, size+1))
	closeErr := writer.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		return plumbing.ZeroHash, err
	}
	if written != size {
		return plumbing.ZeroHash, fail("unsafe_path", "Snapshot file changed during commit")
	}
	if err := ctx.Err(); err != nil {
		return plumbing.ZeroHash, err
	}
	return repository.Storer.SetEncodedObject(encoded)
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
