package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type ledgerFilesystemLockMode int

const (
	ledgerFilesystemSharedLock ledgerFilesystemLockMode = iota
	ledgerFilesystemExclusiveLock
)

const ledgerFilesystemLockRetryInterval = 50 * time.Millisecond

// EnsureLedgerFilesystemLock creates the advisory lock before the indexer is
// allowed to mount the ledger read-only. The lock itself has no ledger data.
func EnsureLedgerFilesystemLock(cfg Config) error {
	if githubAPIEnabled(cfg) || !cfg.LedgerFilesystemLockEnabled {
		return nil
	}
	path, err := ledgerFilesystemLockPath(cfg)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create ledger lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("create ledger lock file: %w", err)
	}
	return file.Close()
}

func withLedgerFilesystemLock(ctx context.Context, cfg Config, mode ledgerFilesystemLockMode, fn func() error) error {
	if githubAPIEnabled(cfg) || !cfg.LedgerFilesystemLockEnabled {
		return fn()
	}
	path, err := ledgerFilesystemLockPath(cfg)
	if err != nil {
		return err
	}
	flags := os.O_RDONLY
	if mode == ledgerFilesystemExclusiveLock {
		if err := EnsureLedgerFilesystemLock(cfg); err != nil {
			return err
		}
		flags = os.O_RDWR
	}
	file, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return fmt.Errorf("open ledger lock file: %w", err)
	}
	defer file.Close()

	operation := syscall.LOCK_SH
	if mode == ledgerFilesystemExclusiveLock {
		operation = syscall.LOCK_EX
	}
	if err := flockWithContext(ctx, int(file.Fd()), operation); err != nil {
		return err
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	return fn()
}

func ledgerFilesystemLockPath(cfg Config) (string, error) {
	path := cfg.LedgerLockFile
	if path == "" && cfg.LedgerRoot != "" {
		path = filepath.Join(cfg.LedgerRoot, ".ledger-web.lock")
	}
	if path == "" || path == "." {
		return "", errors.New("ledger filesystem lock path is required")
	}
	return filepath.Clean(path), nil
}

func flockWithContext(ctx context.Context, fd int, operation int) error {
	for {
		err := syscall.Flock(fd, operation|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return fmt.Errorf("acquire ledger filesystem lock: %w", err)
		}
		timer := time.NewTimer(ledgerFilesystemLockRetryInterval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return fmt.Errorf("wait for ledger filesystem lock: %w", ctx.Err())
		case <-timer.C:
		}
	}
}
