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
	Lines             []BeanLine                `json:"lines"`
	Transactions      []Transaction             `json:"transactions"`
	TransactionsAsc   []Transaction             `json:"-"`
	TransactionsDesc  []Transaction             `json:"-"`
	RawBalances       map[string]map[string]int `json:"-"`
	PriceIndex        PriceIndex                `json:"-"`
	AccountMap        map[string]Account        `json:"-"`
	Balances          map[string]int            `json:"balances"`
	AccountBalances   []AccountBalance          `json:"accountBalances"`
	BalanceAssertions []BalanceAssertion        `json:"balanceAssertions"`
	Budgets           []Budget                  `json:"budgets"`
	Accounts          []Account                 `json:"accounts"`
	Commodities       []string                  `json:"commodities"`
	Prices            []Price                   `json:"prices"`
	ParsedAt          int64                     `json:"parsedAt"`
}

type LedgerCache struct {
	cfg           Config
	mu            sync.Mutex
	snapshot      *LedgerSnapshot
	version       LedgerVersion
	versionReadAt time.Time
}

func NewLedgerCache(cfg Config) *LedgerCache {
	return &LedgerCache{cfg: cfg}
}

func (c *LedgerCache) Version() (LedgerVersion, error) {
	return c.currentVersion()
}

func (c *LedgerCache) Snapshot() (*LedgerSnapshot, error) {
	version, err := c.currentVersion()
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
	var wg sync.WaitGroup
	var txns []Transaction
	var accounts []Account
	var accountErr error
	var prices []Price
	var balanceAssertions []BalanceAssertion
	var budgets []Budget
	var commodities []string

	wg.Add(6)
	go func() {
		defer wg.Done()
		txns = ParseTransactions(lines)
	}()
	go func() {
		defer wg.Done()
		accounts, accountErr = ParseAccounts(c.cfg)
	}()
	go func() {
		defer wg.Done()
		prices = ParsePrices(lines)
	}()
	go func() {
		defer wg.Done()
		balanceAssertions = ParseBalances(lines)
	}()
	go func() {
		defer wg.Done()
		budgets = ParseBudgets(lines)
	}()
	go func() {
		defer wg.Done()
		commodities = ParseCommodities(lines)
	}()
	wg.Wait()
	if accountErr != nil {
		return nil, accountErr
	}
	rawBalances := CurrentBalances(txns)
	transactionsAsc, transactionsDesc := sortedTransactionViews(txns)
	priceIndex := NewPriceIndex(prices)
	accountMap := accountByName(accounts)
	snapshot := &LedgerSnapshot{
		LedgerVersion:     version,
		Lines:             lines,
		Transactions:      txns,
		TransactionsAsc:   transactionsAsc,
		TransactionsDesc:  transactionsDesc,
		RawBalances:       rawBalances,
		PriceIndex:        priceIndex,
		AccountMap:        accountMap,
		Balances:          nativeAccountBalances(rawBalances, accountMap),
		AccountBalances:   AccountBalanceRowsWithPriceIndex(rawBalances, priceIndex, ""),
		BalanceAssertions: balanceAssertions,
		Budgets:           budgets,
		Accounts:          accounts,
		Commodities:       commodities,
		Prices:            prices,
		ParsedAt:          time.Now().UnixMilli(),
	}
	c.snapshot = snapshot
	return snapshot, nil
}

func (c *LedgerCache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.snapshot = nil
	c.version = LedgerVersion{}
	c.versionReadAt = time.Time{}
}

const ledgerVersionCacheTTL = 250 * time.Millisecond

func (c *LedgerCache) currentVersion() (LedgerVersion, error) {
	c.mu.Lock()
	if c.snapshot != nil && !c.versionReadAt.IsZero() && time.Since(c.versionReadAt) < ledgerVersionCacheTTL {
		version := c.version
		c.mu.Unlock()
		return version, nil
	}
	c.mu.Unlock()

	version, err := ledgerVersion(c.cfg)
	if err != nil {
		return LedgerVersion{}, err
	}

	c.mu.Lock()
	c.version = version
	c.versionReadAt = time.Now()
	c.mu.Unlock()
	return version, nil
}

func sortedTransactionViews(txns []Transaction) ([]Transaction, []Transaction) {
	asc := append([]Transaction(nil), txns...)
	sort.Slice(asc, func(i, j int) bool {
		if asc[i].Date == asc[j].Date {
			return asc[i].Source.Line < asc[j].Source.Line
		}
		return asc[i].Date < asc[j].Date
	})
	desc := append([]Transaction(nil), txns...)
	sort.Slice(desc, func(i, j int) bool {
		if desc[i].Date == desc[j].Date {
			return desc[i].Source.Line < desc[j].Source.Line
		}
		return desc[i].Date > desc[j].Date
	})
	return asc, desc
}

func snapshotRawBalances(snapshot *LedgerSnapshot) map[string]map[string]int {
	if snapshot.RawBalances != nil {
		return snapshot.RawBalances
	}
	return CurrentBalances(snapshot.Transactions)
}

func snapshotPriceIndex(snapshot *LedgerSnapshot) PriceIndex {
	if snapshot.PriceIndex.byPair != nil {
		return snapshot.PriceIndex
	}
	return NewPriceIndex(snapshot.Prices)
}

func snapshotAccountMap(snapshot *LedgerSnapshot) map[string]Account {
	if snapshot.AccountMap != nil {
		return snapshot.AccountMap
	}
	return accountByName(snapshot.Accounts)
}

func snapshotTransactionsAsc(snapshot *LedgerSnapshot) []Transaction {
	if snapshot.TransactionsAsc != nil {
		return snapshot.TransactionsAsc
	}
	asc, _ := sortedTransactionViews(snapshot.Transactions)
	return asc
}

func snapshotTransactionsDesc(snapshot *LedgerSnapshot) []Transaction {
	if snapshot.TransactionsDesc != nil {
		return snapshot.TransactionsDesc
	}
	_, desc := sortedTransactionViews(snapshot.Transactions)
	return desc
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
