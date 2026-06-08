package app

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type ginH map[string]any

func detectBillProvider(filename string, content []byte, override string) (providerDetection, error) {
	return detectImportProvider(filename, content, override)
}

func parsePreviewEntries(beanText string) ([]ImportEntry, error) {
	blocks := transactionBlocks(beanText)
	entries := make([]ImportEntry, 0, len(blocks))
	for index, block := range blocks {
		entry, err := parsePreviewEntry(block, index)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func parsePreviewEntry(block string, index int) (ImportEntry, error) {
	lines := strings.Split(block, "\n")
	if len(lines) == 0 {
		return ImportEntry{}, errors.New("空交易块")
	}
	header, err := parseImportHeader(lines[0])
	if err != nil {
		return ImportEntry{}, err
	}
	metadata := map[string]string{}
	postings := []EntryPosting{}
	metaRe := regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_-]*):\s+(.+)$`)
	postRe := regexp.MustCompile(`^([A-Za-z][A-Za-z0-9:_-]+)\s+(-?\d+(?:\.\d+)?)\s+([A-Z][A-Z0-9]*)$`)
	for _, line := range lines[1:] {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if m := metaRe.FindStringSubmatch(trimmed); m != nil {
			metadata[m[1]] = unquoteBean(m[2])
			continue
		}
		if m := postRe.FindStringSubmatch(trimmed); m != nil {
			postings = append(postings, EntryPosting{Account: m[1], Amount: m[2], Currency: m[3]})
		}
	}
	category, funding := choosePreviewAccounts(postings)
	amount := maxPostingAmount(postings)
	id := metadata["orderId"]
	if id == "" {
		id = fmt.Sprintf("%s-%d", header.Date, index)
	}
	currency := "CNY"
	if category.Currency != "" {
		currency = category.Currency
	} else if funding.Currency != "" {
		currency = funding.Currency
	}
	return ImportEntry{
		ID:              id,
		Date:            header.Date,
		Flag:            header.Flag,
		Payee:           header.Payee,
		Narration:       header.Narration,
		Source:          metadata["source"],
		OrderID:         metadata["orderId"],
		MerchantID:      metadata["merchantId"],
		PayTime:         metadata["payTime"],
		Method:          metadata["method"],
		TxType:          metadata["txType"],
		Status:          metadata["status"],
		Type:            metadata["type"],
		CategoryAccount: valueOr(category.Account, "Expenses:Unknown"),
		FundingAccount:  funding.Account,
		Amount:          amount,
		Currency:        currency,
		Metadata:        metadata,
		Postings:        postings,
	}, nil
}

type importHeader struct {
	Date      string
	Flag      string
	Payee     string
	Narration string
}

func parseImportHeader(line string) (importHeader, error) {
	m := regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+([*!])\s+"((?:\\.|[^"])*)"\s+"((?:\\.|[^"])*)"`).FindStringSubmatch(line)
	if m == nil {
		return importHeader{}, fmt.Errorf("无法解析交易行: %s", line)
	}
	return importHeader{Date: m[1], Flag: m[2], Payee: unquoteBean(`"` + m[3] + `"`), Narration: unquoteBean(`"` + m[4] + `"`)}, nil
}

func choosePreviewAccounts(postings []EntryPosting) (EntryPosting, EntryPosting) {
	type numericPosting struct {
		EntryPosting
		Amount int
	}
	numeric := make([]numericPosting, 0, len(postings))
	for _, posting := range postings {
		numeric = append(numeric, numericPosting{EntryPosting: posting, Amount: cents(posting.Amount)})
	}
	categoryIndex := -1
	for i, posting := range numeric {
		if posting.Amount > 0 && (strings.HasPrefix(posting.Account, "Expenses:") || strings.HasPrefix(posting.Account, "Income:")) {
			categoryIndex = i
			break
		}
	}
	if categoryIndex < 0 {
		for i, posting := range numeric {
			if strings.HasPrefix(posting.Account, "Expenses:") || strings.HasPrefix(posting.Account, "Income:") {
				categoryIndex = i
				break
			}
		}
	}
	if categoryIndex < 0 && len(numeric) > 0 {
		categoryIndex = 0
	}
	if categoryIndex < 0 {
		return EntryPosting{}, EntryPosting{}
	}
	category := numeric[categoryIndex]
	for i, posting := range numeric {
		if i != categoryIndex && sign(posting.Amount) != sign(category.Amount) {
			return category.EntryPosting, posting.EntryPosting
		}
	}
	for i, posting := range numeric {
		if i != categoryIndex {
			return category.EntryPosting, posting.EntryPosting
		}
	}
	return category.EntryPosting, EntryPosting{}
}

