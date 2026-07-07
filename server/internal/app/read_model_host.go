package app

import (
	"context"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
)

var ErrWorkerOnlyOperation = errors.New("this operation requires the local ledger worker")

func (s *Server) readModelHostMode() bool {
	return ledgerReadModelEnabled(s.cfg) && s.cfg.ReadModelStrict
}

func (s *Server) ledgerSnapshot(ctx context.Context) (*LedgerSnapshot, error) {
	if s.readService != nil {
		return s.readService.Snapshot(ctx)
	}
	return s.cache.Snapshot()
}

func (s *Server) ledgerSnapshotLite(ctx context.Context) (*LedgerSnapshot, error) {
	if s.readService != nil {
		return s.readService.SnapshotLite(ctx)
	}
	return s.cache.Snapshot()
}

func (s *Server) rejectWorkerOnly(c *gin.Context, operation string) bool {
	if !s.readModelHostMode() || githubAPIEnabled(s.cfg) {
		return false
	}
	c.JSON(http.StatusNotImplemented, gin.H{
		"error":     ErrWorkerOnlyOperation.Error(),
		"operation": operation,
		"message":   "The Vercel host serves the Postgres ledger read model only. Run this operation on the local ledger worker.",
	})
	return true
}
