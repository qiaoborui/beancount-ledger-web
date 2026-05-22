package app

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var ledgerGitCandidatePaths = []string{"main.bean", "transactions", "budgets.bean", "README.md", "accounts.bean", "prices.bean"}

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
	out, err := exec.Command("git", append([]string{"-c", "safe.directory=" + cfg.LedgerRoot, "-C", cfg.LedgerRoot}, args...)...).CombinedOutput()
	text := string(out)
	if err != nil {
		message := strings.TrimSpace(text)
		if message == "" {
			message = err.Error()
		}
		return text, errors.New(message)
	}
	return text, nil
}

func gitRemoteDisabled() bool {
	return truthyEnv("LEDGER_GIT_REMOTE_DISABLED")
}

func ledgerGitTrackedPathspecs(cfg Config) []string {
	paths := []string{}
	for _, path := range ledgerGitCandidatePaths {
		if _, err := os.Stat(filepath.Join(cfg.LedgerRoot, path)); err == nil {
			paths = append(paths, path)
			continue
		}
		output, err := gitLedgerOutput(cfg, "ls-files", "--", path)
		if err == nil && strings.TrimSpace(output) != "" {
			paths = append(paths, path)
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
