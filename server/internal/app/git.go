package app

import (
	"errors"
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

func ledgerGitAvailable(cfg Config) (bool, error) {
	if remoteGitEnabled(cfg) {
		return true, nil
	}
	output, err := gitLedgerOutput(cfg, "rev-parse", "--is-inside-work-tree")
	if err != nil {
		if isGitRepositoryError(err.Error()) {
			return false, nil
		}
		return false, err
	}
	return strings.TrimSpace(output) == "true", nil
}

func ledgerGitUnavailablePayload() map[string]any {
	return map[string]any{
		"status": "", "dirty": false, "changedFileCount": 0, "changes": []GitChange{},
		"gitAvailable": false, "message": "Ledger Git is not available for this ledger.",
	}
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

func isGitRepositoryError(message string) bool {
	lower := strings.ToLower(message)
	return strings.Contains(lower, "not a git repository") ||
		strings.Contains(lower, "not a git repo") ||
		strings.Contains(lower, "fatal: bad revision") ||
		strings.Contains(lower, "不是 git") ||
		strings.Contains(lower, "不是git")
}

func gitCredentialHelp(cfg Config) string {
	return `GitHub 认证失败。请确认服务运行用户能访问 GitHub 凭据，或将账本仓库 remote 改为已配置 SSH key 的地址：
cd ` + cfg.LedgerRoot + `
git remote -v
git remote set-url origin git@github.com:OWNER/REPO.git`
}

func gitRemoteDisabled() bool {
	return truthyEnv("LEDGER_GIT_REMOTE_DISABLED")
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