func parseBeanSummary(beanText string) beanSummary {
	re := regexp.MustCompile(`(?m)^(\d{4}-\d{2}-\d{2})\s+[*!]\s+`)
	matches := re.FindAllStringSubmatch(beanText, -1)
	dates := make([]string, 0, len(matches))
	for _, match := range matches {
		dates = append(dates, match[1])
	}
	sort.Strings(dates)
	summary := beanSummary{CandidateCount: len(dates)}
	if len(dates) > 0 {
		summary.DateStart = dates[0]
		summary.DateEnd = dates[len(dates)-1]
	}
	return summary
}

func transactionOnlyBeanText(beanText string) string {
	return strings.TrimSpace(strings.Join(transactionBlocks(beanText), "\n\n"))
}

func transactionBlocks(beanText string) []string {
	lines := strings.Split(strings.ReplaceAll(beanText, "\r\n", "\n"), "\n")
	chunks := []string{}
	current := []string(nil)
	startRe := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\s+[*!]\s+`)
	for _, line := range lines {
		if startRe.MatchString(line) {
			if len(current) > 0 {
				chunks = append(chunks, strings.TrimRight(strings.Join(current, "\n"), "\n"))
			}
			current = []string{line}
			continue
		}
		if current != nil && (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") || strings.TrimSpace(line) == "") {
			current = append(current, line)
		}
	}
	if len(current) > 0 {
		chunks = append(chunks, strings.TrimRight(strings.Join(current, "\n"), "\n"))
	}
	return chunks
}

func parseCSVLine(line string) []string {
	var cells []string
	var buf strings.Builder
	inQuotes := false
	for i := 0; i < len(line); i++ {
		ch := line[i]
		if ch == '"' {
			if inQuotes && i+1 < len(line) && line[i+1] == '"' {
				buf.WriteByte('"')
				i++
			} else {
				inQuotes = !inQuotes
			}
			continue
		}
		if ch == ',' && !inQuotes {
			cells = append(cells, strings.TrimSpace(buf.String()))
			buf.Reset()
			continue
		}
		buf.WriteByte(ch)
	}
	cells = append(cells, strings.TrimSpace(buf.String()))
	return cells
}

func (s *Server) cmbPaymentSourcePrefixes() []string {
	configFile := filepath.Join(s.cfg.LedgerRoot, "imports/cmb-credit-card-config.yaml")
	raw, err := os.ReadFile(configFile)
	if err != nil {
		return []string{"支付宝-", "财付通-", "微信支付-"}
	}
	match := regexp.MustCompile(`paymentSourceHandledExternally:\s*\n((?:\s+-\s+.+\n?)+)`).FindStringSubmatch(string(raw))
	if match == nil {
		return []string{"支付宝-", "财付通-", "微信支付-"}
	}
	prefixes := []string{}
	for _, m := range regexp.MustCompile(`(?m)^\s+-\s+(.+)\s*$`).FindAllStringSubmatch(match[1], -1) {
		prefix := strings.Trim(strings.TrimSpace(m[1]), `'"`)
		if prefix != "" {
			prefixes = append(prefixes, prefix)
		}
	}
	if len(prefixes) == 0 {
		return []string{"支付宝-", "财付通-", "微信支付-"}
	}
	return prefixes
}

func (s *Server) importAccountOptions() ([]ginH, error) {
	accounts, err := ParseAccounts(s.cfg)
	if err != nil {
		return nil, err
	}
	options := []ginH{}
	for _, account := range accounts {
		if account.Active {
			options = append(options, ginH{"account": account.Account, "alias": account.Alias, "label": account.Label, "group": account.Group, "active": account.Active})
		}
	}
	return options, nil
}

func (s *Server) writeImportMeta(importID string, meta importMeta) error {
	raw, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(importRuntimeDir(s.cfg, importID), "meta.json"), raw, 0o600)
}

func (s *Server) readImportMeta(importID string) (importMeta, error) {
	raw, err := os.ReadFile(filepath.Join(importRuntimeDir(s.cfg, importID), "meta.json"))
	if err != nil {
		return importMeta{}, err
	}
	var meta importMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return importMeta{}, err
	}
	return meta, nil
}

