package app

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/google/go-github/v74/github"
)

type githubLedgerClient struct {
	cfg    Config
	client *github.Client
	owner  string
	repo   string
	branch string
}

type githubLedgerTransaction struct {
	ctx           context.Context
	ledger        *githubLedgerClient
	baseCommitSHA string
	baseTreeSHA   string
	cache         map[string]fileSnapshot
	writes        map[string][]byte
}

type fileInfo struct {
	name    string
	size    int64
	modTime time.Time
}

func (i fileInfo) Name() string       { return i.name }
func (i fileInfo) Size() int64        { return i.size }
func (i fileInfo) Mode() os.FileMode  { return 0o644 }
func (i fileInfo) ModTime() time.Time { return i.modTime }
func (i fileInfo) IsDir() bool        { return false }
func (i fileInfo) Sys() any           { return nil }

func githubAPIEnabled(cfg Config) bool {
	return strings.EqualFold(cfg.LedgerStorage, "github_api")
}

func newGitHubLedgerClient(cfg Config) (*githubLedgerClient, error) {
	owner, repo := strings.TrimSpace(cfg.LedgerGitHubOwner), strings.TrimSpace(cfg.LedgerGitHubRepo)
	if owner == "" || repo == "" {
		return nil, errors.New("LEDGER_GITHUB_OWNER and LEDGER_GITHUB_REPO are required when LEDGER_STORAGE=github_api")
	}
	if strings.TrimSpace(cfg.LedgerGitHubToken) == "" {
		return nil, errors.New("LEDGER_GITHUB_TOKEN is required when LEDGER_STORAGE=github_api")
	}
	branch := strings.TrimSpace(cfg.LedgerGitBranch)
	if branch == "" {
		branch = "main"
	}
	client := github.NewClient(nil)
	if cfg.LedgerGitHubAPIURL != "" {
		baseURL, err := url.Parse(strings.TrimRight(cfg.LedgerGitHubAPIURL, "/") + "/")
		if err != nil {
			return nil, fmt.Errorf("invalid LEDGER_GITHUB_API_URL: %w", err)
		}
		client.BaseURL = baseURL
	}
	if cfg.LedgerGitHubToken != "" {
		client = client.WithAuthToken(cfg.LedgerGitHubToken)
	}
	return &githubLedgerClient{cfg: cfg, client: client, owner: owner, repo: strings.TrimSuffix(repo, ".git"), branch: branch}, nil
}

func (c *githubLedgerClient) beginTransaction(ctx context.Context) (*githubLedgerTransaction, error) {
	ref, _, err := c.client.Git.GetRef(ctx, c.owner, c.repo, "heads/"+c.branch)
	if err != nil {
		return nil, err
	}
	baseSHA := ref.GetObject().GetSHA()
	if baseSHA == "" {
		return nil, errors.New("github branch ref has no commit SHA")
	}
	commit, _, err := c.client.Git.GetCommit(ctx, c.owner, c.repo, baseSHA)
	if err != nil {
		return nil, err
	}
	treeSHA := commit.GetTree().GetSHA()
	if treeSHA == "" {
		return nil, errors.New("github branch commit has no tree SHA")
	}
	return &githubLedgerTransaction{
		ctx:           ctx,
		ledger:        c,
		baseCommitSHA: baseSHA,
		baseTreeSHA:   treeSHA,
		cache:         map[string]fileSnapshot{},
		writes:        map[string][]byte{},
	}, nil
}

func (c *githubLedgerClient) listEditorFiles(ctx context.Context) ([]LedgerEditorFile, error) {
	tx, err := c.beginTransaction(ctx)
	if err != nil {
		return nil, err
	}
	tree, _, err := c.client.Git.GetTree(ctx, c.owner, c.repo, tx.baseTreeSHA, true)
	if err != nil {
		return nil, err
	}
	if tree.GetTruncated() {
		return nil, errors.New("github tree is too large to list editable ledger files")
	}
	files := []LedgerEditorFile{}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, entry := range tree.Entries {
		if entry.GetType() != "blob" {
			continue
		}
		rel := entry.GetPath()
		if !isLedgerEditorPathAllowed(rel) || entry.GetSize() > ledgerEditorMaxFileBytes {
			continue
		}
		files = append(files, LedgerEditorFile{Path: rel, Name: filepath.Base(rel), Dir: filepath.ToSlash(filepath.Dir(rel)), Size: int64(entry.GetSize()), ModTime: now})
	}
	sort.Slice(files, func(i, j int) bool {
		return editorFileSortKey(files[i].Path) < editorFileSortKey(files[j].Path)
	})
	return files, nil
}

