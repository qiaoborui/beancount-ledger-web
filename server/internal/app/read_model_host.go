package app

import (
	"context"
)

func (s *Server) ledgerSnapshot(ctx context.Context) (*LedgerSnapshot, error) {
	if s.snapshotPort != nil {
		return s.snapshotPort.Snapshot(ctx)
	}
	return s.cache.Snapshot()
}

func (s *Server) ledgerSnapshotLite(ctx context.Context) (*LedgerSnapshot, error) {
	if s.snapshotPort != nil {
		return s.snapshotPort.SnapshotLite(ctx)
	}
	return s.cache.Snapshot()
}
