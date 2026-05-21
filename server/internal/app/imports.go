package app

import (
	"crypto/rand"
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

type ImportEntry struct {
	ID              string            `json:"id"`
	Date            string            `json:"date"`
	Flag            string            `json:"flag"`
	Payee           string            `json:"payee"`
	Narration       string            `json:"narration"`
	Source          string            `json:"source,omitempty"`
	OrderID         string            `json:"orderId,omitempty"`
	MerchantID      string            `json:"merchantId,omitempty"`
	PayTime         string            `json:"payTime,omitempty"`
	Method          string            `json:"method,omitempty"`
	TxType          string            `json:"txType,omitempty"`
	Status          string            `json:"status,omitempty"`
	Type            string            `json:"type,omitempty"`
	CategoryAccount string            `json:"categoryAccount"`
	FundingAccount  string            `json:"fundingAccount"`
	Amount          float64           `json:"amount"`
	Currency        string            `json:"currency"`
	Metadata        map[string]string `json:"metadata"`
	Postings        []EntryPosting    `json:"postings"`
}

type importMeta struct {
	Provider         string `json:"provider"`
	OriginalFilename string `json:"originalFilename"`
	InputFile        string `json:"inputFile"`
}

func (s *Server) createImportPreview(providerOverride string, header *multipart.FileHeader) (ginH, error) {
	importID := randomID()
	dir := filepath.Join(s.cfg.RuntimeDir, "imports", importID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	inputPath := filepath.Join(dir, filepath.Base(header.Filename))
	if err := saveMultipartFile(header, inputPath); err != nil {
		return nil, err
	}
	content, err := os.ReadFile(inputPath)
	if err != nil {
		return nil, err
	}
	provider, reason := detectProvider(header.Filename, string(content), providerOverride)
	entries, generatedBean, err := parseSimpleCSVImport(string(content), provider)
	if err != nil {
		return nil, err
	}
	meta := importMeta{Provider: provider, OriginalFilename: header.Filename, InputFile: inputPath}
	raw, _ := json.MarshalIndent(meta, "", "  ")
	_ = os.WriteFile(filepath.Join(dir, "meta.json"), raw, 0o600)
	accounts, err := ParseAccounts(s.cfg)
	if err != nil {
		return nil, err
	}
	accountOptions := []ginH{}
	for _, account := range accounts {
		accountOptions = append(accountOptions, ginH{"account": account.Account, "label": account.Label, "group": account.Group, "active": account.Active})
	}
	dateStart, dateEnd := dateRange(entries)
	return ginH{
		"importId": importID, "provider": provider,
		"providerDetection": ginH{"provider": provider, "reason": reason, "confidence": "medium"},
		"originalFilename":  header.Filename, "generatedBean": generatedBean, "dedupReport": "Go import preview generated without external DEG/dedup scripts.",
		"entries": entries, "accountOptions": accountOptions, "candidateCount": len(entries), "rawRowCount": len(entries), "filteredRowCount": len(entries), "generatedCount": len(entries), "excludedRowCount": 0, "skippedDuplicateCount": 0,
		"dateStart": dateStart, "dateEnd": dateEnd, "warnings": []string{},
	}, nil
}

func (s *Server) commitImport(importID, provider string, entries []ImportEntry) (ginH, error) {
	metaPath := filepath.Join(s.cfg.RuntimeDir, "imports", importID, "meta.json")
	raw, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, err
	}
	var meta importMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return nil, err
	}
	if meta.Provider != provider {
		return nil, errors.New("导入 provider 与预览不一致")
	}
	if len(entries) == 0 {
		return nil, errors.New("entries is required")
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Date < entries[j].Date })
	dateStart, dateEnd := dateRange(entries)
	output := filepath.Join(transactionsDir(s.cfg), dateStart[:4], "imports", fmt.Sprintf("%s_%s-%s.bean", dateStart, dateEnd, provider))
	output = uniquePath(output)
	monthFile := transactionFileForDate(s.cfg, dateStart)
	beanText := renderImportEntries(entries)
	if err := s.writeImportedBeanFile(output, monthFile, beanText, provider, dateStart, dateEnd); err != nil {
		return nil, err
	}
	return ginH{"ok": true, "outputFile": output, "includeFile": monthFile, "count": len(entries), "beanText": beanText}, nil
}

func (s *Server) writeImportedBeanFile(outputFile, monthFile, beanText, provider, start, end string) error {
	s.writer.mu.Lock()
	defer s.writer.mu.Unlock()
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
				_ = os.WriteFile(file, snap.content, 0o644)
			} else {
				_ = os.Remove(file)
			}
		}
	}
	if err := s.writer.ensureMonthlyFileAndInclude(monthFile, start, snapshot); err != nil {
		return err
	}
	if err := snapshot(outputFile); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o755); err != nil {
		return err
	}
	header := fmt.Sprintf("; %s import: %s .. %s\n", provider, start, end)
	if err := os.WriteFile(outputFile, []byte(header+strings.TrimRight(beanText, "\n")+"\n"), 0o644); err != nil {
		restore()
		return err
	}
	includeLine := includeLineRelative(monthFile, outputFile)
	monthBefore, err := os.ReadFile(monthFile)
	if err != nil {
		restore()
		return err
	}
	if !strings.Contains(string(monthBefore), includeLine) {
		sep := ""
		if !strings.HasSuffix(string(monthBefore), "\n") {
			sep = "\n"
		}
		if err := os.WriteFile(monthFile, []byte(string(monthBefore)+sep+includeLine+"\n"), 0o644); err != nil {
			restore()
			return err
		}
	}
	if err := s.writer.validateAndClear(); err != nil {
		restore()
		return err
	}
	return nil
}

