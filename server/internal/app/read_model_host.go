package app

import (
	"context"
)

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
