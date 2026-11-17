package app

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Deterministic ledger audits: fixed rules that never call a model, so the
// same ledger always yields the same findings. They are what a scheduled
// automation runs first; the Agent only explains and drafts fixes for them.

// AuditOptions bounds one audit run. Zero values take the defaults.
type AuditOptions struct {
	// Today is the reference day, YYYY-MM-DD; empty means the local date.
	Today string `json:"today,omitempty"`
	// WindowDays limits the transaction checks to recent entries.
	WindowDays int `json:"windowDays,omitempty"`
	// StaleBalanceDays is how old an account's last balance assertion may be.
	StaleBalanceDays int `json:"staleBalanceDays,omitempty"`
	// DuplicateDays is how far apart two postings may be to count as one.
	DuplicateDays int `json:"duplicateDays,omitempty"`
	// Ignored are fingerprints the user dismissed; they are left out.
	Ignored []string `json:"ignored,omitempty"`
	// ExcludeDirs are top-level directories whose .bean files are never
	// expected to be included.
	ExcludeDirs []string `json:"excludeDirs,omitempty"`
}

const (
	defaultAuditWindowDays       = 180
	defaultAuditStaleBalanceDays = 45
	defaultAuditDuplicateDays    = 3
	maxAuditFindingsPerCheck     = 50
)

var defaultAuditExcludeDirs = []string{"archive", "skills", "audits", "automations"}

// AuditFinding is one problem. ID is a content fingerprint: it survives
// unrelated edits, so a finding is reported as new only once and an ignore
// sticks.
type AuditFinding struct {
	ID       string   `json:"id"`
	Check    string   `json:"check"`
	Severity string   `json:"severity"`
	Title    string   `json:"title"`
	Detail   string   `json:"detail"`
	Refs     []string `json:"refs"`
}

// AuditReport is everything one run found.
type AuditReport struct {
	Today      string         `json:"today"`
	Findings   []AuditFinding `json:"findings"`
	Truncated  []string       `json:"truncated,omitempty"`
	DurationMs int64          `json:"durationMs"`
}

// RunLocalAudit runs every built-in check over a committed local generation.
func RunLocalAudit(input LocalRequest, options AuditOptions) (AuditReport, error) {
	started := time.Now()
	cfg, err := localConfig(input)
	if err != nil {
		return AuditReport{}, err
	}
	snapshot, err := NewLedgerCache(cfg).Snapshot()
	if err != nil {
		return AuditReport{}, err
	}
	report, err := auditSnapshot(snapshot, cfg.LedgerRoot, cfg.localEntrypoint, options)
	report.DurationMs = time.Since(started).Milliseconds()
	return report, err
}

func auditSnapshot(snapshot *LedgerSnapshot, root, entrypoint string, options AuditOptions) (AuditReport, error) {
	if options.WindowDays <= 0 {
		options.WindowDays = defaultAuditWindowDays
	}
	if options.StaleBalanceDays <= 0 {
		options.StaleBalanceDays = defaultAuditStaleBalanceDays
	}
	if options.DuplicateDays <= 0 {
		options.DuplicateDays = defaultAuditDuplicateDays
	}
	if options.ExcludeDirs == nil {
		options.ExcludeDirs = defaultAuditExcludeDirs
	}
	if entrypoint == "" {
		entrypoint = "main.bean"
	}
	today := time.Now()
	if options.Today != "" {
		parsed, err := time.Parse(time.DateOnly, options.Today)
		if err != nil {
			return AuditReport{}, fmt.Errorf("today must be YYYY-MM-DD: %w", err)
		}
		today = parsed
	}
	today = time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.UTC)
	since := today.AddDate(0, 0, -options.WindowDays).Format(time.DateOnly)
	audit := auditRun{root: root, ignored: map[string]bool{}}
	for _, id := range options.Ignored {
		audit.ignored[id] = true
	}
	audit.duplicates(snapshot, since, options.DuplicateDays)
	audit.unresolved(snapshot, since)
	audit.staleBalances(snapshot, today, options.StaleBalanceDays)
	if err := audit.unincluded(snapshot, root, entrypoint, options.ExcludeDirs); err != nil {
		return AuditReport{}, err
	}
	report := AuditReport{Today: today.Format(time.DateOnly), Findings: audit.findings, Truncated: audit.truncated}
	if report.Findings == nil {
		report.Findings = []AuditFinding{}
	}
	return report, nil
}

type auditRun struct {
	root      string
	ignored   map[string]bool
	findings  []AuditFinding
	counts    map[string]int
	truncated []string
}

