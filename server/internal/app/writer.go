package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type LedgerWriter struct {
	cfg                 Config
	cache               *LedgerCache
	runtimeStore        RuntimeStore
	indexStore          *LedgerIndexStore
	commoditiesProvider func() ([]string, error)
	logger              *slog.Logger
	mu                  sync.Mutex
}

// SetLogger attaches the process structured logger for background error
// reporting (for example index-request enqueue failures after a successful
// Git commit).
func (w *LedgerWriter) SetLogger(logger *slog.Logger) {
	w.logger = logger
}

func (w *LedgerWriter) loggerOr() *slog.Logger {
	if w != nil && w.logger != nil {
		return w.logger
	}
	return slog.Default()
}

var (
	errLedgerWriteTimeout = errors.New("ledger write timed out")
)

const defaultGitHubLedgerWriteTimeout = 50 * time.Second

type AccountInput struct {
	Date     string `json:"date"`
	Account  string `json:"account"`
	Alias    string `json:"alias"`
	Currency string `json:"currency"`
}

type AccountOperation struct {
	Kind     string `json:"kind"`
	Date     string `json:"date"`
	Account  string `json:"account"`
	Alias    string `json:"alias,omitempty"`
	Currency string `json:"currency,omitempty"`
	Group    string `json:"group,omitempty"`
}

type LedgerEntry struct {
	Kind        string                   `json:"kind"`
	Date        string                   `json:"date"`
	Flag        string                   `json:"flag,omitempty"`
	Payee       string                   `json:"payee,omitempty"`
	Narration   string                   `json:"narration,omitempty"`
	Metadata    map[string]MetadataValue `json:"metadata,omitempty"`
	Tags        []string                 `json:"tags,omitempty"`
	Links       []string                 `json:"links,omitempty"`
	Postings    []EntryPosting           `json:"postings,omitempty"`
	Account     string                   `json:"account,omitempty"`
	Amount      string                   `json:"amount,omitempty"`
	Currency    string                   `json:"currency"`
	Confidence  float64                  `json:"confidence,omitempty"`
	NeedsReview bool                     `json:"needsReview,omitempty"`
	Questions   []string                 `json:"questions,omitempty"`
}

type EntryPosting struct {
	Account       string `json:"account"`
	Flag          string `json:"flag,omitempty"`
	Amount        string `json:"amount"`
	Currency      string `json:"currency"`
	CostKind      string `json:"costKind,omitempty"`
	CostAmount    string `json:"costAmount,omitempty"`
	CostCurrency  string `json:"costCurrency,omitempty"`
	CostSpec      string `json:"costSpec,omitempty"`
	PriceKind     string `json:"priceKind,omitempty"`
	PriceAmount   string `json:"priceAmount,omitempty"`
	PriceCurrency string `json:"priceCurrency,omitempty"`
}

type fileSnapshot struct {
	existed bool
	content []byte
}

type LedgerWriteTransaction struct {
	snapshots map[string]fileSnapshot
	github    *githubLedgerTransaction
}

const (
	ledgerWriteSourceDefault             = "ledger-write"
	ledgerWriteSourceAppendText          = "ledger-append-text"
	ledgerWriteSourceAppendEntry         = "append-entry"
	ledgerWriteSourceAppendBatch         = "append-batch"
	ledgerWriteSourceAppendEntries       = "append-entries"
	ledgerWriteSourceAccountAppend       = "account-append"
	ledgerWriteSourceAccountOperations   = "account-operations"
	ledgerWriteSourceTransactionUpdate   = "transaction-update"
	ledgerWriteSourceTransactionTags     = "transaction-tags-batch"
	ledgerWriteSourceTransactionDelete   = "transaction-delete"
	ledgerWriteSourceTransactionReversal = "transaction-reversal"
	ledgerWriteSourceReconciliation      = "reconciliation"
	ledgerWriteSourceImportCommit        = "import-commit"
	ledgerWriteSourceEditorSave          = "editor-save"
)

func NewLedgerWriter(cfg Config, cache *LedgerCache) *LedgerWriter {
	return NewLedgerWriterWithRuntimeStore(cfg, cache, MustRuntimeStore(cfg))
}

func NewLedgerWriterWithRuntimeStore(cfg Config, cache *LedgerCache, runtimeStore RuntimeStore) *LedgerWriter {
	return NewLedgerWriterWithRuntimeStoreAndCommodities(cfg, cache, runtimeStore, nil)
}

func NewLedgerWriterWithRuntimeStoreAndCommodities(cfg Config, cache *LedgerCache, runtimeStore RuntimeStore, commoditiesProvider func() ([]string, error)) *LedgerWriter {
	if runtimeStore == nil {
		runtimeStore = MustRuntimeStore(cfg)
	}
	return &LedgerWriter{cfg: cfg, cache: cache, runtimeStore: runtimeStore, commoditiesProvider: commoditiesProvider}
}

func (w *LedgerWriter) SetIndexRequestStore(store *LedgerIndexStore) {
	if w != nil {
		w.indexStore = store
	}
}

func (w *LedgerWriter) SetConfig(cfg Config) {
	if w == nil {
		return
	}
	w.mu.Lock()
	w.cfg = cfg
	w.mu.Unlock()
}

func (w *LedgerWriter) RunTransaction(apply func(*LedgerWriteTransaction) error) error {
	return w.RunTransactionWithSource(ledgerWriteSourceDefault, apply)
}

func (w *LedgerWriter) RunTransactionWithSource(source string, apply func(*LedgerWriteTransaction) error) error {
	_, err := w.RunTransactionWithSourceResult(source, apply)
	return err
}

