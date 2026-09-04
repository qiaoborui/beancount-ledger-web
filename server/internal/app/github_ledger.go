package app

import (
	"bytes"
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
	"sync"
	"time"

	"github.com/google/go-github/v74/github"
	"golang.org/x/sync/errgroup"
)

const (
	githubLedgerAPIConcurrency             = 6
	githubGraphQLCommitMaxFiles            = 50
	githubGraphQLCommitMaxEncodedFileBytes = 768 << 10
)

type githubLedgerClient struct {
	cfg              Config
	client           *github.Client
	owner            string
	repo             string
	branch           string
	useGraphQLCommit bool
}

type githubLedgerTransaction struct {
	ctx           context.Context
	ledger        *githubLedgerClient
	baseCommitSHA string
	baseTreeSHA   string
	cache         map[string]fileSnapshot
	writes        map[string][]byte
	metricsMu     sync.Mutex
	metrics       githubLedgerTransactionMetrics
}

type githubLedgerTransactionMetrics struct {
	readRequests    int
	readElapsed     time.Duration
	blobRequests    int
	blobElapsed     time.Duration
	treeElapsed     time.Duration
	commitElapsed   time.Duration
	refElapsed      time.Duration
	mutationElapsed time.Duration
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
	return &githubLedgerClient{
		cfg:              cfg,
		client:           client,
		owner:            owner,
		repo:             strings.TrimSuffix(repo, ".git"),
		branch:           branch,
		useGraphQLCommit: strings.EqualFold(client.BaseURL.Hostname(), "api.github.com") && client.BaseURL.Path == "/",
	}, nil
}