func (a *auditRun) add(finding AuditFinding, fingerprint ...string) {
	sum := sha256.Sum256([]byte(strings.Join(append([]string{finding.Check}, fingerprint...), "\x00")))
	finding.ID = finding.Check + ":" + hex.EncodeToString(sum[:])[:12]
	if a.ignored[finding.ID] {
		return
	}
	if a.counts == nil {
		a.counts = map[string]int{}
	}
	if a.counts[finding.Check] >= maxAuditFindingsPerCheck {
		if a.counts[finding.Check] == maxAuditFindingsPerCheck {
			a.truncated = append(a.truncated, finding.Check)
			a.counts[finding.Check]++
		}
		return
	}
	a.counts[finding.Check]++
	if finding.Refs == nil {
		finding.Refs = []string{}
	}
	a.findings = append(a.findings, finding)
}

// ref is a transaction's place, relative to the workspace.
func (a *auditRun) ref(source TransactionSource) string {
	return fmt.Sprintf("%s:%d", a.relative(source.File), source.Line)
}

func (a *auditRun) relative(file string) string {
	if rel, err := filepath.Rel(a.root, file); err == nil && !strings.HasPrefix(rel, "..") {
		return filepath.ToSlash(rel)
	}
	return filepath.ToSlash(file)
}

// transactionKey is the transaction's content, without its place, so a
// finding keeps its fingerprint when lines move.
func transactionKey(tx Transaction) string {
	return transactionDuplicateSignature(tx.Date, tx.Payee, tx.Narration, tx.Postings)
}

func fundingAccount(account string) bool {
	return strings.HasPrefix(account, "Assets:") || strings.HasPrefix(account, "Liabilities:")
}

func formatCents(amount int, currency string) string {
	sign := ""
	if amount < 0 {
		sign, amount = "-", -amount
	}
	return fmt.Sprintf("%s%d.%02d %s", sign, amount/100, amount%100, currency)
}

func dayDistance(a, b string) int {
	left, errA := time.Parse(time.DateOnly, a)
	right, errB := time.Parse(time.DateOnly, b)
	if errA != nil || errB != nil {
		return 1 << 30
	}
	days := int(right.Sub(left).Hours() / 24)
	if days < 0 {
		days = -days
	}
	return days
}

func normalizedPayee(tx Transaction) string {
	payee := strings.ToLower(strings.TrimSpace(tx.Payee))
	if payee == "" {
		payee = strings.ToLower(strings.TrimSpace(tx.Narration))
	}
	return strings.Join(strings.Fields(payee), "")
}

func sharesLink(a, b Transaction) bool {
	for _, left := range a.Links {
		for _, right := range b.Links {
			if left == right {
				return true
			}
		}
	}
	return false
}

