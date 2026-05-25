package app

import (
	"bytes"
	"errors"
	"fmt"
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
	cfg   Config
	cache *LedgerCache
	mu    sync.Mutex
}

type AccountInput struct {
	Date     string `json:"date"`
	Account  string `json:"account"`
	Alias    string `json:"alias"`
	Currency string `json:"currency"`
}

type LedgerEntry struct {
	Kind        string                   `json:"kind"`
	Date        string                   `json:"date"`
	Payee       string                   `json:"payee,omitempty"`
	Narration   string                   `json:"narration,omitempty"`
	Metadata    map[string]MetadataValue `json:"metadata,omitempty"`
	Tags        []string                 `json:"tags,omitempty"`
	Postings    []EntryPosting           `json:"postings,omitempty"`
	Account     string                   `json:"account,omitempty"`
	Amount      string                   `json:"amount,omitempty"`
	Currency    string                   `json:"currency"`
	Confidence  float64                  `json:"confidence,omitempty"`
	NeedsReview bool                     `json:"needsReview,omitempty"`
	Questions   []string                 `json:"questions,omitempty"`
}

type EntryPosting struct {
	Account  string `json:"account"`
	Amount   string `json:"amount"`
	Currency string `json:"currency"`
}

type fileSnapshot struct {
	existed bool
	content []byte
}

func NewLedgerWriter(cfg Config, cache *LedgerCache) *LedgerWriter {
	return &LedgerWriter{cfg: cfg, cache: cache}
}

func (w *LedgerWriter) AppendBeanText(date, beanText string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.appendItemsChecked([]appendItem{{date: date, beanText: beanText}})
}

func (w *LedgerWriter) AppendEntries(entries []LedgerEntry) ([]string, error) {
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
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.appendItemsChecked(items); err != nil {
		return nil, err
	}
	return texts, nil
}

func (w *LedgerWriter) AppendAccount(input AccountInput) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	file := accountsBeanPath(w.cfg)
	before, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	sep := "\n\n"
	if strings.HasSuffix(string(before), "\n") {
		sep = "\n"
	}
	next := string(before) + sep + strings.TrimRight(AccountToBean(input.Date, input.Account, input.Alias, input.Currency), "\n") + "\n"
	if err := os.WriteFile(file, []byte(next), 0o644); err != nil {
		return err
	}
	if err := w.validateAndClear(); err != nil {
		_ = os.WriteFile(file, before, 0o644)
		return err
	}
	return nil
}

func (w *LedgerWriter) ReplaceTransactionBlock(source TransactionSource, entry LedgerEntry, newAccounts []ImportNewAccount) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	file, err := editableLedgerFile(w.cfg, source.File)
	if err != nil {
		return err
	}
	before, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	accountsFile := accountsBeanPath(w.cfg)
	var accountsBefore []byte
	if len(newAccounts) > 0 {
		accountsBefore, err = os.ReadFile(accountsFile)
		if err != nil {
			return err
		}
		accounts, err := ParseAccounts(w.cfg)
		if err != nil {
			return err
		}
		existing := map[string]bool{}
		for _, account := range accounts {
			existing[account.Account] = true
		}
		newAccounts = usedEntryNewAccounts(entry, newAccounts, existing)
		if len(newAccounts) > 0 {
			lines := make([]string, 0, len(newAccounts))
			for _, account := range newAccounts {
				alias := account.Alias
				if alias == "" {
					alias = importAccountAlias(account.Account)
				}
				lines = append(lines, strings.TrimRight(AccountToBean(entry.Date, account.Account, alias, "CNY"), "\n"))
			}
			sep := "\n\n"
			if strings.HasSuffix(string(accountsBefore), "\n") {
				sep = "\n"
			}
			if err := os.WriteFile(accountsFile, []byte(string(accountsBefore)+sep+strings.Join(lines, "\n\n")+"\n"), 0o644); err != nil {
				return err
			}
		}
	}
	lines, start, end, err := transactionBlock(string(before), source)
	if err != nil {
		if len(accountsBefore) > 0 {
			_ = os.WriteFile(accountsFile, accountsBefore, 0o644)
		}
		return err
	}
	replacement := strings.Split(strings.TrimRight(TransactionToBean(entry), "\n"), "\n")
	nextLines := append([]string{}, lines[:start]...)
	nextLines = append(nextLines, replacement...)
	nextLines = append(nextLines, lines[end:]...)
	next := strings.TrimRight(strings.Join(nextLines, "\n"), "\n") + "\n"
	if err := os.WriteFile(file, []byte(next), 0o644); err != nil {
		if len(accountsBefore) > 0 {
			_ = os.WriteFile(accountsFile, accountsBefore, 0o644)
		}
		return err
	}
	if err := w.validateAndClear(); err != nil {
		_ = os.WriteFile(file, before, 0o644)
		if len(accountsBefore) > 0 {
			_ = os.WriteFile(accountsFile, accountsBefore, 0o644)
		}
		return err
	}
	return nil
}

func usedEntryNewAccounts(entry LedgerEntry, newAccounts []ImportNewAccount, existing map[string]bool) []ImportNewAccount {
	used := map[string]bool{}
	for _, posting := range entry.Postings {
		if !existing[posting.Account] {
			used[posting.Account] = true
		}
	}
	seen := map[string]bool{}
	out := []ImportNewAccount{}
	for _, account := range newAccounts {
		if !used[account.Account] || seen[account.Account] {
			continue
		}
		if !strings.HasPrefix(account.Account, "Expenses:") && !strings.HasPrefix(account.Account, "Income:") {
			continue
		}
		seen[account.Account] = true
		out = append(out, ImportNewAccount{Account: account.Account, Alias: strings.TrimSpace(account.Alias)})
	}
	return out
}

