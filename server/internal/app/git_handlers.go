package app

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
)

func (s *Server) gitStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.readModelHostMode() || githubAPIEnabled(s.cfg) {
		c.JSON(http.StatusOK, ledgerGitManagedExternallyPayload())
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

func (s *Server) gitDiff(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if s.rejectLocalGitOperation(c, "git.diff") {
		return
	}
	if s.rejectWorkerOnly(c, "git.diff") {
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
		errorJSON(c, http.StatusBadRequest, errors.New("Ledger Git is not available for this ledger"))
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
	c.JSON(http.StatusNotImplemented, gin.H{
		"error":     ErrWorkerOnlyOperation.Error(),
		"operation": "git.pull",
		"message":   "Remote Git sync has been removed from the application. Sync the local ledger checkout outside ledger-web.",
	})
}

func (s *Server) gitCommit(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	c.JSON(http.StatusNotImplemented, gin.H{
		"error":     ErrWorkerOnlyOperation.Error(),
		"operation": "git.commit",
		"message":   "Git commits are managed outside ledger-web. Use GitHub API writes on the stateless host or commit directly in the local ledger repository.",
	})
}

func (s *Server) rejectLocalGitOperation(c *gin.Context, operation string) bool {
	if !s.readModelHostMode() && !githubAPIEnabled(s.cfg) {
		return false
	}
	c.JSON(http.StatusNotImplemented, gin.H{
		"error":     ErrWorkerOnlyOperation.Error(),
		"operation": operation,
		"message":   "Ledger Git is managed outside the stateless API host. Run this operation on the local ledger worker or directly in the ledger repository.",
	})
	return true
}