func (c *githubLedgerClient) readEditorFile(ctx context.Context, rel string) (string, fileInfo, string, error) {
	tx, err := c.beginTransaction(ctx)
	if err != nil {
		return "", fileInfo{}, "", err
	}
	content, err := tx.readFile(filepath.Join(c.cfg.LedgerRoot, filepath.FromSlash(rel)))
	if err != nil {
		return "", fileInfo{}, "", err
	}
	if len(content) > ledgerEditorMaxFileBytes {
		return "", fileInfo{}, "", fmt.Errorf("file is too large, max %d bytes", ledgerEditorMaxFileBytes)
	}
	hash := sha256Hex(content)[:16]
	info := fileInfo{name: filepath.Base(rel), size: int64(len(content)), modTime: time.Now().UTC()}
	return string(content), info, hash, nil
}

func (c *githubLedgerClient) listImportDocuments(ctx context.Context) ([]ImportDocument, error) {
	tx, err := c.beginTransaction(ctx)
	if err != nil {
		return nil, err
	}
	tree, _, err := c.client.Git.GetTree(ctx, c.owner, c.repo, tx.baseTreeSHA, true)
	if err != nil {
		return nil, err
	}
	if tree.GetTruncated() {
		return nil, errors.New("github tree is too large to list import documents")
	}
	documents := []ImportDocument{}
	now := time.Now().UTC()
	for _, entry := range tree.Entries {
		if entry.GetType() != "blob" {
			continue
		}
		path := entry.GetPath()
		parts := strings.Split(path, "/")
		if len(parts) != 5 || parts[0] != "transactions" || parts[2] != "documents" || parts[3] != "imports" {
			continue
		}
		if len(parts[1]) != 4 {
			continue
		}
		documents = append(documents, importDocumentInfo(path, parts[1], parts[4], int64(entry.GetSize()), now))
	}
	sort.Slice(documents, func(i, j int) bool {
		if documents[i].ModTime == documents[j].ModTime {
			return documents[i].Path > documents[j].Path
		}
		return documents[i].ModTime > documents[j].ModTime
	})
	return documents, nil
}

func (c *githubLedgerClient) readLedgerFile(ctx context.Context, rel string) ([]byte, error) {
	tx, err := c.beginTransaction(ctx)
	if err != nil {
		return nil, err
	}
	return tx.readFile(filepath.Join(c.cfg.LedgerRoot, filepath.FromSlash(rel)))
}

func (tx *githubLedgerTransaction) readFile(file string) ([]byte, error) {
	rel, err := tx.relPath(file)
	if err != nil {
		return nil, err
	}
	if content, ok := tx.writes[rel]; ok {
		return append([]byte(nil), content...), nil
	}
	if snap, ok := tx.cache[rel]; ok {
		if !snap.existed {
			return nil, os.ErrNotExist
		}
		return append([]byte(nil), snap.content...), nil
	}
	content, err := tx.readBaseFile(rel)
	if err != nil {
		return nil, err
	}
	tx.cache[rel] = fileSnapshot{existed: true, content: append([]byte(nil), content...)}
	return content, nil
}

func (tx *githubLedgerTransaction) readBaseFile(rel string) ([]byte, error) {
	fileContent, _, _, err := tx.ledger.client.Repositories.GetContents(tx.ctx, tx.ledger.owner, tx.ledger.repo, rel, &github.RepositoryContentGetOptions{Ref: tx.baseCommitSHA})
	if err != nil {
		if isGitHubNotFound(err) {
			return nil, os.ErrNotExist
		}
		return nil, err
	}
	if fileContent == nil || fileContent.GetType() != "file" {
		return nil, os.ErrNotExist
	}
	text, err := fileContent.GetContent()
	if err != nil {
		return nil, err
	}
	return []byte(text), nil
}

func (tx *githubLedgerTransaction) snapshot(file string) error {
	rel, err := tx.relPath(file)
	if err != nil {
		return err
	}
	if _, ok := tx.cache[rel]; ok {
		return nil
	}
	content, err := tx.readBaseFile(rel)
	if errors.Is(err, os.ErrNotExist) {
		tx.cache[rel] = fileSnapshot{existed: false}
		return nil
	}
	if err != nil {
		return err
	}
	tx.cache[rel] = fileSnapshot{existed: true, content: append([]byte(nil), content...)}
	return nil
}

