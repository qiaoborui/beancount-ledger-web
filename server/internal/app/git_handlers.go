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
	if s.readModelHostMode() {
		c.JSON(http.StatusOK, gin.H{"status": "", "dirty": false, "changedFileCount": 0, "changes": []GitChange{}, "gitAvailable": false, "message": "Ledger Git is managed by the local ledger worker."})
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	available, err := ledgerGitAvailable(s.cfg)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !available {
		c.JSON(http.StatusOK, ledgerGitUnavailablePayload())
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

func (s *Server) gitPull(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "git.pull") {
		return
	}
	if gitRemoteDisabled() {
		c.JSON(http.StatusOK, gin.H{"ok": true, "output": "Git remote sync disabled\n"})
		return
	}
	publishJobStatus("git.pull", "running", "")
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
}

func (s *Server) gitCommit(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectWorkerOnly(c, "git.commit") {
		return
	}
	var input GitCommitRequest
	_ = c.ShouldBindJSON(&input)
	if strings.TrimSpace(input.Message) == "" {
		input.Message = "chore: update ledger"
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "changedFileCount": 0, "remainingChangedFileCount": 0, "output": "Remote Git mode commits and pushes each ledger write automatically."})
}