// RunTransactionWithSourceResult applies one all-or-nothing ledger write and
// returns the immutable Git commit created for it. Filesystem writers return
// an empty commit SHA. Callers that need to wait for the indexer should only
// use the SHA with GitHub API storage.
func (w *LedgerWriter) RunTransactionWithSourceResult(source string, apply func(*LedgerWriteTransaction) error) (string, error) {
	if githubAPIEnabled(w.cfg) {
		return w.runGitHubAPITransaction(source, apply)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	err := withLedgerFilesystemLock(context.Background(), w.cfg, ledgerFilesystemExclusiveLock, func() error {
		tx := &LedgerWriteTransaction{snapshots: map[string]fileSnapshot{}}
		if err := apply(tx); err != nil {
			tx.Restore()
			return err
		}
		if err := runBeanCheck(w.cfg); err != nil {
			tx.Restore()
			return err
		}
		if w.cache != nil {
			w.cache.MarkDirty()
		}
		if strings.TrimSpace(source) == "" {
			source = ledgerWriteSourceDefault
		}
		return nil
	})
	return "", err
}

func (w *LedgerWriter) runGitHubAPITransaction(source string, apply func(*LedgerWriteTransaction) error) (string, error) {
	if w.runtimeStore != nil {
		var gitSHA string
		err := w.runtimeStore.WithLock(context.Background(), "ledger:"+w.cfg.LedgerGitBranch, func(context.Context) error {
			var err error
			gitSHA, err = w.runGitHubAPITransactionLocked(source, apply)
			return err
		})
		return gitSHA, err
	}
	return w.runGitHubAPITransactionLocked(source, apply)
}

func (w *LedgerWriter) runGitHubAPITransactionLocked(source string, apply func(*LedgerWriteTransaction) error) (string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	client, err := newGitHubLedgerClient(w.cfg)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(source) == "" {
		source = ledgerWriteSourceDefault
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		attemptStarted := time.Now()
		timeout := githubLedgerWriteTimeout()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		beginStarted := time.Now()
		remoteTx, err := client.beginTransaction(ctx)
		beginElapsed := time.Since(beginStarted)
		if err != nil {
			w.logGitHubAPITransaction(source, attempt+1, attemptStarted, beginElapsed, 0, nil, err)
			cancel()
			if isContextTimeout(err) {
				return "", ledgerWriteTimeoutError(timeout, err)
			}
			return "", err
		}
		tx := &LedgerWriteTransaction{snapshots: map[string]fileSnapshot{}, github: remoteTx}
		applyStarted := time.Now()
		if err := apply(tx); err != nil {
			w.logGitHubAPITransaction(source, attempt+1, attemptStarted, beginElapsed, time.Since(applyStarted), remoteTx, err)
			cancel()
			if isContextTimeout(err) {
				return "", ledgerWriteTimeoutError(timeout, err)
			}
			return "", err
		}
		applyElapsed := time.Since(applyStarted)
		gitSHA, err := remoteTx.commit(ledgerCommitMessage(source))
		if err != nil {
			w.logGitHubAPITransaction(source, attempt+1, attemptStarted, beginElapsed, applyElapsed, remoteTx, err)
			cancel()
			if isContextTimeout(err) {
				return "", ledgerWriteTimeoutError(timeout, err)
			}
			lastErr = err
			continue
		}
		w.logGitHubAPITransaction(source, attempt+1, attemptStarted, beginElapsed, applyElapsed, remoteTx, nil)
		cancel()
		if w.cfg.LedgerIndexNotifyEnabled && gitSHA != "" {
			if err := w.enqueueLedgerIndexRequest(context.Background(), gitSHA); err != nil {
				// The Git commit has already succeeded. Polling remains a safe
				// fallback, so do not turn a committed financial write into an
				// apparent client-side failure.
				w.loggerOr().Warn("queue ledger index request", "sha", gitSHA, "error", err)
			}
		}
		if w.cache != nil {
			w.cache.MarkDirty()
		}
		return gitSHA, nil
	}
	if lastErr == nil {
		lastErr = errors.New("github api ledger write failed")
	}
	return "", lastErr
}

func (w *LedgerWriter) logGitHubAPITransaction(source string, attempt int, started time.Time, beginElapsed, applyElapsed time.Duration, tx *githubLedgerTransaction, writeErr error) {
	metrics := githubLedgerTransactionMetrics{}
	writtenFiles := 0
	if tx != nil {
		metrics = tx.metricsSnapshot()
		writtenFiles = len(tx.writes)
	}
	attrs := []slog.Attr{
		slog.String("source", source),
		slog.Int("attempt", attempt),
		slog.Duration("total_elapsed", time.Since(started)),
		slog.Duration("begin_elapsed", beginElapsed),
		slog.Duration("read_api_elapsed_sum", metrics.readElapsed),
		slog.Int("read_requests", metrics.readRequests),
		slog.Duration("apply_elapsed", applyElapsed),
		slog.Duration("blob_elapsed", metrics.blobElapsed),
		slog.Int("blob_requests", metrics.blobRequests),
		slog.Duration("tree_elapsed", metrics.treeElapsed),
		slog.Duration("commit_elapsed", metrics.commitElapsed),
		slog.Duration("ref_elapsed", metrics.refElapsed),
		slog.Int("written_files", writtenFiles),
	}
	level := slog.LevelInfo
	if writeErr != nil {
		level = slog.LevelWarn
		attrs = append(attrs, slog.Any("error", writeErr))
	}
	w.loggerOr().LogAttrs(context.Background(), level, "github ledger write", attrs...)
}

func (w *LedgerWriter) enqueueLedgerIndexRequest(ctx context.Context, gitSHA string) error {
	if w.indexStore == nil {
		return errors.New("ledger index request store is unavailable")
	}
	return w.indexStore.EnqueueRequest(ctx, gitSHA)
}

func githubLedgerWriteTimeout() time.Duration {
	raw := strings.TrimSpace(os.Getenv("LEDGER_GITHUB_WRITE_TIMEOUT"))
	if raw == "" {
		return defaultGitHubLedgerWriteTimeout
	}
	if timeout, err := time.ParseDuration(raw); err == nil && timeout > 0 {
		return timeout
	}
	if timeout, err := time.ParseDuration(raw + "s"); err == nil && timeout > 0 {
		return timeout
	}
	return defaultGitHubLedgerWriteTimeout
}

func isContextTimeout(err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)
}