func importRuntimeDir(cfg Config, importID string) string {
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]+$`).MatchString(importID) {
		return filepath.Join(cfg.RuntimeDir, "imports", "invalid")
	}
	return filepath.Join(cfg.RuntimeDir, "imports", importID)
}

func previewPath(cfg Config, importID, name string) string {
	return filepath.Join(importRuntimeDir(cfg, importID), name)
}

func importOutputPath(cfg Config, dateStart, dateEnd, provider, suffix string) string {
	safeSuffix := safeSuffix(suffix)
	base := fmt.Sprintf("%s_%s-%s", dateStart, dateEnd, provider)
	if safeSuffix != "" {
		base += "-" + safeSuffix
	}
	return filepath.Join(transactionsDir(cfg), dateStart[:4], "imports", base+".bean")
}

func importDocumentPath(cfg Config, dateStart, dateEnd, provider, originalFilename, suffix string) string {
	safeSuffix := safeSuffix(suffix)
	ext := strings.ToLower(filepath.Ext(originalFilename))
	if ext == "" {
		switch provider {
		case "wechat":
			ext = ".xlsx"
		case "cmb":
			ext = ".pdf"
		default:
			ext = ".csv"
		}
	}
	base := fmt.Sprintf("%s_%s-%s", dateStart, dateEnd, provider)
	if safeSuffix != "" {
		base += "-" + safeSuffix
	}
	return filepath.Join(transactionsDir(cfg), dateStart[:4], "documents", "imports", base+ext)
}

func documentDirective(date, account, outputFile, documentFile string) string {
	rel, _ := filepath.Rel(filepath.Dir(outputFile), documentFile)
	return fmt.Sprintf(`%s document %s "%s"`, date, account, filepath.ToSlash(rel))
}

func providerDocumentAccount(provider string, accounts map[string]bool, fallback string) string {
	if importer, ok := importProvider(provider); ok {
		return importer.DocumentAccount(accounts, fallback)
	}
	return fallback
}

func includeLineRelative(baseFile, includedFile string) string {
	rel, _ := filepath.Rel(filepath.Dir(baseFile), includedFile)
	return `include "` + filepath.ToSlash(rel) + `"`
}

func uniquePath(file string) string {
	if _, err := os.Stat(file); errors.Is(err, os.ErrNotExist) {
		return file
	}
	ext := filepath.Ext(file)
	base := strings.TrimSuffix(file, ext)
	for i := 2; i < 1000; i++ {
		candidate := fmt.Sprintf("%s-%d%s", base, i, ext)
		if _, err := os.Stat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
	return file
}

func readMultipartFile(header *multipart.FileHeader) ([]byte, error) {
	src, err := header.Open()
	if err != nil {
		return nil, err
	}
	defer src.Close()
	return io.ReadAll(src)
}

func copyFile(source, dest string) error {
	input, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(dest, input, 0o600)
}

func fileSHA256(file string) (string, error) {
	raw, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return sha256Hex(raw), nil
}

func sha256Hex(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func randomID() string {
	var bytes [8]byte
	_, _ = rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:])
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func unquoteBean(value string) string {
	trimmed := strings.TrimSpace(value)
	if strings.HasPrefix(trimmed, `"`) && strings.HasSuffix(trimmed, `"`) && len(trimmed) >= 2 {
		unquoted := trimmed[1 : len(trimmed)-1]
		unquoted = strings.ReplaceAll(unquoted, `\"`, `"`)
		unquoted = strings.ReplaceAll(unquoted, `\\`, `\`)
		return unquoted
	}
	return trimmed
}

func maxPostingAmount(postings []EntryPosting) float64 {
	max := 0
	for _, posting := range postings {
		amount := cents(posting.Amount)
		if amount < 0 {
			amount = -amount
		}
		if amount > max {
			max = amount
		}
	}
	return float64(max) / 100
}

func sign(value int) int {
	switch {
	case value > 0:
		return 1
	case value < 0:
		return -1
	default:
		return 0
	}
}

func valueOr(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

func stringIn(value string, values []string) bool {
	for _, candidate := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func safeSuffix(value string) string {
	cleaned := regexp.MustCompile(`[^a-zA-Z0-9_-]`).ReplaceAllString(value, "")
	if len(cleaned) > 12 {
		return cleaned[:12]
	}
	return cleaned
}

func importProviderTitle(provider string) string {
	if importer, ok := importProvider(provider); ok {
		return importer.ProviderTitle()
	}
	return provider
}

func normalizeCmbCSVText(text string) string {
	text = strings.TrimPrefix(text, "\uFEFF")
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	return strings.TrimRight(text, "\n")
}

func nonEmptyLines(text string) []string {
	lines := strings.Split(text, "\n")
	out := []string{}
	for _, line := range lines {
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

func mustReadString(file string) string {
	raw, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	return string(raw)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
