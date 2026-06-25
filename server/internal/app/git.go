package app

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var ledgerGitCandidatePaths = []string{"main.bean", "transactions", "accounts.bean", "commodities.bean", "prices.bean", "README.md"}

type GitChange struct {
	Path           string `json:"path"`
	OriginalPath   string `json:"originalPath,omitempty"`
	IndexStatus    string `json:"indexStatus"`
	WorkTreeStatus string `json:"workTreeStatus"`
	Status         string `json:"status"`
	Label          string `json:"label"`
}

const gitDiffMaxBytes = 200_000

func gitLedger(cfg Config, args ...string) (string, error) {
	return gitLedgerOutput(cfg, args...)
}

func gitLedgerOutput(cfg Config, args ...string) (string, error) {
	out, err := exec.Command("git", append(gitLedgerBaseArgs(cfg), args...)...).CombinedOutput()
	text := string(out)
	if err != nil {
		message := strings.TrimSpace(text)
		if message == "" {
			message = err.Error()
		}
		if isGitAuthorIdentityError(message) {
			message = gitAuthorIdentityHelp(cfg)
		}
		if isGitCredentialError(message) {
			message = gitCredentialHelp(cfg)
		}
		return text, errors.New(message)
	}
	return text, nil
}

func gitLedgerBaseArgs(cfg Config) []string {
	base := []string{"-c", "safe.directory=" + cfg.LedgerRoot}
	if name := env("LEDGER_GIT_AUTHOR_NAME", ""); name != "" {
		base = append(base, "-c", "user.name="+name)
	}
	if email := env("LEDGER_GIT_AUTHOR_EMAIL", ""); email != "" {
		base = append(base, "-c", "user.email="+email)
	}
	return append(base, "-C", cfg.LedgerRoot)
}

func isGitAuthorIdentityError(message string) bool {
	lower := strings.ToLower(message)
	return strings.Contains(lower, "author identity unknown") ||
		strings.Contains(lower, "unable to auto-detect email address") ||
		strings.Contains(lower, "empty ident name") ||
		strings.Contains(message, "作者身份未知") ||
		strings.Contains(message, "无法自动探测邮件地址")
}

func gitAuthorIdentityHelp(cfg Config) string {
	return `Git 提交缺少作者身份。请在账本仓库设置：
cd ` + cfg.LedgerRoot + `
git config user.name "Your Name"
git config user.email "you@example.com"
也可以在服务环境中设置 LEDGER_GIT_AUTHOR_NAME 和 LEDGER_GIT_AUTHOR_EMAIL 后重启服务。`
}

func isGitCredentialError(message string) bool {
	lower := strings.ToLower(message)
	return strings.Contains(lower, "could not read username for") ||
		strings.Contains(lower, "authentication failed")
}

func gitCredentialHelp(cfg Config) string {
	return `GitHub 认证失败，服务进程无法读取当前 Git 凭据。请确认服务运行用户能访问 GitHub 凭据，或将账本仓库 remote 改为已配置 SSH key 的地址：
cd ` + cfg.LedgerRoot + `
git remote -v
git remote set-url origin git@github.com:OWNER/REPO.git
如果使用 HTTPS，请让 systemd 服务以已登录 GitHub CLI 的用户运行，并确认该用户的 HOME 指向正确。`
}

func gitRemoteDisabled() bool {
	return truthyEnv("LEDGER_GIT_REMOTE_DISABLED")
}

func ledgerGitDiffForPath(cfg Config, rawPath string) (string, bool, error) {
	path, err := cleanLedgerGitPath(cfg, rawPath)
	if err != nil {
		return "", false, err
	}
	status, err := gitLedgerOutput(cfg, "status", "--short", "--", path)
	if err != nil {
		return "", false, err
	}
	change := ""
	changes := parseGitChanges(status)
	for _, item := range changes {
		if item.Path == path || item.OriginalPath == path {
			change = item.Status
			break
		}
	}
	if change == "??" {
		diff, truncated, err := untrackedFileDiff(cfg, path)
		return diff, truncated, err
	}
	cached, err := gitLedgerOutput(cfg, "diff", "--cached", "--no-ext-diff", "--", path)
	if err != nil {
		return "", false, err
	}
	worktree, err := gitLedgerOutput(cfg, "diff", "--no-ext-diff", "--", path)
	if err != nil {
		return "", false, err
	}
	parts := []string{}
	if strings.TrimSpace(cached) != "" {
		parts = append(parts, cached)
	}
	if strings.TrimSpace(worktree) != "" {
		parts = append(parts, worktree)
	}
	if len(parts) == 0 {
		return "该文件没有可显示的文本差异。", false, nil
	}
	combined := strings.Join(parts, "\n")
	return truncateGitDiff(combined), len(combined) > gitDiffMaxBytes, nil
}

