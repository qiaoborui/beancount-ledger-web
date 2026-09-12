package app

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// validate stages the candidate include closure at the transaction's immutable
// base revision. The staging directory is disposable; GitHub deployments do not
// need a checkout or write access to LedgerRoot.
func (tx *githubLedgerTransaction) validate() error {
	if len(tx.writes) == 0 {
		return nil
	}
	started := time.Now()
	defer func() { tx.metrics.validationElapsed = time.Since(started) }()
	tree, err := tx.validationTreeBlobs()
	if err != nil {
		return fmt.Errorf("prepare GitHub ledger validation: %w", err)
	}
	treePaths := make([]string, 0, len(tree)+len(tx.writes))
	for rel := range tree {
		treePaths = append(treePaths, rel)
	}
	for rel := range tx.writes {
		if _, exists := tree[rel]; !exists {
			treePaths = append(treePaths, rel)
		}
	}
	sort.Strings(treePaths)
	root, err := os.MkdirTemp("", "ledger-write-check-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)

	seen := map[string]bool{}
	queue := []string{mainBeanPath(tx.ledger.cfg)}
	stage := func(file string) error {
		rel, err := tx.relPath(file)
		if err != nil {
			return err
		}
		if seen[rel] {
			return nil
		}
		seen[rel] = true
		content, err := tx.readFile(file)
		if err != nil {
			return fmt.Errorf("read validation include %s: %w", rel, err)
		}
		dest := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(dest, content, 0o600); err != nil {
			return err
		}
		for _, line := range strings.Split(string(content), "\n") {
			tokens := scanBeanLine(line)
			if len(tokens) >= 4 && tokens[1].Value == "document" && tokens[3].Kind == beanTokenString {
				document := tokens[3].Value
				if filepath.IsAbs(document) {
					return fmt.Errorf("validation document must be relative to the ledger: %s", document)
				}
				documentRel, err := tx.relPath(filepath.Join(filepath.Dir(file), filepath.FromSlash(document)))
				if err != nil {
					return err
				}
				// The built-in document plugin checks existence. Mirror only
				// confirmed repository paths, without downloading private bills.
				index := sort.SearchStrings(treePaths, documentRel)
				if index < len(treePaths) && treePaths[index] == documentRel {
					dest := filepath.Join(root, filepath.FromSlash(documentRel))
					if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
						return err
					}
					file, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY, 0o600)
					if err != nil {
						return err
					}
					if err := file.Close(); err != nil {
						return err
					}
				}
			}
			if len(tokens) < 2 || tokens[0].Value != "include" || tokens[1].Kind != beanTokenString {
				continue
			}
			include := tokens[1].Value
			// Absolute includes would make bean-check read outside its isolated
			// candidate snapshot. Relative parent traversal within the repo works.
			if filepath.IsAbs(include) {
				return fmt.Errorf("validation include must be relative to the ledger: %s", include)
			}
			pattern := filepath.Join(filepath.Dir(file), filepath.FromSlash(include))
			patternRel, err := tx.relPath(pattern)
			if err != nil {
				return err
			}
			if !strings.ContainsAny(include, "*?[") {
				queue = append(queue, pattern)
				continue
			}
			for _, candidate := range treePaths {
				matched, err := filepath.Match(filepath.FromSlash(patternRel), filepath.FromSlash(candidate))
				if err != nil {
					return fmt.Errorf("invalid validation include %q: %w", include, err)
				}
				if matched {
					queue = append(queue, filepath.Join(tx.ledger.cfg.LedgerRoot, filepath.FromSlash(candidate)))
				}
			}
		}
		return nil
	}
	// Hydrate each breadth-first include frontier with the existing six-request
	// limiter. Parsing/staging and transaction maps stay on this goroutine.
	for len(queue) > 0 {
		batch := queue
		queue = nil
		for _, file := range batch {
			rel, err := tx.relPath(file)
			if err != nil {
				return err
			}
			if _, exists := tx.cache[rel]; exists {
				continue
			}
			if _, written := tx.writes[rel]; written {
				continue
			}
			if content, ok := tx.ledger.validationCache.get(tree[rel]); ok {
				tx.cache[rel] = fileSnapshot{existed: true, content: content}
				tx.metrics.validationCacheHits++
			}
		}
		if err := tx.prefetch(batch); err != nil {
			return fmt.Errorf("fetch validation includes: %w", err)
		}
		for _, file := range batch {
			if err := stage(file); err != nil {
				return fmt.Errorf("prepare GitHub ledger validation: %w", err)
			}
		}
	}
	// Cache only actual content identities. Candidate writes get their own SHA,
	// so failures, retries and external branch changes cannot reuse stale bytes.
	for rel := range seen {
		if content, written := tx.writes[rel]; written {
			tx.ledger.validationCache.put(content)
		} else if snapshot := tx.cache[rel]; snapshot.existed {
			tx.ledger.validationCache.put(snapshot.content)
		}
	}

	cfg := tx.ledger.cfg
	cfg.LedgerRoot = root
	checkStarted := time.Now()
	defer func() { tx.metrics.beanCheckElapsed = time.Since(checkStarted) }()
	if err := runBeanCheckContext(tx.ctx, cfg); err != nil {
		if tx.ctx.Err() != nil {
			return tx.ctx.Err()
		}
		// Keep diagnostics useful without leaking an ephemeral filesystem path.
		return fmt.Errorf("GitHub ledger validation failed: %s", strings.ReplaceAll(err.Error(), root+string(filepath.Separator), ""))
	}
	return nil
}

func (tx *githubLedgerTransaction) validationTreeBlobs() (map[string]string, error) {
	tree, _, err := tx.ledger.client.Git.GetTree(tx.ctx, tx.ledger.owner, tx.ledger.repo, tx.baseTreeSHA, true)
	if err != nil {
		return nil, err
	}
	if tree.GetTruncated() {
		return nil, fmt.Errorf("GitHub tree is too large to validate all ledger includes")
	}
	blobs := make(map[string]string)
	for _, entry := range tree.Entries {
		if entry.GetType() == "blob" {
			// Symlink tree objects hash the link text, while the Contents API
			// can return the target bytes. Only regular blobs share identities
			// across these APIs; retain other paths but always fetch them.
			sha := ""
			if entry.GetMode() == "100644" || entry.GetMode() == "100755" {
				sha = entry.GetSHA()
			}
			blobs[entry.GetPath()] = sha
		}
	}
	return blobs, nil
}

func runBeanCheckContext(ctx context.Context, cfg Config) error {
	command := exec.CommandContext(ctx, env("BEAN_CHECK_BIN", "bean-check"), mainBeanPath(cfg))
	command.Dir = filepath.Dir(mainBeanPath(cfg))
	var output bytes.Buffer
	command.Stderr = &output
	command.Stdout = &output
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if output.Len() > 0 {
			return fmt.Errorf("%w: %s", err, strings.TrimSpace(output.String()))
		}
		return err
	}
	return nil
}