func ledgerWriteTimeoutError(timeout time.Duration, err error) error {
	return fmt.Errorf("%w: GitHub 写入超过 %s，请稍后重试；如果经常发生，可调大 LEDGER_GITHUB_WRITE_TIMEOUT 或改用异步写入: %v", errLedgerWriteTimeout, timeout.Round(time.Second), err)
}

func (tx *LedgerWriteTransaction) Snapshot(file string) error {
	if _, ok := tx.snapshots[file]; ok {
		return nil
	}
	if tx.github != nil {
		if err := tx.github.snapshot(file); err != nil {
			return err
		}
		tx.snapshots[file] = fileSnapshot{existed: true}
		return nil
	}
	content, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		tx.snapshots[file] = fileSnapshot{existed: false}
		return nil
	}
	if err != nil {
		return err
	}
	tx.snapshots[file] = fileSnapshot{existed: true, content: content}
	return nil
}

func (tx *LedgerWriteTransaction) ReadFile(file string) ([]byte, error) {
	if tx.github != nil {
		return tx.github.readFile(file)
	}
	return os.ReadFile(file)
}

func (tx *LedgerWriteTransaction) PrefetchFiles(files []string) error {
	if tx.github == nil {
		return nil
	}
	return tx.github.prefetch(files)
}

func (tx *LedgerWriteTransaction) ReadLedgerLines(entry string, seen map[string]bool) ([]BeanLine, error) {
	full, err := filepath.Abs(entry)
	if err != nil {
		return nil, err
	}
	if seen[full] {
		return nil, nil
	}
	seen[full] = true
	text, err := tx.ReadFile(full)
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(full)
	var out []BeanLine
	for i, line := range strings.Split(string(text), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if m := includeRe.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			out = append(out, BeanLine{File: full, Line: i + 1, Text: line})
			lines, err := tx.ReadLedgerLines(filepath.Join(dir, m[1]), seen)
			if err != nil {
				return nil, err
			}
			out = append(out, lines...)
			continue
		}
		out = append(out, BeanLine{File: full, Line: i + 1, Text: line})
	}
	return out, nil
}