func (tx *githubLedgerTransaction) writeFile(file string, content []byte) error {
	rel, err := tx.relPath(file)
	if err != nil {
		return err
	}
	tx.writes[rel] = append([]byte(nil), content...)
	return nil
}

func (tx *githubLedgerTransaction) exists(file string) (bool, error) {
	_, err := tx.readFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func (tx *githubLedgerTransaction) uniquePath(file string) (string, error) {
	if exists, err := tx.exists(file); err != nil {
		return "", err
	} else if !exists {
		return file, nil
	}
	ext := filepath.Ext(file)
	base := strings.TrimSuffix(file, ext)
	for i := 2; i < 1000; i++ {
		candidate := fmt.Sprintf("%s-%d%s", base, i, ext)
		exists, err := tx.exists(candidate)
		if err != nil {
			return "", err
		}
		if !exists {
			return candidate, nil
		}
	}
	return file, nil
}

func (tx *githubLedgerTransaction) commit(message string) (string, error) {
	if len(tx.writes) == 0 {
		return "No ledger changes to commit.", nil
	}
	paths := make([]string, 0, len(tx.writes))
	for path := range tx.writes {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	entries := make([]*github.TreeEntry, 0, len(paths))
	for _, path := range paths {
		content := base64.StdEncoding.EncodeToString(tx.writes[path])
		encoding := "base64"
		blob, _, err := tx.ledger.client.Git.CreateBlob(tx.ctx, tx.ledger.owner, tx.ledger.repo, &github.Blob{Content: &content, Encoding: &encoding})
		if err != nil {
			return "", err
		}
		mode, typ := "100644", "blob"
		sha := blob.GetSHA()
		entries = append(entries, &github.TreeEntry{Path: &path, Mode: &mode, Type: &typ, SHA: &sha})
	}
	tree, _, err := tx.ledger.client.Git.CreateTree(tx.ctx, tx.ledger.owner, tx.ledger.repo, tx.baseTreeSHA, entries)
	if err != nil {
		return "", err
	}
	author := githubCommitAuthor()
	commit := &github.Commit{
		Message: &message,
		Tree:    &github.Tree{SHA: tree.SHA},
		Parents: []*github.Commit{{SHA: &tx.baseCommitSHA}},
	}
	if author != nil {
		commit.Author = author
		commit.Committer = author
	}
	created, _, err := tx.ledger.client.Git.CreateCommit(tx.ctx, tx.ledger.owner, tx.ledger.repo, commit, nil)
	if err != nil {
		return "", err
	}
	refName := "refs/heads/" + tx.ledger.branch
	_, _, err = tx.ledger.client.Git.UpdateRef(tx.ctx, tx.ledger.owner, tx.ledger.repo, &github.Reference{
		Ref: &refName,
		Object: &github.GitObject{
			SHA: created.SHA,
		},
	}, false)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("Committed %s to %s/%s@%s\n", created.GetSHA(), tx.ledger.owner, tx.ledger.repo, tx.ledger.branch), nil
}

func (tx *githubLedgerTransaction) relPath(file string) (string, error) {
	if strings.Contains(file, "\x00") {
		return "", errors.New("invalid ledger path")
	}
	root, err := filepath.Abs(tx.ledger.cfg.LedgerRoot)
	if err != nil {
		return "", err
	}
	full := file
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, filepath.FromSlash(full))
	}
	full, err = filepath.Abs(full)
	if err != nil {
		return "", err
	}
	if full != root && !strings.HasPrefix(full, root+string(filepath.Separator)) {
		return "", errors.New("path is outside ledger root")
	}
	rel, err := filepath.Rel(root, full)
	if err != nil {
		return "", err
	}
	rel = filepath.ToSlash(filepath.Clean(rel))
	if rel == "." || strings.HasPrefix(rel, "../") || strings.Contains(rel, "/../") || strings.HasPrefix(rel, ".git/") {
		return "", errors.New("invalid ledger path")
	}
	return rel, nil
}

func githubCommitAuthor() *github.CommitAuthor {
	name := env("LEDGER_GIT_AUTHOR_NAME", "")
	email := env("LEDGER_GIT_AUTHOR_EMAIL", "")
	if name == "" && email == "" {
		return nil
	}
	now := github.Timestamp{Time: time.Now()}
	return &github.CommitAuthor{Name: &name, Email: &email, Date: &now}
}

func isGitHubNotFound(err error) bool {
	var response *github.ErrorResponse
	return errors.As(err, &response) && response.Response != nil && response.Response.StatusCode == http.StatusNotFound
}