func cleanLedgerGitPath(cfg Config, rawPath string) (string, error) {
	trimmed := strings.TrimSpace(rawPath)
	if trimmed == "" {
		return "", errors.New("path is required")
	}
	if strings.Contains(trimmed, "\x00") || filepath.IsAbs(trimmed) {
		return "", errors.New("invalid git path")
	}
	path := filepath.ToSlash(filepath.Clean(trimmed))
	if path == "." || strings.HasPrefix(path, "../") || strings.Contains(path, "/../") {
		return "", errors.New("invalid git path")
	}
	for _, allowed := range ledgerGitCandidatePaths {
		if path == allowed || strings.HasPrefix(path, allowed+"/") {
			return path, nil
		}
	}
	if isLedgerEditorPathAllowed(path) {
		return path, nil
	}
	return "", fmt.Errorf("path is outside ledger tracked areas: %s", path)
}

func untrackedFileDiff(cfg Config, path string) (string, bool, error) {
	full := filepath.Join(cfg.LedgerRoot, filepath.FromSlash(path))
	raw, err := os.ReadFile(full)
	if err != nil {
		return "", false, err
	}
	text, truncated := truncateRawText(string(raw))
	var builder strings.Builder
	builder.WriteString("diff --git a/")
	builder.WriteString(path)
	builder.WriteString(" b/")
	builder.WriteString(path)
	builder.WriteString("\nnew file\n--- /dev/null\n+++ b/")
	builder.WriteString(path)
	builder.WriteString("\n@@\n")
	for _, line := range strings.Split(text, "\n") {
		if line == "" {
			builder.WriteString("+\n")
			continue
		}
		builder.WriteString("+")
		builder.WriteString(line)
		builder.WriteString("\n")
	}
	return builder.String(), truncated, nil
}

func truncateRawText(text string) (string, bool) {
	if len(text) <= gitDiffMaxBytes {
		return text, false
	}
	return text[:gitDiffMaxBytes] + "\n... diff truncated ...", true
}

func truncateGitDiff(diff string) string {
	text, _ := truncateRawText(diff)
	return text
}

func ledgerGitTrackedPathspecs(cfg Config) []string {
	paths := []string{}
	seen := map[string]bool{}
	for _, path := range ledgerGitCandidatePaths {
		if _, err := os.Stat(filepath.Join(cfg.LedgerRoot, path)); err == nil {
			paths = append(paths, path)
			seen[path] = true
			continue
		}
		output, err := gitLedgerOutput(cfg, "ls-files", "--", path)
		if err == nil && strings.TrimSpace(output) != "" {
			paths = append(paths, path)
			seen[path] = true
		}
	}
	if files, err := listLedgerEditorFiles(cfg); err == nil {
		for _, file := range files {
			if seen[file.Path] {
				continue
			}
			paths = append(paths, file.Path)
			seen[file.Path] = true
		}
	}
	return paths
}

func parseGitChanges(status string) []GitChange {
	changes := []GitChange{}
	for _, line := range strings.Split(status, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		for len(line) < 3 {
			line += " "
		}
		indexStatus := string(line[0])
		workTreeStatus := string(line[1])
		rawPath := strings.TrimSpace(line[3:])
		originalPath := ""
		path := rawPath
		if before, after, ok := strings.Cut(rawPath, " -> "); ok {
			originalPath = before
			path = after
		}
		combined := strings.TrimSpace(indexStatus + workTreeStatus)
		if combined == "" {
			combined = "changed"
		}
		changes = append(changes, GitChange{
			Path:           path,
			OriginalPath:   originalPath,
			IndexStatus:    indexStatus,
			WorkTreeStatus: workTreeStatus,
			Status:         combined,
			Label:          gitStatusLabel(indexStatus, workTreeStatus),
		})
	}
	return changes
}

func gitStatusLabel(indexStatus, workTreeStatus string) string {
	combined := indexStatus + workTreeStatus
	switch {
	case combined == "??":
		return "未跟踪"
	case indexStatus == "R" || workTreeStatus == "R":
		return "重命名"
	case indexStatus == "C" || workTreeStatus == "C":
		return "复制"
	case indexStatus == "A" || workTreeStatus == "A":
		return "新增"
	case indexStatus == "D" || workTreeStatus == "D":
		return "删除"
	case indexStatus == "M" || workTreeStatus == "M":
		return "修改"
	case indexStatus == "U" || workTreeStatus == "U":
		return "冲突"
	default:
		return "变更"
	}
}
