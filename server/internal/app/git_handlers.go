package app

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

func (s *Server) gitStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	trackedPaths := ledgerGitTrackedPathspecs(s.cfg)
	output, err := gitLedger(s.cfg, append([]string{"status", "--short", "--"}, trackedPaths...)...)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	changes := parseGitChanges(output)
	c.JSON(http.StatusOK, gin.H{"status": output, "dirty": len(changes) > 0, "changedFileCount": len(changes), "changes": changes})
}

func (s *Server) gitDiff(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	path := c.Query("path")
	diff, truncated, err := ledgerGitDiffForPath(s.cfg, path)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"path": path, "diff": diff, "truncated": truncated})
}

func (s *Server) gitPull(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if gitRemoteDisabled() {
		c.JSON(http.StatusOK, gin.H{"ok": true, "output": "Git remote sync disabled\n"})
		return
	}
	publishJobStatus("git.pull", "running", "")
	if remoteGitEnabled(s.cfg) {
		if err := syncLedgerNow(s.cfg); err != nil {
			publishJobStatus("git.pull", "error", err.Error())
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		out := "Remote Git checkout synced.\n"
		publishJobStatus("git.pull", "ok", out)
		publishLedgerUpdated(s.cfg, "git-pull")
		publishGitStatus(s.cfg, "git-pull")
		c.JSON(http.StatusOK, gin.H{"ok": true, "output": out})
		return
	}
	out, err := gitLedgerOutput(s.cfg, "pull", "--rebase")
	if err != nil {
		publishJobStatus("git.pull", "error", err.Error())
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	publishJobStatus("git.pull", "ok", out)
	publishLedgerUpdated(s.cfg, "git-pull")
	publishGitStatus(s.cfg, "git-pull")
	c.JSON(http.StatusOK, gin.H{"ok": true, "output": out})
}

func (s *Server) gitCommit(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	var input GitCommitRequest
	_ = c.ShouldBindJSON(&input)
	if strings.TrimSpace(input.Message) == "" {
		input.Message = "chore: update ledger"
	}
	if remoteGitEnabled(s.cfg) {
		if err := ensureLedgerReady(s.cfg); err != nil {
			errorJSON(c, http.StatusBadRequest, err)
			return
		}
		c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": 0, "remainingChangedFileCount": 0, "output": "Remote Git mode commits and pushes each ledger write automatically."})
		return
	}
	trackedPaths := ledgerGitTrackedPathspecs(s.cfg)
	before, err := gitLedger(s.cfg, append([]string{"status", "--short", "--"}, trackedPaths...)...)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	beforeChanges := parseGitChanges(before)
	if len(beforeChanges) == 0 {
		c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": 0, "output": "No ledger changes to commit."})
		return
	}
	publishJobStatus("git.commit", "running", "")
	output, err := ledgerGitCommitPullPush(s.cfg, input.Message)
	if err != nil {
		publishJobStatus("git.commit", "error", err.Error())
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	after, err := gitLedger(s.cfg, append([]string{"status", "--short", "--"}, trackedPaths...)...)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	publishJobStatus("git.commit", "ok", output)
	publishGitStatus(s.cfg, "git-commit")
	publishLedgerUpdated(s.cfg, "git-commit")
	c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": len(beforeChanges), "remainingChangedFileCount": len(parseGitChanges(after)), "output": output})
}