// duplicates finds two transactions that move the same amount through the
// same funding account within a few days and look like one purchase: the
// same payee, or the same amount recorded from two different source files
// (a bank statement and an Alipay export, for example).
func (a *auditRun) duplicates(snapshot *LedgerSnapshot, since string, maxDays int) {
	type leg struct {
		index int
		date  string
	}
	buckets := map[string][]leg{}
	for index, tx := range snapshot.Transactions {
		if tx.Date < since {
			continue
		}
		for _, posting := range tx.Postings {
			if !fundingAccount(posting.Account) || posting.Amount == 0 {
				continue
			}
			key := fmt.Sprintf("%s|%d|%s", posting.Account, posting.Amount, posting.Currency)
			buckets[key] = append(buckets[key], leg{index: index, date: tx.Date})
		}
	}
	keys := make([]string, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	seen := map[[2]int]bool{}
	for _, key := range keys {
		legs := buckets[key]
		sort.SliceStable(legs, func(i, j int) bool { return legs[i].date < legs[j].date })
		for i := range legs {
			for j := i + 1; j < len(legs) && dayDistance(legs[i].date, legs[j].date) <= maxDays; j++ {
				first, second := legs[i].index, legs[j].index
				if first == second || seen[[2]int{first, second}] {
					continue
				}
				left, right := snapshot.Transactions[first], snapshot.Transactions[second]
				samePayee := normalizedPayee(left) != "" && normalizedPayee(left) == normalizedPayee(right)
				otherSource := left.Source.File != right.Source.File
				if (!samePayee && !otherSource) || sharesLink(left, right) {
					continue
				}
				seen[[2]int{first, second}] = true
				parts := strings.SplitN(key, "|", 3)
				var amount int
				fmt.Sscan(parts[1], &amount)
				keyA, keyB := transactionKey(left), transactionKey(right)
				if keyB < keyA {
					keyA, keyB = keyB, keyA
				}
				label := strings.TrimSpace(left.Payee)
				if label == "" {
					label = strings.TrimSpace(left.Narration)
				}
				a.add(AuditFinding{Check: "duplicate", Severity: "warning",
					Title:  fmt.Sprintf("疑似重复：%s %s", label, formatCents(-amount, parts[2])),
					Detail: fmt.Sprintf("%s 在 %s 和 %s 各记了一笔 %s", parts[0], left.Date, right.Date, formatCents(amount, parts[2])),
					Refs:   []string{a.ref(left.Source), a.ref(right.Source)}}, keyA, keyB)
			}
		}
	}
}

// unresolved finds what was left to sort out later: uncategorized accounts,
// pending flags and FIXME/TODO notes.
func (a *auditRun) unresolved(snapshot *LedgerSnapshot, since string) {
	for _, entry := range snapshot.BeanEntries {
		if entry.Kind != "transaction" || entry.Date < since {
			continue
		}
		reasons := []string{}
		if entry.Flag == "!" {
			reasons = append(reasons, "标记为 !")
		}
		for _, posting := range entry.Postings {
			account := posting.Account
			if strings.HasSuffix(account, ":Uncategorized") || strings.HasSuffix(account, ":Unknown") {
				reasons = append(reasons, "记在 "+account)
			}
			if posting.Flag == "!" {
				reasons = append(reasons, account+" 标记为 !")
			}
		}
		text := strings.ToUpper(entry.Payee + " " + entry.Narration)
		for _, note := range []string{"FIXME", "TODO"} {
			if strings.Contains(text, note) {
				reasons = append(reasons, "备注里有 "+note)
			}
		}
		if len(reasons) == 0 {
			continue
		}
		postings := make([]Posting, 0, len(entry.Postings))
		for _, posting := range entry.Postings {
			postings = append(postings, posting.Posting)
		}
		label := strings.TrimSpace(strings.TrimSpace(entry.Payee + " " + entry.Narration))
		a.add(AuditFinding{Check: "unresolved", Severity: "warning",
			Title:  fmt.Sprintf("待处理：%s %s", entry.Date, label),
			Detail: strings.Join(reasons, "；"),
			Refs:   []string{fmt.Sprintf("%s:%d", a.relative(entry.File), entry.Line)}},
			transactionDuplicateSignature(entry.Date, entry.Payee, entry.Narration, postings), strings.Join(reasons, ","))
	}
}

// staleBalances finds open asset and liability accounts that were
// reconciled before but not lately, while money kept moving through them.
func (a *auditRun) staleBalances(snapshot *LedgerSnapshot, today time.Time, maxDays int) {
	lastAssertion := map[string]string{}
	for _, assertion := range snapshot.BalanceAssertions {
		if assertion.Date > lastAssertion[assertion.Account] {
			lastAssertion[assertion.Account] = assertion.Date
		}
	}
	lastActivity := map[string]string{}
	for _, tx := range snapshot.Transactions {
		for _, posting := range tx.Postings {
			if tx.Date > lastActivity[posting.Account] {
				lastActivity[posting.Account] = tx.Date
			}
		}
	}
	accounts := make([]string, 0, len(lastAssertion))
	for account := range lastAssertion {
		accounts = append(accounts, account)
	}
	sort.Strings(accounts)
	closed := map[string]bool{}
	for _, account := range snapshot.Accounts {
		if account.CloseDate != nil {
			closed[account.Account] = true
		}
	}
	todayText := today.Format(time.DateOnly)
	for _, account := range accounts {
		if closed[account] || !fundingAccount(account) {
			continue
		}
		last := lastAssertion[account]
		age := dayDistance(last, todayText)
		if age <= maxDays || lastActivity[account] <= last {
			continue
		}
		a.add(AuditFinding{Check: "stale-balance", Severity: "info",
			Title:  fmt.Sprintf("%s %d 天没有对账", account, age),
			Detail: fmt.Sprintf("最近一次余额断言在 %s，之后到 %s 仍有交易", last, lastActivity[account]),
			Refs:   []string{}}, account, last)
	}
}

// unincluded finds .bean files the entrypoint never loads, the way the
// October 2026 includes went missing.
func (a *auditRun) unincluded(snapshot *LedgerSnapshot, root, entrypoint string, exclude []string) error {
	loaded := map[string]bool{filepath.Clean(filepath.Join(root, entrypoint)): true}
	for _, entry := range snapshot.BeanEntries {
		if entry.File != "" {
			loaded[filepath.Clean(entry.File)] = true
		}
		if entry.Kind == "include" && entry.Filename != "" && entry.File != "" {
			pattern := entry.Filename
			if !filepath.IsAbs(pattern) {
				pattern = filepath.Join(filepath.Dir(entry.File), pattern)
			}
			if matches, err := filepath.Glob(pattern); err == nil {
				for _, match := range matches {
					loaded[filepath.Clean(match)] = true
				}
			}
		}
	}
	skip := map[string]bool{}
	for _, dir := range exclude {
		skip[dir] = true
	}
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := a.relative(path)
		if d.IsDir() {
			if path != root && (strings.HasPrefix(d.Name(), ".") || (!strings.Contains(rel, "/") && skip[rel])) {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".bean") || strings.HasPrefix(d.Name(), ".") || loaded[filepath.Clean(path)] {
			return nil
		}
		a.add(AuditFinding{Check: "unincluded", Severity: "error",
			Title:  "没被 include 的账本文件：" + rel,
			Detail: "这个文件不在 " + entrypoint + " 的 include 链里，里面的交易不会进账本",
			Refs:   []string{rel}}, rel)
		return nil
	})
}