func (w *LedgerWriter) CommentTransactionBlock(source TransactionSource, reason string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	file, err := editableLedgerFile(w.cfg, source.File)
	if err != nil {
		return err
	}
	before, err := os.ReadFile(file)
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
	if err := os.WriteFile(file, []byte(next), 0o644); err != nil {
		return err
	}
	if err := w.validateAndClear(); err != nil {
		_ = os.WriteFile(file, before, 0o644)
		return err
	}
	return nil
}

type appendItem struct {
	date     string
	beanText string
}

func (w *LedgerWriter) appendItemsChecked(items []appendItem) error {
	snapshots := map[string]fileSnapshot{}
	snapshot := func(file string) error {
		if _, ok := snapshots[file]; ok {
			return nil
		}
		content, err := os.ReadFile(file)
		if errors.Is(err, os.ErrNotExist) {
			snapshots[file] = fileSnapshot{existed: false}
			return nil
		}
		if err != nil {
			return err
		}
		snapshots[file] = fileSnapshot{existed: true, content: content}
		return nil
	}
	restore := func() {
		for file, snap := range snapshots {
			if snap.existed {
				_ = os.MkdirAll(filepath.Dir(file), 0o755)
				_ = os.WriteFile(file, snap.content, 0o644)
			} else {
				_ = os.Remove(file)
			}
		}
	}
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
	for _, file := range files {
		fileItems := byFile[file]
		if err := w.ensureMonthlyFileAndInclude(file, fileItems[0].date, snapshot); err != nil {
			restore()
			return err
		}
		before, err := os.ReadFile(file)
		if err != nil {
			restore()
			return err
		}
		next := string(before)
		for _, item := range fileItems {
			next = appendText(next, item.beanText)
		}
		if err := os.WriteFile(file, []byte(next), 0o644); err != nil {
			restore()
			return err
		}
	}
	if err := w.validateAndClear(); err != nil {
		restore()
		return err
	}
	return nil
}

func (w *LedgerWriter) ensureMonthlyFileAndInclude(file, date string, snapshot func(string) error) error {
	main := mainBeanPath(w.cfg)
	if err := snapshot(main); err != nil {
		return err
	}
	if err := snapshot(file); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(file); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(file, []byte("; "+date[:7]+" 交易记录\n"), 0o644); err != nil {
			return err
		}
	}
	includeLine := includeLineFor(w.cfg, file)
	mainBefore, err := os.ReadFile(main)
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
	return os.WriteFile(main, []byte(string(mainBefore)+sep+includeLine+"\n"), 0o644)
}

func (w *LedgerWriter) validateAndClear() error {
	start := time.Now()
	err := runBeanCheck(w.cfg)
	logDuration("bean-check", start, map[string]any{"ok": err == nil})
	if err == nil {
		w.cache.Clear()
		publishLedgerUpdated(w.cfg, "ledger-write")
	}
	return err
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
		return "", errors.New("只能修改当前账本目录内的文件")
	}
	if _, err := os.Stat(full); err != nil {
		return "", errors.New("找不到交易来源文件")
	}
	return full, nil
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
	if start < 0 || start >= len(lines) || !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+[*!]\s+`).MatchString(lines[start]) {
		return nil, 0, 0, errors.New("交易来源行无效")
	}
	end := start + 1
	for end < len(lines) && !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+`).MatchString(lines[end]) && !strings.HasPrefix(strings.TrimSpace(lines[end]), "include ") {
		end++
	}
	return lines, start, end, nil
}

func findTransactionBlockByHash(text, hash string) ([]string, int, int, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	for start := 0; start < len(lines); start++ {
		if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+[*!]\s+`).MatchString(lines[start]) {
			continue
		}
		end := start + 1
		for end < len(lines) && !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+`).MatchString(lines[end]) && !strings.HasPrefix(strings.TrimSpace(lines[end]), "include ") {
			end++
		}
		if transactionHash(lines[start:end]) == hash {
			return lines, start, end, nil
		}
	}
	return nil, 0, 0, errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
}

func TransactionToBean(entry LedgerEntry) string {
	tagText := ""
	if len(entry.Tags) > 0 {
		tags := make([]string, len(entry.Tags))
		for i, tag := range entry.Tags {
			tags[i] = "#" + tag
		}
		tagText = " " + strings.Join(tags, " ")
	}
	lines := []string{fmt.Sprintf(`%s * "%s" "%s"%s`, entry.Date, escapeBean(entry.Payee), escapeBean(entry.Narration), tagText)}
	keys := make([]string, 0, len(entry.Metadata))
	for key := range entry.Metadata {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		lines = append(lines, fmt.Sprintf("  %s: %s", key, metadataValueToBean(entry.Metadata[key])))
	}
	for _, posting := range entry.Postings {
		lines = append(lines, fmt.Sprintf("  %-34s %12s %s", posting.Account, posting.Amount, posting.Currency))
	}
	return strings.Join(lines, "\n") + "\n"
}

func BalanceToBean(entry LedgerEntry) string {
	return fmt.Sprintf("%s balance %s %s %s\n", entry.Date, entry.Account, entry.Amount, entry.Currency)
}

func AccountToBean(date, account, alias, currency string) string {
	if currency == "" {
		currency = "CNY"
	}
	lines := []string{fmt.Sprintf("%s open %s %s", date, account, currency)}
	if strings.TrimSpace(alias) != "" {
		lines = append(lines, fmt.Sprintf(`  alias: "%s"`, escapeBean(strings.TrimSpace(alias))))
	}
	return strings.Join(lines, "\n") + "\n"
}

func escapeBean(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return value
}

func metadataValueToBean(value MetadataValue) string {
	switch typed := value.(type) {
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