func (c *githubLedgerClient) beginTransaction(ctx context.Context) (*githubLedgerTransaction, error) {
	commit, _, err := c.client.Repositories.GetCommit(ctx, c.owner, c.repo, c.branch, nil)
	if err != nil {
		return nil, err
	}
	baseSHA := commit.GetSHA()
	if baseSHA == "" {
		return nil, errors.New("github branch ref has no commit SHA")
	}
	treeSHA := commit.GetCommit().GetTree().GetSHA()
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
	tree, _, err := c.client.Git.GetTree(ctx, c.owner, c.repo, c.branch, true)
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
	content, err := c.readLedgerFile(ctx, rel)
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
	tree, _, err := c.client.Git.GetTree(ctx, c.owner, c.repo, c.branch, true)
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
	tx := &githubLedgerTransaction{
		ctx:           ctx,
		ledger:        c,
		baseCommitSHA: c.branch,
		cache:         map[string]fileSnapshot{},
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
	if errors.Is(err, os.ErrNotExist) {
		tx.cache[rel] = fileSnapshot{existed: false}
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, err
	}
	tx.cache[rel] = fileSnapshot{existed: true, content: append([]byte(nil), content...)}
	return content, nil
}

func (tx *githubLedgerTransaction) readBaseFile(rel string) ([]byte, error) {
	return tx.readBaseFileContext(tx.ctx, rel)
}

func (tx *githubLedgerTransaction) readBaseFileContext(ctx context.Context, rel string) ([]byte, error) {
	started := time.Now()
	defer func() {
		tx.metricsMu.Lock()
		tx.metrics.readRequests++
		tx.metrics.readElapsed += time.Since(started)
		tx.metricsMu.Unlock()
	}()
	fileContent, _, _, err := tx.ledger.client.Repositories.GetContents(ctx, tx.ledger.owner, tx.ledger.repo, rel, &github.RepositoryContentGetOptions{Ref: tx.baseCommitSHA})
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

func (tx *githubLedgerTransaction) prefetch(files []string) error {
	rels := make([]string, 0, len(files))
	seen := map[string]bool{}
	for _, file := range files {
		rel, err := tx.relPath(file)
		if err != nil {
			return err
		}
		if seen[rel] {
			continue
		}
		seen[rel] = true
		if _, ok := tx.writes[rel]; ok {
			continue
		}
		if _, ok := tx.cache[rel]; ok {
			continue
		}
		rels = append(rels, rel)
	}
	if len(rels) == 0 {
		return nil
	}

	fetched := make(map[string]fileSnapshot, len(rels))
	var fetchedMu sync.Mutex
	group, ctx := errgroup.WithContext(tx.ctx)
	group.SetLimit(githubLedgerAPIConcurrency)
	for _, rel := range rels {
		rel := rel
		group.Go(func() error {
			content, err := tx.readBaseFileContext(ctx, rel)
			snapshot := fileSnapshot{existed: true, content: append([]byte(nil), content...)}
			if errors.Is(err, os.ErrNotExist) {
				snapshot = fileSnapshot{existed: false}
				err = nil
			}
			if err != nil {
				return err
			}
			fetchedMu.Lock()
			fetched[rel] = snapshot
			fetchedMu.Unlock()
			return nil
		})
	}
	if err := group.Wait(); err != nil {
		return err
	}
	for rel, snapshot := range fetched {
		tx.cache[rel] = snapshot
	}
	return nil
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
	if snap, ok := tx.cache[rel]; ok && snap.existed && bytes.Equal(snap.content, content) {
		delete(tx.writes, rel)
		return nil
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

const githubCreateCommitMutation = `mutation CreateCommit($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid }
  }
}`

type githubGraphQLFileAddition struct {
	Path     string `json:"path"`
	Contents string `json:"contents"`
}

type githubGraphQLCommitInput struct {
	Branch struct {
		RepositoryNameWithOwner string `json:"repositoryNameWithOwner"`
		BranchName              string `json:"branchName"`
	} `json:"branch"`
	FileChanges struct {
		Additions []githubGraphQLFileAddition `json:"additions"`
	} `json:"fileChanges"`
	Message struct {
		Headline string `json:"headline"`
	} `json:"message"`
	ExpectedHeadOID string `json:"expectedHeadOid"`
}

type githubGraphQLCommitResponse struct {
	Data struct {
		CreateCommitOnBranch struct {
			Commit struct {
				OID string `json:"oid"`
			} `json:"commit"`
		} `json:"createCommitOnBranch"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

func (tx *githubLedgerTransaction) commit(message string) (string, error) {
	if len(tx.writes) == 0 {
		return "", nil
	}
	if tx.canCommitGraphQL() {
		return tx.commitGraphQL(message)
	}
	return tx.commitWithGitData(message)
}

func (tx *githubLedgerTransaction) canCommitGraphQL() bool {
	if !tx.ledger.useGraphQLCommit || githubCommitAuthor() != nil || len(tx.writes) > githubGraphQLCommitMaxFiles {
		return false
	}
	encodedBytes := 0
	for _, content := range tx.writes {
		encodedBytes += base64.StdEncoding.EncodedLen(len(content))
		if encodedBytes > githubGraphQLCommitMaxEncodedFileBytes {
			return false
		}
	}
	return true
}

func (tx *githubLedgerTransaction) commitGraphQL(message string) (string, error) {
	paths := make([]string, 0, len(tx.writes))
	for path := range tx.writes {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	input := githubGraphQLCommitInput{ExpectedHeadOID: tx.baseCommitSHA}
	input.Branch.RepositoryNameWithOwner = tx.ledger.owner + "/" + tx.ledger.repo
	input.Branch.BranchName = tx.ledger.branch
	input.Message.Headline = message
	input.FileChanges.Additions = make([]githubGraphQLFileAddition, len(paths))
	for index, path := range paths {
		input.FileChanges.Additions[index] = githubGraphQLFileAddition{
			Path:     path,
			Contents: base64.StdEncoding.EncodeToString(tx.writes[path]),
		}
	}

	request, err := tx.ledger.client.NewRequest(http.MethodPost, "graphql", map[string]any{
		"query": githubCreateCommitMutation,
		"variables": map[string]any{
			"input": input,
		},
	})
	if err != nil {
		return "", err
	}
	started := time.Now()
	var response githubGraphQLCommitResponse
	_, err = tx.ledger.client.Do(tx.ctx, request, &response)
	tx.metrics.mutationElapsed = time.Since(started)
	if err != nil {
		return "", err
	}
	if len(response.Errors) > 0 {
		messages := make([]string, 0, len(response.Errors))
		for _, graphQLError := range response.Errors {
			messages = append(messages, graphQLError.Message)
		}
		return "", fmt.Errorf("github createCommitOnBranch: %s", strings.Join(messages, "; "))
	}
	sha := response.Data.CreateCommitOnBranch.Commit.OID
	if sha == "" {
		return "", errors.New("github createCommitOnBranch returned no commit OID")
	}
	return sha, nil
}

func (tx *githubLedgerTransaction) commitWithGitData(message string) (string, error) {
	paths := make([]string, 0, len(tx.writes))
	for path := range tx.writes {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	entries := make([]*github.TreeEntry, len(paths))
	blobStarted := time.Now()
	group, ctx := errgroup.WithContext(tx.ctx)
	group.SetLimit(githubLedgerAPIConcurrency)
	for index, path := range paths {
		index, path := index, path
		group.Go(func() error {
			content := base64.StdEncoding.EncodeToString(tx.writes[path])
			encoding := "base64"
			blob, _, err := tx.ledger.client.Git.CreateBlob(ctx, tx.ledger.owner, tx.ledger.repo, &github.Blob{Content: &content, Encoding: &encoding})
			if err != nil {
				return err
			}
			mode, typ := "100644", "blob"
			sha := blob.GetSHA()
			entries[index] = &github.TreeEntry{Path: &path, Mode: &mode, Type: &typ, SHA: &sha}
			return nil
		})
	}
	blobErr := group.Wait()
	tx.metrics.blobRequests = len(paths)
	tx.metrics.blobElapsed = time.Since(blobStarted)
	if blobErr != nil {
		return "", blobErr
	}
	treeStarted := time.Now()
	tree, _, err := tx.ledger.client.Git.CreateTree(tx.ctx, tx.ledger.owner, tx.ledger.repo, tx.baseTreeSHA, entries)
	tx.metrics.treeElapsed = time.Since(treeStarted)
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
	commitStarted := time.Now()
	created, _, err := tx.ledger.client.Git.CreateCommit(tx.ctx, tx.ledger.owner, tx.ledger.repo, commit, nil)
	tx.metrics.commitElapsed = time.Since(commitStarted)
	if err != nil {
		return "", err
	}
	refName := "refs/heads/" + tx.ledger.branch
	refStarted := time.Now()
	_, _, err = tx.ledger.client.Git.UpdateRef(tx.ctx, tx.ledger.owner, tx.ledger.repo, &github.Reference{
		Ref: &refName,
		Object: &github.GitObject{
			SHA: created.SHA,
		},
	}, false)
	tx.metrics.refElapsed = time.Since(refStarted)
	if err != nil {
		return "", err
	}
	return created.GetSHA(), nil
}

func (tx *githubLedgerTransaction) metricsSnapshot() githubLedgerTransactionMetrics {
	tx.metricsMu.Lock()
	defer tx.metricsMu.Unlock()
	return tx.metrics
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