func parseSimpleCSVImport(text, provider string) ([]ImportEntry, string, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	var entries []ImportEntry
	for index, line := range lines {
		if strings.TrimSpace(line) == "" || strings.Contains(line, "交易号") || strings.Contains(line, "交易创建时间") {
			continue
		}
		cells := parseCSVLine(line)
		if len(cells) < 3 {
			continue
		}
		date := firstDate(cells)
		amount := firstAmount(cells)
		if date == "" || amount == "" {
			continue
		}
		payee := firstNonEmpty(cells, 1)
		if payee == "" {
			payee = "Imported"
		}
		funding := "Assets:Cash"
		if provider == "alipay" {
			funding = "Assets:CN:Alipay:Balance"
		} else if provider == "wechat" {
			funding = "Assets:CN:Wechat:Balance"
		}
		amountCents := cents(amount)
		entry := ImportEntry{ID: fmt.Sprintf("%s-%d", date, index), Date: date, Flag: "*", Payee: payee, Narration: payee, CategoryAccount: "Expenses:Unknown", FundingAccount: funding, Amount: float64(amountCents) / 100, Currency: "CNY", Metadata: map[string]string{"source": provider}, Postings: []EntryPosting{{Account: "Expenses:Unknown", Amount: fromCents(amountCents), Currency: "CNY"}, {Account: funding, Amount: fromCents(-amountCents), Currency: "CNY"}}}
		entries = append(entries, entry)
	}
	if len(entries) == 0 {
		return nil, "", errors.New("未从账单中识别出可导入交易")
	}
	bean := renderImportEntries(entries)
	return entries, bean, nil
}

func renderImportEntries(entries []ImportEntry) string {
	var blocks []string
	for _, entry := range entries {
		metadata := map[string]MetadataValue{}
		for key, value := range entry.Metadata {
			if value != "" {
				metadata[key] = value
			}
		}
		postings := entry.Postings
		if len(postings) == 0 {
			amount := cents(fmt.Sprintf("%.2f", entry.Amount))
			postings = []EntryPosting{{Account: entry.CategoryAccount, Amount: fromCents(amount), Currency: "CNY"}, {Account: entry.FundingAccount, Amount: fromCents(-amount), Currency: "CNY"}}
		}
		blocks = append(blocks, TransactionToBean(LedgerEntry{Kind: "transaction", Date: entry.Date, Payee: entry.Payee, Narration: entry.Narration, Metadata: metadata, Tags: []string{}, Postings: postings, Currency: "CNY", Confidence: 1}))
	}
	return strings.Join(blocks, "\n")
}

type ginH map[string]any

func saveMultipartFile(header *multipart.FileHeader, path string) error {
	src, err := header.Open()
	if err != nil {
		return err
	}
	defer src.Close()
	content, err := io.ReadAll(src)
	if err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o600)
}

func detectProvider(filename, content, override string) (string, string) {
	if override == "alipay" || override == "wechat" || override == "cmb" {
		return override, "手动指定"
	}
	lower := strings.ToLower(filename)
	switch {
	case strings.HasSuffix(lower, ".xlsx"), strings.HasSuffix(lower, ".xls"):
		return "wechat", "Excel 文件通常为微信支付账单"
	case strings.HasSuffix(lower, ".pdf"), strings.Contains(content, "招商银行"):
		return "cmb", "文件将按招商银行信用卡账单解析"
	case strings.Contains(content, "支付宝"):
		return "alipay", "CSV 内容包含支付宝账单字段"
	default:
		return "alipay", "CSV 文件默认按支付宝账单处理"
	}
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

func firstDate(cells []string) string {
	for _, cell := range cells {
		cell = strings.TrimSpace(cell)
		if len(cell) >= 10 && cell[4] == '-' && cell[7] == '-' {
			return cell[:10]
		}
	}
	return ""
}

func firstAmount(cells []string) string {
	for _, cell := range cells {
		cleaned := strings.TrimSpace(strings.TrimPrefix(strings.ReplaceAll(cell, ",", ""), "¥"))
		if regexp.MustCompile(`^-?\d+(\.\d{1,2})?$`).MatchString(cleaned) && cleaned != "0" {
			if strings.HasPrefix(cleaned, "-") {
				cleaned = strings.TrimPrefix(cleaned, "-")
			}
			return cleaned
		}
	}
	return ""
}

func firstNonEmpty(cells []string, start int) string {
	for i := start; i < len(cells); i++ {
		if strings.TrimSpace(cells[i]) != "" && firstDate([]string{cells[i]}) == "" && firstAmount([]string{cells[i]}) == "" {
			return strings.TrimSpace(cells[i])
		}
	}
	return ""
}

func dateRange(entries []ImportEntry) (string, string) {
	if len(entries) == 0 {
		return "", ""
	}
	start, end := entries[0].Date, entries[0].Date
	for _, entry := range entries {
		if entry.Date < start {
			start = entry.Date
		}
		if entry.Date > end {
			end = entry.Date
		}
	}
	return start, end
}

func randomID() string {
	var bytes [8]byte
	_, _ = rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:])
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

func includeLineRelative(baseFile, includedFile string) string {
	rel, _ := filepath.Rel(filepath.Dir(baseFile), includedFile)
	return `include "` + filepath.ToSlash(rel) + `"`
}
