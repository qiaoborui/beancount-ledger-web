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
)

// validate stages the candidate include closure at the transaction's immutable
// base revision. The staging directory is disposable; GitHub deployments do not
// need a checkout or write access to LedgerRoot.
func (tx *githubLedgerTransaction) validate() error {
	if len(tx.writes) == 0 {
		return nil
	}
	root, err := os.MkdirTemp("", "ledger-write-check-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)

	seen := map[string]bool{}
	var treePaths []string
	var stage func(string) error
	stage = func(file string) error {
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
				if treePaths == nil {
					treePaths, err = tx.validationTreePaths()
					if err != nil {
						return err
					}
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
				if err := stage(pattern); err != nil {
					return err
				}
				continue
			}
			if treePaths == nil {
				treePaths, err = tx.validationTreePaths()
				if err != nil {
					return err
				}
			}
			for _, candidate := range treePaths {
				matched, err := filepath.Match(filepath.FromSlash(patternRel), filepath.FromSlash(candidate))
				if err != nil {
					return fmt.Errorf("invalid validation include %q: %w", include, err)
				}
				if matched {
					if err := stage(filepath.Join(tx.ledger.cfg.LedgerRoot, filepath.FromSlash(candidate))); err != nil {
						return err
					}
				}
			}
		}
		return nil
	}
	if err := stage(mainBeanPath(tx.ledger.cfg)); err != nil {
		return fmt.Errorf("prepare GitHub ledger validation: %w", err)
	}
	cfg := tx.ledger.cfg
	cfg.LedgerRoot = root
	if err := runBeanCheckContext(tx.ctx, cfg); err != nil {
		if tx.ctx.Err() != nil {
			return tx.ctx.Err()
		}
		// Keep diagnostics useful without leaking an ephemeral filesystem path.
		return fmt.Errorf("GitHub ledger validation failed: %s", strings.ReplaceAll(err.Error(), root+string(filepath.Separator), ""))
	}
	return nil
}

func (tx *githubLedgerTransaction) validationTreePaths() ([]string, error) {
	tree, _, err := tx.ledger.client.Git.GetTree(tx.ctx, tx.ledger.owner, tx.ledger.repo, tx.baseTreeSHA, true)
	if err != nil {
		return nil, err
	}
	if tree.GetTruncated() {
		return nil, fmt.Errorf("GitHub tree is too large to validate all ledger includes")
	}
	paths := map[string]bool{}
	for _, entry := range tree.Entries {
		if entry.GetType() == "blob" {
			paths[entry.GetPath()] = true
		}
	}
	for path := range tx.writes {
		paths[path] = true
	}
	result := make([]string, 0, len(paths))
	for path := range paths {
		result = append(result, path)
	}
	sort.Strings(result)
	return result, nil
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
