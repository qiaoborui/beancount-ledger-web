package automation

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// gitTimeout bounds every git call; a hung network must not hold the tick
// lock forever.
const gitTimeout = 3 * time.Minute

func git(ctx context.Context, dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = dir
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	if err := command.Run(); err != nil {
		return stdout.String(), fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

// syncMirror keeps a bare copy of the ledger repository and returns the
// commit the ledger branch points at.
func (r *Runner) syncMirror(ctx context.Context) (string, error) {
	mirror := r.mirrorDir()
	if _, err := os.Stat(filepath.Join(mirror, "HEAD")); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(mirror), 0o700); err != nil {
			return "", err
		}
		if _, err := git(ctx, "", "clone", "--bare", "--single-branch", "--branch", r.cfg.Branch, r.cfg.Repo, mirror); err != nil {
			return "", err
		}
	}
	if _, err := git(ctx, mirror, "fetch", "--prune", "origin", "+refs/heads/"+r.cfg.Branch+":refs/heads/"+r.cfg.Branch); err != nil {
		return "", err
	}
	sha, err := git(ctx, mirror, "rev-parse", "refs/heads/"+r.cfg.Branch)
	return strings.TrimSpace(sha), err
}

// exportGeneration writes the tree of a commit to
// ledger/generations/<sha>/workspace, the layout the ledger core reads, and
// drops older generations.
func (r *Runner) exportGeneration(ctx context.Context, sha string) (string, error) {
	generations := filepath.Join(r.cfg.Home, "ledger", "generations")
	workspace := filepath.Join(generations, sha[:12], "workspace")
	if _, err := os.Stat(filepath.Join(workspace, r.cfg.Entrypoint)); err == nil {
		return workspace, nil
	}
	if err := os.MkdirAll(filepath.Join(r.cfg.Home, "ledger", "runtime"), 0o700); err != nil {
		return "", err
	}
	staging := workspace + ".partial"
	_ = os.RemoveAll(filepath.Dir(staging))
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", "archive", "--format=tar", sha)
	command.Dir = r.mirrorDir()
	var stderr bytes.Buffer
	command.Stderr = &stderr
	stdout, err := command.StdoutPipe()
	if err != nil {
		return "", err
	}
	if err := command.Start(); err != nil {
		return "", err
	}
	extractErr := extractTar(stdout, staging)
	_, _ = io.Copy(io.Discard, stdout)
	if err := command.Wait(); err != nil {
		return "", fmt.Errorf("git archive: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if extractErr != nil {
		return "", extractErr
	}
	if err := os.Rename(staging, workspace); err != nil {
		return "", err
	}
	entries, _ := os.ReadDir(generations)
	for _, entry := range entries {
		if entry.Name() != sha[:12] {
			_ = os.RemoveAll(filepath.Join(generations, entry.Name()))
		}
	}
	return workspace, nil
}

func extractTar(stream io.Reader, dir string) error {
	reader := tar.NewReader(stream)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(header.Name)
		if name == "." || filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, ".."+string(filepath.Separator)) {
			continue
		}
		target := filepath.Join(dir, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o700); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
				return err
			}
			file, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(file, reader)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		default:
			// Symlinks and other special entries never reach the ledger
			// core, which refuses them.
		}
	}
}

// openRuns returns the worktree of the record branch, creating the branch
// on first use. Only this runner writes it, so the worktree is the truth
// after the first fetch.
func (r *Runner) openRuns(ctx context.Context) (string, error) {
	dir := r.runsDir()
	if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
		return dir, nil
	}
	mirror := r.mirrorDir()
	_ = os.RemoveAll(dir)
	_, _ = git(ctx, mirror, "worktree", "prune")
	ref := "refs/heads/" + r.cfg.RunsBranch
	if _, err := git(ctx, mirror, "fetch", "origin", "+"+ref+":"+ref); err == nil {
		if _, err := git(ctx, mirror, "worktree", "add", dir, r.cfg.RunsBranch); err != nil {
			return "", err
		}
		return dir, nil
	}
	if _, err := git(ctx, mirror, "worktree", "add", "--detach", dir, "refs/heads/"+r.cfg.Branch); err != nil {
		return "", err
	}
	if _, err := git(ctx, dir, "checkout", "--orphan", r.cfg.RunsBranch); err != nil {
		return "", err
	}
	if _, err := git(ctx, dir, "rm", "-rf", "--quiet", "."); err != nil {
		return "", err
	}
	readme := "# 定时任务运行记录\n\n这个分支由 ledger-automation 自动写入，不要手动修改。每次运行一个目录：runs/<运行 id>/。\n"
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte(readme), 0o600); err != nil {
		return "", err
	}
	if err := r.commitRuns(ctx, dir, "Start automation run records"); err != nil {
		return "", err
	}
	return dir, nil
}

// commitRuns commits everything in the record worktree and pushes it,
// retrying the push a few times on a flaky network. The commit stays local
// when every push fails; the next tick pushes it.
func (r *Runner) commitRuns(ctx context.Context, dir, message string) error {
	if _, err := git(ctx, dir, "add", "-A"); err != nil {
		return err
	}
	if status, err := git(ctx, dir, "status", "--porcelain"); err != nil {
		return err
	} else if strings.TrimSpace(status) != "" {
		if _, err := git(ctx, dir, "-c", "user.name="+r.cfg.CommitName, "-c", "user.email="+r.cfg.CommitEmail,
			"commit", "--quiet", "--no-verify", "-m", message); err != nil {
			return err
		}
	}
	return r.pushRuns(ctx, dir)
}

func (r *Runner) pushRuns(ctx context.Context, dir string) error {
	var err error
	for attempt := 0; attempt < 4; attempt++ {
		if attempt > 0 {
			r.sleep(ctx, time.Duration(1<<attempt)*time.Second)
		}
		if _, err = git(ctx, dir, "push", "--quiet", "origin", "HEAD:refs/heads/"+r.cfg.RunsBranch); err == nil {
			return nil
		}
	}
	return err
}

// openScratch checks out the pinned commit as the copy the Agent may edit.
func (r *Runner) openScratch(ctx context.Context, sha, runID string) (string, func(), error) {
	dir := filepath.Join(r.cfg.Home, "scratch", runID)
	_ = os.RemoveAll(dir)
	_, _ = git(ctx, r.mirrorDir(), "worktree", "prune")
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return "", nil, err
	}
	if _, err := git(ctx, r.mirrorDir(), "worktree", "add", "--detach", dir, sha); err != nil {
		return "", nil, err
	}
	cleanup := func() {
		_, _ = git(context.Background(), r.mirrorDir(), "worktree", "remove", "--force", dir)
		_ = os.RemoveAll(dir)
	}
	return dir, cleanup, nil
}

// draftPatch is what the Agent changed in its copy, as a patch against the
// pinned commit that `git apply` takes.
func draftPatch(ctx context.Context, scratch string) (string, error) {
	if _, err := git(ctx, scratch, "add", "-A"); err != nil {
		return "", err
	}
	return git(ctx, scratch, "diff", "--cached", "--binary", "--no-color")
}
