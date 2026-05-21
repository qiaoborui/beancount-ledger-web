package app

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type LedgerVersion struct {
	Version     string  `json:"version"`
	LatestMtime float64 `json:"latestMtimeMs"`
	FileCount   int     `json:"fileCount"`
}

type LedgerSnapshot struct {
	LedgerVersion
	Lines             []BeanLine         `json:"lines"`
	Transactions      []Transaction      `json:"transactions"`
	Balances          map[string]int     `json:"balances"`
	BalanceAssertions []BalanceAssertion `json:"balanceAssertions"`
	Budgets           []Budget           `json:"budgets"`
	Accounts          []Account          `json:"accounts"`
	ParsedAt          int64              `json:"parsedAt"`
}

type LedgerCache struct {
	cfg      Config
	mu       sync.Mutex
	snapshot *LedgerSnapshot
}

func NewLedgerCache(cfg Config) *LedgerCache {
	return &LedgerCache{cfg: cfg}
}

func (c *LedgerCache) Version() (LedgerVersion, error) {
	return ledgerVersion(c.cfg)
}

func (c *LedgerCache) Snapshot() (*LedgerSnapshot, error) {
	version, err := ledgerVersion(c.cfg)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.snapshot != nil && c.snapshot.Version == version.Version {
		return c.snapshot, nil
	}
	lines, err := ReadLedgerLines(mainBeanPath(c.cfg), map[string]bool{})
	if err != nil {
		return nil, err
	}
	txns := ParseTransactions(lines)
	accounts, err := ParseAccounts(c.cfg)
	if err != nil {
		return nil, err
	}
	snapshot := &LedgerSnapshot{
		LedgerVersion:     version,
		Lines:             lines,
		Transactions:      txns,
		Balances:          CurrentBalances(txns),
		BalanceAssertions: ParseBalances(lines),
		Budgets:           ParseBudgets(lines),
		Accounts:          accounts,
		ParsedAt:          time.Now().UnixMilli(),
	}
	c.snapshot = snapshot
	return snapshot, nil
}

func (c *LedgerCache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.snapshot = nil
}

type fileStat struct {
	relative string
	size     int64
	mtimeMs  int64
}

func ledgerVersion(cfg Config) (LedgerVersion, error) {
	stats := []fileStat{}
	err := filepath.WalkDir(cfg.LedgerRoot, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".runtime", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".bean") {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(cfg.LedgerRoot, path)
		stats = append(stats, fileStat{
			relative: filepath.ToSlash(rel),
			size:     info.Size(),
			mtimeMs:  info.ModTime().UnixMilli(),
		})
		return nil
	})
	if err != nil {
		return LedgerVersion{}, err
	}
	sort.Slice(stats, func(i, j int) bool { return stats[i].relative < stats[j].relative })
	hash := sha256.New()
	var latest int64
	for _, stat := range stats {
		hash.Write([]byte(stat.relative))
		hash.Write([]byte{0})
		hash.Write([]byte(strconv.FormatInt(stat.size, 10)))
		hash.Write([]byte{0})
		hash.Write([]byte(strconv.FormatInt(stat.mtimeMs, 10)))
		hash.Write([]byte{0})
		if stat.mtimeMs > latest {
			latest = stat.mtimeMs
		}
	}
	return LedgerVersion{Version: hex.EncodeToString(hash.Sum(nil)), LatestMtime: float64(latest), FileCount: len(stats)}, nil
}
