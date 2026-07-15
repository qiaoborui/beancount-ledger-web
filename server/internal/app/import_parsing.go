package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type ginH map[string]any

func detectBillProvider(filename string, content []byte, override string) (providerDetection, error) {
	return detectImportProvider(filename, content, override)
}

func parsePreviewEntries(beanText string) ([]ImportEntry, error) {
	result := ParseBeanLines(beanTextLines("<import-preview>", beanText))
	if len(result.Errors) > 0 {
		return nil, result.Errors[0]
	}
	entries := make([]ImportEntry, 0, len(result.Entries))
	for _, beanEntry := range result.Entries {
		if beanEntry.Kind != "transaction" {
			continue
		}
		entry, err := previewEntryFromBeanEntry(beanEntry, len(entries))
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func beanTextLines(filename, beanText string) []BeanLine {
	normalized := strings.ReplaceAll(beanText, "\r\n", "\n")
	rawLines := strings.Split(normalized, "\n")
	lines := make([]BeanLine, 0, len(rawLines))
	for i, line := range rawLines {
		lines = append(lines, BeanLine{File: filename, Line: i + 1, Text: strings.TrimSuffix(line, "\r")})
	}
	return lines
}

func previewEntryFromBeanEntry(beanEntry BeanEntry, index int) (ImportEntry, error) {
	if beanEntry.Kind != "transaction" {
		return ImportEntry{}, errors.New("预览条目不是交易")
	}
	metadata := previewMetadata(beanEntry.Metadata)
	postings := previewPostings(beanEntry.Postings)
	category, funding := choosePreviewAccounts(postings)
	amount := maxPostingAmount(postings)
	id := metadata["orderId"]
	if id == "" {
		id = fmt.Sprintf("%s-%d", beanEntry.Date, index)
	}
	currency := "CNY"
	if category.Currency != "" {
		currency = category.Currency
	} else if funding.Currency != "" {
		currency = funding.Currency
	}
	return ImportEntry{
		ID:              id,
		Date:            beanEntry.Date,
		Flag:            beanEntry.Flag,
		Payee:           beanEntry.Payee,
		Narration:       beanEntry.Narration,
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

func previewMetadata(values map[string]MetadataValue) map[string]string {
	metadata := make(map[string]string, len(values))
	for key, value := range values {
		metadata[key] = metadataString(value)
	}
	return metadata
}

func metadataString(value MetadataValue) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	default:
		return fmt.Sprint(typed)
	}
}

func previewPostings(postings []parsedPosting) []EntryPosting {
	out := make([]EntryPosting, 0, len(postings))
	for _, posting := range postings {
		if posting.Account == "" {
			continue
		}
		entryPosting := EntryPosting{
			Account:  posting.Account,
			Amount:   posting.Quantity.Number,
			Currency: posting.Quantity.Currency,
		}
		if posting.Price.Currency != "" {
			entryPosting.PriceKind = "unit"
			if posting.TotalPrice {
				entryPosting.PriceKind = "total"
			}
			entryPosting.PriceAmount = posting.Price.Number
			entryPosting.PriceCurrency = posting.Price.Currency
		}
		out = append(out, entryPosting)
	}
	return out
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
	result := ParseBeanLines(beanTextLines("<import-summary>", beanText))
	summary := beanSummary{}
	for _, entry := range result.Entries {
		if entry.Kind != "transaction" || entry.Date == "" {
			continue
		}
		summary.CandidateCount++
		if summary.DateStart == "" || entry.Date < summary.DateStart {
			summary.DateStart = entry.Date
		}
		if summary.DateEnd == "" || entry.Date > summary.DateEnd {
			summary.DateEnd = entry.Date
		}
	}
	return summary
}

func transactionOnlyBeanText(beanText string) string {
	result := ParseBeanLines(beanTextLines("<import-transactions>", beanText))
	blocks := make([]string, 0, len(result.Entries))
	for _, entry := range result.Entries {
		if entry.Kind != "transaction" || len(entry.RawLines) == 0 {
			continue
		}
		blocks = append(blocks, strings.TrimRight(strings.Join(entry.RawLines, "\n"), "\n"))
	}
	return strings.TrimSpace(strings.Join(blocks, "\n\n"))
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
	raw, err := s.readLedgerFileContent(context.Background(), "imports/cmb-credit-card-config.yaml")
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
	snapshot, err := s.ledgerSnapshot(context.Background())
	if err != nil {
		return nil, err
	}
	options := []ginH{}
	for _, account := range snapshot.Accounts {
		if account.Active {
			options = append(options, ginH{"account": account.Account, "alias": account.Alias, "label": account.Label, "group": account.Group, "active": account.Active})
		}
	}
	return options, nil
}

func (s *Server) writeImportMeta(ctx context.Context, importID string, meta importMeta) error {
	return s.runtime().PutJSON(ctx, "imports", importFileKey(importID, "meta"), meta)
}

func (s *Server) readImportMeta(ctx context.Context, importID string) (importMeta, error) {
	var meta importMeta
	ok, err := s.runtime().GetJSON(ctx, "imports", importFileKey(importID, "meta"), &meta)
	if err != nil {
		return importMeta{}, err
	}
	if !ok {
		return importMeta{}, os.ErrNotExist
	}
	return meta, nil
}

func importFileKey(importID, name string) string {
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]+$`).MatchString(importID) {
		importID = "invalid"
	}
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]+$`).MatchString(name) {
		name = safeSuffix(name)
	}
	if name == "" {
		name = "file"
	}
	return importID + "/" + name
}

func (s *Server) putImportFile(ctx context.Context, importID, name string, content []byte) (string, error) {
	key := importFileKey(importID, name)
	if err := s.runtime().PutFile(ctx, "imports", key, content); err != nil {
		return "", err
	}
	return key, nil
}

func (s *Server) materializeImportFile(ctx context.Context, key, localPath string) (bool, error) {
	if key == "" || localPath == "" {
		return false, nil
	}
	return s.runtime().MaterializeFile(ctx, "imports", key, localPath)
}

func (s *Server) materializeImportMetaFiles(ctx context.Context, importID string, meta *importMeta) error {
	if meta.InputFileKey != "" {
		if meta.InputFile == "" {
			meta.InputFile = previewPath(s.cfg, importID, "original")
		}
		ok, err := s.materializeImportFile(ctx, meta.InputFileKey, meta.InputFile)
		if err != nil {
			return err
		}
		if !ok {
			return os.ErrNotExist
		}
	}
	if meta.DocumentFileKey != "" {
		if meta.DocumentFile == "" {
			meta.DocumentFile = previewPath(s.cfg, importID, "document")
		}
		ok, err := s.materializeImportFile(ctx, meta.DocumentFileKey, meta.DocumentFile)
		if err != nil {
			return err
		}
		if !ok {
			return os.ErrNotExist
		}
	}
	return nil
}

func importRuntimeDir(cfg Config, importID string) string {
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]+$`).MatchString(importID) {
		return filepath.Join(os.TempDir(), "beancount-ledger-web", "imports", "invalid")
	}
	return filepath.Join(os.TempDir(), "beancount-ledger-web", "imports", importID)
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

func (s *Server) providerDocumentAccount(provider string, accounts map[string]bool, fallback string) string {
	if importer, ok := s.importerRegistry().Lookup(provider); ok {
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

func (s *Server) importProviderTitle(provider string) string {
	if importer, ok := s.importerRegistry().Lookup(provider); ok {
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