func (tx *LedgerWriteTransaction) Exists(file string) (bool, error) {
	if tx.github != nil {
		return tx.github.exists(file)
	}
	if _, err := os.Stat(file); errors.Is(err, os.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	return true, nil
}

func (tx *LedgerWriteTransaction) UniquePath(file string) (string, error) {
	if tx.github != nil {
		return tx.github.uniquePath(file)
	}
	return uniquePath(file), nil
}

func (tx *LedgerWriteTransaction) WriteFile(file string, content []byte, perm os.FileMode) error {
	if err := tx.Snapshot(file); err != nil {
		return err
	}
	if tx.github != nil {
		return tx.github.writeFile(file, content)
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	return os.WriteFile(file, content, perm)
}

func (tx *LedgerWriteTransaction) CopyFile(source, dest string, perm os.FileMode) error {
	content, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return tx.WriteFile(dest, content, perm)
}

func (tx *LedgerWriteTransaction) Restore() {
	files := make([]string, 0, len(tx.snapshots))
	for file := range tx.snapshots {
		files = append(files, file)
	}
	sort.Strings(files)
	for i := len(files) - 1; i >= 0; i-- {
		file := files[i]
		snap := tx.snapshots[file]
		if snap.existed {
			_ = os.MkdirAll(filepath.Dir(file), 0o755)
			_ = os.WriteFile(file, snap.content, 0o644)
		} else {
			_ = os.Remove(file)
		}
	}
}

func (w *LedgerWriter) AppendBeanText(date, beanText string) error {
	return w.AppendBeanTextWithSource(date, beanText, ledgerWriteSourceAppendText)
}

func (w *LedgerWriter) AppendBeanTextWithSource(date, beanText, source string) error {
	return w.appendItemsChecked(source, []appendItem{{date: date, beanText: beanText}}, nil)
}

func (w *LedgerWriter) AppendEntries(entries []LedgerEntry) ([]string, error) {
	return w.AppendEntriesWithSource(ledgerWriteSourceAppendEntries, entries)
}

func (w *LedgerWriter) AppendEntriesWithSource(source string, entries []LedgerEntry) ([]string, error) {
	items := make([]appendItem, 0, len(entries))
	texts := make([]string, 0, len(entries))
	for _, entry := range entries {
		var text string
		if entry.Kind == "transaction" {
			text = TransactionToBean(entry)
		} else if entry.Kind == "balance" {
			text = BalanceToBean(entry)
		} else {
			return nil, fmt.Errorf("unsupported ledger entry kind: %s", entry.Kind)
		}
		items = append(items, appendItem{date: entry.Date, beanText: text})
		texts = append(texts, text)
	}
	if err := w.appendItemsChecked(source, items, func(tx *LedgerWriteTransaction) error {
		return w.validateEntryCommodities(tx, entries)
	}); err != nil {
		return nil, err
	}
	return texts, nil
}

func (w *LedgerWriter) AppendAccount(input AccountInput) error {
	input.Currency = defaultAccountCurrency(input.Account, input.Currency)
	return w.RunTransactionWithSource(ledgerWriteSourceAccountAppend, func(tx *LedgerWriteTransaction) error {
		if err := w.validateCurrencies(tx, []string{input.Currency}); err != nil {
			return err
		}
		file := accountsBeanPath(w.cfg)
		before, err := tx.ReadFile(file)
		if err != nil {
			return err
		}
		sep := "\n\n"
		if strings.HasSuffix(string(before), "\n") {
			sep = "\n"
		}
		next := string(before) + sep + strings.TrimRight(AccountToBean(input.Date, input.Account, input.Alias, input.Currency), "\n") + "\n"
		return tx.WriteFile(file, []byte(next), 0o644)
	})
}

func (w *LedgerWriter) ApplyAccountOperations(operations []AccountOperation) ([]string, error) {
	normalized := append([]AccountOperation(nil), operations...)
	currencies := []string{}
	for i := range normalized {
		if normalized[i].Kind == "create" {
			normalized[i].Currency = defaultAccountCurrency(normalized[i].Account, normalized[i].Currency)
		}
		operation := normalized[i]
		if operation.Currency != "" {
			currencies = append(currencies, operation.Currency)
		}
	}
	texts := []string{}
	if err := w.RunTransactionWithSource(ledgerWriteSourceAccountOperations, func(tx *LedgerWriteTransaction) error {
		if err := w.validateCurrencies(tx, currencies); err != nil {
			return err
		}
		file := accountsBeanPath(w.cfg)
		before, err := tx.ReadFile(file)
		if err != nil {
			return err
		}
		accounts, err := w.knownAccounts(tx)
		if err != nil {
			return err
		}
		if err := validateAccountOperations(normalized, accounts); err != nil {
			return err
		}
		next := string(before)
		texts = []string{}
		for _, operation := range normalized {
			var text string
			switch operation.Kind {
			case "create":
				text = AccountToBeanWithMetadata(operation.Date, operation.Account, operation.Alias, operation.Currency, accountOperationMetadata(operation))
				next = appendText(next, text)
			case "update":
				var updated string
				updated, err = updateAccountMetadata(next, operation)
				if err != nil {
					return err
				}
				next = updated
				text = operationSummary(operation)
			case "disable":
				text = fmt.Sprintf("%s close %s\n", operation.Date, operation.Account)
				next = appendText(next, text)
			}
			texts = append(texts, text)
		}
		return tx.WriteFile(file, []byte(next), 0o644)
	}); err != nil {
		return nil, err
	}
	return texts, nil
}

func (w *LedgerWriter) ReplaceTransactionBlock(source TransactionSource, entry LedgerEntry) error {
	return w.RunTransactionWithSource(ledgerWriteSourceTransactionUpdate, func(tx *LedgerWriteTransaction) error {
		if err := tx.validateTransactionSource(source); err != nil {
			return err
		}
		if err := w.validateEntryCommodities(tx, []LedgerEntry{entry}); err != nil {
			return err
		}
		file, err := editableLedgerFile(w.cfg, source.File)
		if err != nil {
			return err
		}
		before, err := tx.ReadFile(file)
		if err != nil {
			return err
		}
		lines, start, end, err := transactionBlock(string(before), source)
		if err != nil {
			return err
		}
		replacement := strings.Split(strings.TrimRight(TransactionToBean(entry), "\n"), "\n")
		nextLines := append([]string{}, lines[:start]...)
		nextLines = append(nextLines, replacement...)
		nextLines = append(nextLines, lines[end:]...)
		next := strings.TrimRight(strings.Join(nextLines, "\n"), "\n") + "\n"
		return tx.WriteFile(file, []byte(next), 0o644)
	})
}

func normalizeTransactionTags(tags []string) []string {
	seen := map[string]bool{}
	normalized := make([]string, 0, len(tags))
	for _, tag := range tags {
		tag = strings.TrimPrefix(strings.TrimSpace(tag), "#")
		if tag == "" || seen[tag] {
			continue
		}
		seen[tag] = true
		normalized = append(normalized, tag)
	}
	return normalized
}

func (w *LedgerWriter) addTransactionTagsFromSnapshot(sources []TransactionSource, tags []string, snapshot *LedgerSnapshot) error {
	effectiveTags, err := transactionEffectiveTagsFromSnapshot(w.cfg, snapshot)
	if err != nil {
		return err
	}
	return w.addTransactionTags(sources, tags, effectiveTags)
}

func (w *LedgerWriter) addTransactionTags(sources []TransactionSource, tags []string, effectiveTags map[transactionTagIdentity][]string) error {
	tags = normalizeTransactionTags(tags)
	if len(tags) == 0 {
		return errors.New("至少需要一个标签")
	}
	byFile := map[string][]TransactionSource{}
	type sourceIdentity struct {
		file string
		line int
		hash string
	}
	seen := map[sourceIdentity]bool{}
	for _, source := range sources {
		if strings.TrimSpace(source.Hash) == "" {
			return errors.New("批量打标签需要交易哈希，请刷新后重试")
		}
		file, err := editableLedgerFile(w.cfg, source.File)
		if err != nil {
			return err
		}
		key := sourceIdentity{file: file, line: source.Line, hash: source.Hash}
		if seen[key] {
			continue
		}
		seen[key] = true
		byFile[file] = append(byFile[file], source)
	}
	files := make([]string, 0, len(byFile))
	for file := range byFile {
		files = append(files, file)
	}
	sort.Strings(files)
	return w.RunTransactionWithSource(ledgerWriteSourceTransactionTags, func(tx *LedgerWriteTransaction) error {
		if err := tx.PrefetchFiles(files); err != nil {
			return err
		}
		for _, file := range files {
			before, err := tx.ReadFile(file)
			if err != nil {
				return err
			}
			lines := strings.Split(strings.ReplaceAll(string(before), "\r\n", "\n"), "\n")
			headerIndexes := make([]int, 0, len(byFile[file]))
			for _, source := range byFile[file] {
				blockLines, start, end, err := transactionBlock(string(before), source)
				if err != nil {
					return err
				}
				identity := transactionTagIdentity{
					file: filepath.Clean(file),
					line: start + 1,
					hash: transactionHash(blockLines[start:end]),
				}
				current, ok := effectiveTags[identity]
				if !ok {
					return errors.New("无法读取交易的完整标签，请刷新后重试")
				}
				if err := validateFinalTransactionTags(current, tags); err != nil {
					return err
				}
				headerIndexes = append(headerIndexes, start)
			}
			for _, index := range headerIndexes {
				updated, err := addTagsToTransactionHeader(lines[index], tags)
				if err != nil {
					return err
				}
				lines[index] = updated
			}
			next := strings.TrimRight(strings.Join(lines, "\n"), "\n") + "\n"
			if err := tx.WriteFile(file, []byte(next), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
}

type transactionTagIdentity struct {
	file string
	line int
	hash string
}

func transactionEffectiveTagsFromSnapshot(cfg Config, snapshot *LedgerSnapshot) (map[transactionTagIdentity][]string, error) {
	if snapshot == nil {
		return nil, errors.New("ledger snapshot is unavailable")
	}
	result := make(map[transactionTagIdentity][]string, len(snapshot.Transactions))
	for _, transaction := range snapshot.Transactions {
		file, err := editableLedgerFile(cfg, transaction.Source.File)
		if err != nil {
			return nil, err
		}
		result[transactionTagIdentity{
			file: filepath.Clean(file),
			line: transaction.Source.Line,
			hash: transaction.Source.Hash,
		}] = normalizeTransactionTags(transaction.Tags)
	}
	return result, nil
}

func validateFinalTransactionTags(existing, added []string) error {
	final := map[string]bool{}
	for _, tag := range normalizeTransactionTags(existing) {
		final[tag] = true
	}
	for _, tag := range normalizeTransactionTags(added) {
		final[tag] = true
	}
	if len(final) > maxTransactionTags {
		return fmt.Errorf("交易标签最多 %d 个", maxTransactionTags)
	}
	return nil
}

func addTagsToTransactionHeader(header string, tags []string) (string, error) {
	commentAt := len(header)
	inQuote, escaped := false, false
	for index, char := range header {
		if escaped {
			escaped = false
			continue
		}
		if inQuote && char == '\\' {
			escaped = true
			continue
		}
		if char == '"' {
			inQuote = !inQuote
			continue
		}
		if char == ';' && !inQuote {
			commentAt = index
			break
		}
	}
	code, comment := header[:commentAt], header[commentAt:]
	existing := map[string]bool{}
	inQuote, escaped = false, false
	var outside strings.Builder
	for _, char := range code {
		if escaped {
			escaped = false
			continue
		}
		if inQuote && char == '\\' {
			escaped = true
			continue
		}
		if char == '"' {
			inQuote = !inQuote
			outside.WriteRune(' ')
			continue
		}
		if inQuote {
			outside.WriteRune(' ')
		} else {
			outside.WriteRune(char)
		}
	}
	for _, field := range strings.Fields(outside.String()) {
		if strings.HasPrefix(field, "#") {
			tag := strings.TrimPrefix(field, "#")
			if tag != "" {
				existing[tag] = true
			}
		}
	}
	missing := make([]string, 0, len(tags))
	for _, tag := range tags {
		if !existing[tag] {
			missing = append(missing, tag)
		}
	}
	if len(missing) == 0 {
		return header, nil
	}
	if len(existing)+len(missing) > maxTransactionTags {
		return "", fmt.Errorf("交易标签最多 %d 个", maxTransactionTags)
	}
	trailing := code[len(strings.TrimRight(code, " \t")):]
	code = strings.TrimRight(code, " \t") + " #" + strings.Join(missing, " #") + trailing
	return code + comment, nil
}

func (w *LedgerWriter) validateEntryCommodities(tx *LedgerWriteTransaction, entries []LedgerEntry) error {
	currencies := []string{}
	for _, entry := range entries {
		if entry.Kind == "balance" {
			currencies = append(currencies, entry.Currency)
		}
		for _, posting := range entry.Postings {
			currencies = append(currencies, posting.Currency)
		}
	}
	return w.validateCurrencies(tx, currencies)
}

func (w *LedgerWriter) validateCurrencies(tx *LedgerWriteTransaction, currencies []string) error {
	if len(currencies) == 0 {
		return nil
	}
	commodities, err := w.knownCommodities(tx)
	if err != nil {
		return err
	}
	for _, currency := range currencies {
		if strings.TrimSpace(currency) == "" {
			continue
		}
		if err := validateKnownCurrency("currency", currency, commodities); err != nil {
			return err
		}
	}
	return nil
}

func (w *LedgerWriter) knownCommodities(tx *LedgerWriteTransaction) ([]string, error) {
	if w.commoditiesProvider != nil {
		commodities, err := w.commoditiesProvider()
		if err != nil {
			return nil, err
		}
		if len(commodities) > 0 {
			return commodities, nil
		}
	}
	lines, err := tx.ReadLedgerLines(mainBeanPath(w.cfg), map[string]bool{})
	if err != nil {
		return nil, err
	}
	return CommoditiesFromBeanEntries(ParseBeanLines(lines).Entries), nil
}

func (w *LedgerWriter) knownAccounts(tx *LedgerWriteTransaction) ([]Account, error) {
	lines, err := tx.ReadLedgerLines(mainBeanPath(w.cfg), map[string]bool{})
	if err != nil {
		return nil, err
	}
	return AccountsFromBeanEntries(ParseBeanLines(lines).Entries), nil
}

func (w *LedgerWriter) CommentTransactionBlock(source TransactionSource, reason string) error {
	return w.RunTransactionWithSource(ledgerWriteSourceTransactionDelete, func(tx *LedgerWriteTransaction) error {
		if err := tx.validateTransactionSource(source); err != nil {
			return err
		}
		file, err := editableLedgerFile(w.cfg, source.File)
		if err != nil {
			return err
		}
		before, err := tx.ReadFile(file)
		if err != nil {
			return err
		}
		lines, start, end, err := transactionBlock(string(before), source)
		if err != nil {
			return err
		}
		note := ""
		if strings.TrimSpace(reason) != "" {
			note = ": " + escapeBean(strings.TrimSpace(reason))
		}
		commented := []string{"; deleted " + time.Now().Format("2006-01-02") + note}
		for _, line := range lines[start:end] {
			commented = append(commented, "; "+line)
		}
		nextLines := append([]string{}, lines[:start]...)
		nextLines = append(nextLines, commented...)
		nextLines = append(nextLines, lines[end:]...)
		next := strings.TrimRight(strings.Join(nextLines, "\n"), "\n") + "\n"
		return tx.WriteFile(file, []byte(next), 0o644)
	})
}

func (tx *LedgerWriteTransaction) validateTransactionSource(source TransactionSource) error {
	if source.Line <= 0 && strings.TrimSpace(source.Hash) == "" {
		return errors.New("交易来源缺少定位信息，请刷新后重试")
	}
	return nil
}

type appendItem struct {
	date     string
	beanText string
}

func (w *LedgerWriter) appendItemsChecked(source string, items []appendItem, validate func(*LedgerWriteTransaction) error) error {
	byFile := map[string][]appendItem{}
	for _, item := range items {
		file := transactionFileForDate(w.cfg, item.date)
		byFile[file] = append(byFile[file], item)
	}
	files := make([]string, 0, len(byFile))
	for file := range byFile {
		files = append(files, file)
	}
	sort.Strings(files)
	return w.RunTransactionWithSource(source, func(tx *LedgerWriteTransaction) error {
		if validate != nil {
			if err := validate(tx); err != nil {
				return err
			}
		}
		for _, file := range files {
			fileItems := byFile[file]
			if err := w.ensureMonthlyFileAndInclude(tx, file, fileItems[0].date); err != nil {
				return err
			}
			before, err := tx.ReadFile(file)
			if err != nil {
				return err
			}
			next := string(before)
			for _, item := range fileItems {
				next = appendText(next, item.beanText)
			}
			if err := tx.WriteFile(file, []byte(next), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
}

func (w *LedgerWriter) ensureMonthlyFileAndInclude(tx *LedgerWriteTransaction, file, date string) error {
	main := mainBeanPath(w.cfg)
	if err := tx.Snapshot(main); err != nil {
		return err
	}
	if err := tx.Snapshot(file); err != nil {
		return err
	}
	if tx.github == nil {
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			return err
		}
	}
	exists, err := tx.Exists(file)
	if err != nil {
		return err
	}
	if !exists {
		if err := tx.WriteFile(file, []byte("; "+date[:7]+" 交易记录\n"), 0o644); err != nil {
			return err
		}
	}
	includeLine := includeLineFor(w.cfg, file)
	mainBefore, err := tx.ReadFile(main)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(mainBefore), "\n") {
		if strings.TrimSpace(line) == includeLine {
			return nil
		}
	}
	sep := ""
	if !strings.HasSuffix(string(mainBefore), "\n") {
		sep = "\n"
	}
	return tx.WriteFile(main, []byte(string(mainBefore)+sep+includeLine+"\n"), 0o644)
}

func ledgerCommitMessage(source string) string {
	source = strings.TrimSpace(source)
	if source == "" {
		return "chore: update ledger"
	}
	return "chore: update ledger (" + source + ")"
}

func (w *LedgerWriter) ReplaceLedgerFile(file string, content []byte) error {
	return w.RunTransactionWithSource(ledgerWriteSourceEditorSave, func(tx *LedgerWriteTransaction) error {
		return tx.WriteFile(file, content, 0o644)
	})
}

func includeLineFor(cfg Config, file string) string {
	rel, _ := filepath.Rel(filepath.Dir(mainBeanPath(cfg)), file)
	return `include "` + filepath.ToSlash(rel) + `"`
}

func appendText(before, beanText string) string {
	trimmed := strings.TrimRight(beanText, "\n")
	if strings.TrimSpace(trimmed) == "" {
		return before
	}
	sep := "\n\n"
	if before == "" {
		sep = ""
	} else if strings.HasSuffix(before, "\n") {
		sep = "\n"
	}
	return before + sep + trimmed + "\n"
}

func runBeanCheck(cfg Config) error {
	cmd := env("BEAN_CHECK_BIN", "bean-check")
	command := exec.Command(cmd, mainBeanPath(cfg))
	command.Dir = filepath.Dir(mainBeanPath(cfg))
	var stderr bytes.Buffer
	command.Stderr = &stderr
	command.Stdout = &stderr
	if err := command.Run(); err != nil {
		if stderr.Len() > 0 {
			return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
		}
		return err
	}
	return nil
}

func editableLedgerFile(cfg Config, file string) (string, error) {
	if !filepath.IsAbs(file) {
		file = filepath.Join(cfg.LedgerRoot, filepath.FromSlash(file))
	}
	full, err := filepath.Abs(file)
	if err != nil {
		return "", err
	}
	root, err := filepath.Abs(filepath.Dir(mainBeanPath(cfg)))
	if err != nil {
		return "", err
	}
	main, _ := filepath.Abs(mainBeanPath(cfg))
	if full != main && !strings.HasPrefix(full, root+string(filepath.Separator)) {
		if githubAPIEnabled(cfg) {
			if migrated, ok := legacyGitHubTransactionSourcePath(cfg, full); ok {
				return migrated, nil
			}
		}
		return "", errors.New("只能修改当前账本目录内的文件")
	}
	if githubAPIEnabled(cfg) {
		return full, nil
	}
	if _, err := os.Stat(full); err != nil {
		return "", errors.New("找不到交易来源文件")
	}
	return full, nil
}

func legacyGitHubTransactionSourcePath(cfg Config, file string) (string, bool) {
	path := filepath.ToSlash(filepath.Clean(file))
	marker := "/transactions/"
	index := strings.LastIndex(path, marker)
	if index < 0 {
		return "", false
	}
	relative := strings.TrimPrefix(path[index+1:], "/")
	if relative == "transactions" || !strings.HasSuffix(relative, ".bean") {
		return "", false
	}
	return filepath.Join(cfg.LedgerRoot, filepath.FromSlash(relative)), true
}

func transactionBlock(text string, source TransactionSource) ([]string, int, int, error) {
	if source.Line > 0 {
		lines, start, end, err := transactionBlockAtLine(text, source.Line)
		if err == nil && (source.Hash == "" || transactionHash(lines[start:end]) == source.Hash) {
			return lines, start, end, nil
		}
		if source.Hash == "" {
			return nil, 0, 0, err
		}
	}
	if source.Hash != "" {
		return findTransactionBlockByHash(text, source.Hash)
	}
	return nil, 0, 0, errors.New("交易来源行无效")
}

func transactionBlockAtLine(text string, line int) ([]string, int, int, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	start := line - 1
	if start < 0 || start >= len(lines) || !isTransactionHeaderLine(lines[start]) {
		return nil, 0, 0, errors.New("交易来源行无效")
	}
	end := start + 1
	for end < len(lines) && !isDatedBeanDirectiveLine(lines[end]) && !strings.HasPrefix(strings.TrimSpace(lines[end]), "include ") {
		end++
	}
	return lines, start, end, nil
}

func findTransactionBlockByHash(text, hash string) ([]string, int, int, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	matchStart, matchEnd := -1, -1
	for start := 0; start < len(lines); start++ {
		if !isTransactionHeaderLine(lines[start]) {
			continue
		}
		end := start + 1
		for end < len(lines) && !isDatedBeanDirectiveLine(lines[end]) && !strings.HasPrefix(strings.TrimSpace(lines[end]), "include ") {
			end++
		}
		if transactionHash(lines[start:end]) == hash {
			if matchStart >= 0 {
				return nil, 0, 0, errors.New("交易来源不唯一，账本可能已被修改，请刷新后重试")
			}
			matchStart, matchEnd = start, end
		}
	}
	if matchStart >= 0 {
		return lines, matchStart, matchEnd, nil
	}
	return nil, 0, 0, errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
}

func isTransactionHeaderLine(line string) bool {
	if strings.TrimSpace(line) == "" || isIndentedBeanLine(line) {
		return false
	}
	tokens := scanBeanLine(line)
	return len(tokens) >= 2 && isBeanDateToken(tokens[0].Value) && isTransactionFlag(tokens[1].Value)
}

func isDatedBeanDirectiveLine(line string) bool {
	if strings.TrimSpace(line) == "" || isIndentedBeanLine(line) {
		return false
	}
	tokens := scanBeanLine(line)
	return len(tokens) >= 2 && isBeanDateToken(tokens[0].Value)
}

func TransactionToBean(entry LedgerEntry) string {
	annotationText := ""
	if len(entry.Tags) > 0 {
		tags := make([]string, len(entry.Tags))
		for i, tag := range entry.Tags {
			tags[i] = "#" + tag
		}
		annotationText = " " + strings.Join(tags, " ")
	}
	if len(entry.Links) > 0 {
		links := make([]string, len(entry.Links))
		for i, link := range entry.Links {
			links[i] = "^" + link
		}
		annotationText += " " + strings.Join(links, " ")
	}
	flag := strings.TrimSpace(entry.Flag)
	if flag == "" {
		flag = "*"
	}
	lines := []string{fmt.Sprintf(`%s %s "%s" "%s"%s`, entry.Date, flag, escapeBean(entry.Payee), escapeBean(entry.Narration), annotationText)}
	keys := make([]string, 0, len(entry.Metadata))
	for key := range entry.Metadata {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		lines = append(lines, fmt.Sprintf("  %s: %s", key, metadataValueToBean(entry.Metadata[key])))
	}
	for _, posting := range entry.Postings {
		lines = append(lines, renderEntryPosting(posting))
	}
	return strings.Join(lines, "\n") + "\n"
}

func renderEntryPosting(posting EntryPosting) string {
	prefix := "  "
	if posting.Flag != "" {
		prefix += posting.Flag + " "
	}
	line := prefix + posting.Account
	if posting.Amount != "" || posting.Currency != "" {
		currency := posting.Currency
		if currency == "" {
			currency = "CNY"
		}
		line = fmt.Sprintf("%-36s %12s %s", prefix+posting.Account, posting.Amount, currency)
	}
	if posting.CostSpec != "" {
		line += " " + posting.CostSpec
	} else if posting.CostAmount != "" && posting.CostCurrency != "" {
		open, close := "{", "}"
		if posting.CostKind == "total" {
			open, close = "{{", "}}"
		}
		line += fmt.Sprintf(" %s %s %s %s", open, posting.CostAmount, posting.CostCurrency, close)
	}
	if posting.PriceAmount != "" && posting.PriceCurrency != "" {
		operator := "@"
		if posting.PriceKind == "total" {
			operator = "@@"
		}
		line += fmt.Sprintf(" %s %s %s", operator, posting.PriceAmount, posting.PriceCurrency)
	}
	return line
}

func BalanceToBean(entry LedgerEntry) string {
	return fmt.Sprintf("%s balance %s %s %s\n", entry.Date, entry.Account, entry.Amount, entry.Currency)
}

func AccountToBean(date, account, alias, currency string) string {
	return AccountToBeanWithMetadata(date, account, alias, currency, nil)
}

func AccountToBeanWithMetadata(date, account, alias, currency string, metadata map[string]MetadataValue) string {
	currency = defaultAccountCurrency(account, currency)
	openLine := fmt.Sprintf("%s open %s", date, account)
	if strings.TrimSpace(currency) != "" {
		openLine += " " + strings.TrimSpace(currency)
	}
	lines := []string{openLine}
	if strings.TrimSpace(alias) != "" {
		lines = append(lines, fmt.Sprintf(`  alias: "%s"`, escapeBean(strings.TrimSpace(alias))))
	}
	keys := make([]string, 0, len(metadata))
	for key := range metadata {
		if key != "alias" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		lines = append(lines, fmt.Sprintf("  %s: %s", key, metadataValueToBean(metadata[key])))
	}
	return strings.Join(lines, "\n") + "\n"
}

func accountOperationMetadata(operation AccountOperation) map[string]MetadataValue {
	metadata := map[string]MetadataValue{}
	if group := normalizeGroup(operation.Group); group != "" {
		metadata["group"] = group
	}
	return metadata
}

func validateAccountOperations(operations []AccountOperation, accounts []Account) error {
	known := map[string]Account{}
	for _, account := range accounts {
		known[account.Account] = account
	}
	for i, operation := range operations {
		if err := operation.Validate(); err != nil {
			return fmt.Errorf("operation %d: %w", i+1, err)
		}
		switch operation.Kind {
		case "create":
			if _, exists := known[operation.Account]; exists {
				return fmt.Errorf("operation %d: account already exists: %s", i+1, operation.Account)
			}
			known[operation.Account] = Account{Account: operation.Account, Active: true}
		case "update":
			if _, exists := known[operation.Account]; !exists {
				return fmt.Errorf("operation %d: account does not exist: %s", i+1, operation.Account)
			}
		case "disable":
			account, exists := known[operation.Account]
			if !exists {
				return fmt.Errorf("operation %d: account does not exist: %s", i+1, operation.Account)
			}
			if !account.Active {
				return fmt.Errorf("operation %d: account is already closed: %s", i+1, operation.Account)
			}
			account.Active = false
			known[operation.Account] = account
		}
	}
	return nil
}

func updateAccountMetadata(text string, operation AccountOperation) (string, error) {
	lines, start, end, err := accountBlock(text, operation.Account)
	if err != nil {
		return "", err
	}
	block := append([]string{}, lines[start:end]...)
	if strings.TrimSpace(operation.Alias) != "" {
		block = setMetadataLine(block, "alias", metadataValueToBean(strings.TrimSpace(operation.Alias)))
	}
	if group := normalizeGroup(operation.Group); group != "" {
		block = setMetadataLine(block, "group", metadataValueToBean(group))
	}
	nextLines := append([]string{}, lines[:start]...)
	nextLines = append(nextLines, block...)
	nextLines = append(nextLines, lines[end:]...)
	return strings.TrimRight(strings.Join(nextLines, "\n"), "\n") + "\n", nil
}

func accountBlock(text, account string) ([]string, int, int, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	openPattern := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+open\s+` + regexp.QuoteMeta(account) + `(?:\s|$)`)
	directivePattern := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+`)
	for start, line := range lines {
		if !openPattern.MatchString(line) {
			continue
		}
		end := start + 1
		for end < len(lines) && strings.TrimSpace(lines[end]) != "" && (strings.HasPrefix(lines[end], " ") || strings.HasPrefix(strings.TrimSpace(lines[end]), ";")) && !directivePattern.MatchString(lines[end]) {
			end++
		}
		return lines, start, end, nil
	}
	return nil, 0, 0, fmt.Errorf("找不到账本中的账户定义：%s", account)
}

func setMetadataLine(block []string, key, value string) []string {
	pattern := regexp.MustCompile(`^\s+` + regexp.QuoteMeta(key) + `:\s+`)
	line := fmt.Sprintf("  %s: %s", key, value)
	for i := range block {
		if pattern.MatchString(block[i]) {
			block[i] = line
			return block
		}
	}
	return append(block, line)
}

func operationSummary(operation AccountOperation) string {
	parts := []string{operation.Kind, operation.Account}
	if strings.TrimSpace(operation.Alias) != "" {
		parts = append(parts, "alias="+strings.TrimSpace(operation.Alias))
	}
	if group := normalizeGroup(operation.Group); group != "" {
		parts = append(parts, "group="+group)
	}
	return strings.Join(parts, " ") + "\n"
}

func escapeBean(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	value = strings.ReplaceAll(value, "\n", `\n`)
	value = strings.ReplaceAll(value, "\t", `\t`)
	value = strings.ReplaceAll(value, "\r", `\r`)
	value = strings.ReplaceAll(value, "\b", `\b`)
	value = strings.ReplaceAll(value, "\f", `\f`)
	return value
}

func metadataValueToBean(value MetadataValue) string {
	switch typed := value.(type) {
	case nil:
		return "NULL"
	case bool:
		if typed {
			return "TRUE"
		}
		return "FALSE"
	case float64:
		return strconvFormatFloat(typed)
	case int:
		return fmt.Sprint(typed)
	case string:
		return `"` + escapeBean(typed) + `"`
	default:
		return `"` + escapeBean(fmt.Sprint(value)) + `"`
	}
}

func strconvFormatFloat(value float64) string {
	text := fmt.Sprintf("%f", value)
	text = strings.TrimRight(text, "0")
	return strings.TrimRight(text, ".")
}
