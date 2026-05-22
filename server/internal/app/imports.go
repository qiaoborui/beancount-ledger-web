package app

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"os"
	"os/exec"
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

type importProviderConfig struct {
	Config     string
	Output     string
	Extensions []string
	Label      string
}

type providerDetection struct {
	Provider   string `json:"provider"`
	Reason     string `json:"reason"`
	Confidence string `json:"confidence"`
}

type importMeta struct {
	Provider           string            `json:"provider"`
	OriginalFilename   string            `json:"originalFilename"`
	InputFile          string            `json:"inputFile"`
	ProviderDetection  providerDetection `json:"providerDetection"`
	StatementHash      string            `json:"statementHash"`
	ExpectedEntryCount *int              `json:"expectedEntryCount,omitempty"`
}

type preparedImportInput struct {
	InputFile        string
	Warnings         []string
	RawRowCount      int
	FilteredRowCount int
	PrefilterSkipped int
}

type beanSummary struct {
	CandidateCount int
	DateStart      string
	DateEnd        string
}

var importProviderConfigs = map[string]importProviderConfig{
	"alipay": {Config: "imports/alipay-config.yaml", Output: "alipay-output.bean", Extensions: []string{".csv"}, Label: "支付宝"},
	"wechat": {Config: "imports/wechat-config.yaml", Output: "wechat-output.bean", Extensions: []string{".xlsx", ".xls"}, Label: "微信支付"},
	"cmb":    {Config: "imports/cmb-credit-card-config.yaml", Output: "cmb-credit-output.bean", Extensions: []string{".pdf", ".csv"}, Label: "招商银行信用卡"},
}

func (s *Server) createImportPreview(providerOverride string, alipayFundRounding bool, header *multipart.FileHeader) (ginH, error) {
	importID := randomID()
	upload, err := s.saveImportUpload(header, providerOverride, importID)
	if err != nil {
		return nil, err
	}
	if err := s.ensureImportRequirements(upload.Provider); err != nil {
		return nil, err
	}

	generatedFile := previewPath(s.cfg, importID, importProviderConfigs[upload.Provider].Output)
	dedupedFile := previewPath(s.cfg, importID, upload.Provider+"-preview-deduped.bean")
	prepared, err := s.prepareProviderInput(upload.Provider, upload.InputFile, upload.OriginalFilename, importID)
	if err != nil {
		return nil, err
	}
	if err := s.runTranslate(upload.Provider, prepared.InputFile, generatedFile); err != nil {
		return nil, err
	}
	rawGeneratedBean, err := os.ReadFile(generatedFile)
	if err != nil {
		return nil, err
	}
	dedupReport, err := s.runDedup(upload.Provider, generatedFile, "", alipayFundRounding, true)
	if err != nil {
		return nil, err
	}
	if err := s.runDedupToFile(upload.Provider, generatedFile, dedupedFile, alipayFundRounding); err != nil {
		return nil, err
	}
	dedupedRaw := []byte{}
	if raw, err := os.ReadFile(dedupedFile); err == nil {
		dedupedRaw = raw
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	generatedBean := transactionOnlyBeanText(string(rawGeneratedBean))
	dedupedBean := transactionOnlyBeanText(string(dedupedRaw))
	entries, err := parsePreviewEntries(dedupedBean)
	if err != nil {
		return nil, err
	}
	if upload.Provider == "cmb" {
		for i := range entries {
			if entries[i].Metadata == nil {
				entries[i].Metadata = map[string]string{}
			}
			entries[i].Metadata["statementHash"] = upload.StatementHash
		}
	}
	summary := parseBeanSummary(dedupedBean)
	generatedSummary := parseBeanSummary(generatedBean)
	skippedDuplicateCount := generatedSummary.CandidateCount - summary.CandidateCount
	if skippedDuplicateCount < 0 {
		skippedDuplicateCount = 0
	}
	excludedRowCount := 0
	if upload.Provider == "cmb" {
		excludedRowCount = prepared.FilteredRowCount - generatedSummary.CandidateCount
		if excludedRowCount < 0 {
			excludedRowCount = 0
		}
	}
	warnings := append([]string{}, prepared.Warnings...)
	if summary.CandidateCount == 0 {
		warnings = append(warnings, "去重后没有发现可写入的新交易。")
	}
	if !strings.Contains(generatedBean, "orderId") {
		warnings = append(warnings, "生成结果中没有发现 orderId，将只能使用 fallback 去重。")
	}
	if upload.Provider == "cmb" {
		if generatedSummary.CandidateCount != prepared.FilteredRowCount {
			return nil, fmt.Errorf("招商银行信用卡行数核对失败：PDF/CSV 明细 %d 条，Web 前置过滤后 %d 条，但 DEG 生成 %d 条。已停止导入，请检查 PDF 解析或 DEG 配置", prepared.RawRowCount, prepared.FilteredRowCount, generatedSummary.CandidateCount)
		}
		warnings = append(warnings, fmt.Sprintf("招商银行信用卡行数核对通过：PDF/CSV 明细 %d 条，Web 前置过滤后 %d 条，DEG 生成 %d 条，去重后待写入 %d 条。", prepared.RawRowCount, prepared.FilteredRowCount, generatedSummary.CandidateCount, summary.CandidateCount))
	}
	expected := len(entries)
	upload.ExpectedEntryCount = &expected
	if err := s.writeImportMeta(importID, upload); err != nil {
		return nil, err
	}
	accountOptions, err := s.importAccountOptions()
	if err != nil {
		return nil, err
	}
	rawRowCount, filteredRowCount := generatedSummary.CandidateCount, generatedSummary.CandidateCount
	if upload.Provider == "cmb" {
		rawRowCount, filteredRowCount = prepared.RawRowCount, prepared.FilteredRowCount
	}
	return ginH{
		"importId":              importID,
		"provider":              upload.Provider,
		"providerDetection":     upload.ProviderDetection,
		"originalFilename":      upload.OriginalFilename,
		"generatedBean":         generatedBean,
		"dedupReport":           dedupReport,
		"entries":               entries,
		"accountOptions":        accountOptions,
		"candidateCount":        summary.CandidateCount,
		"rawRowCount":           rawRowCount,
		"filteredRowCount":      filteredRowCount,
		"generatedCount":        generatedSummary.CandidateCount,
		"excludedRowCount":      excludedRowCount,
		"skippedDuplicateCount": skippedDuplicateCount,
		"dateStart":             nullableString(summary.DateStart),
		"dateEnd":               nullableString(summary.DateEnd),
		"warnings":              warnings,
	}, nil
}

func (s *Server) commitImport(importID, provider string, entries []ImportEntry) (ginH, error) {
	if err := s.ensureImportRequirements(provider); err != nil {
		return nil, err
	}
	meta, err := s.readImportMeta(importID)
	if err != nil {
		return nil, errors.New("找不到导入预览，请重新上传账单")
	}
	if meta.Provider != provider {
		return nil, errors.New("导入 provider 与预览不一致")
	}
	hash, err := fileSHA256(meta.InputFile)
	if err != nil {
		return nil, err
	}
	if meta.StatementHash != "" && hash != meta.StatementHash {
		return nil, errors.New("原始账单文件哈希与预览不一致，请重新上传账单")
	}
	if meta.ExpectedEntryCount != nil && len(entries) != *meta.ExpectedEntryCount {
		return nil, fmt.Errorf("待写入交易数量与预览不一致：预览 %d 条，提交 %d 条，请重新生成预览", *meta.ExpectedEntryCount, len(entries))
	}
	if len(entries) == 0 {
		return nil, errors.New("没有可写入的交易")
	}
	beanText, err := s.validateAndRenderImportEntries(entries)
	if err != nil {
		return nil, err
	}
	summary := parseBeanSummary(beanText)
	if summary.CandidateCount == 0 || summary.DateStart == "" || summary.DateEnd == "" {
		return nil, errors.New("去重后没有可写入的交易")
	}
	accounts, err := ParseAccounts(s.cfg)
	if err != nil {
		return nil, err
	}
	accountSet := map[string]bool{}
	for _, account := range accounts {
		accountSet[account.Account] = true
	}
	fallbackDocumentAccount := ""
	if len(entries) > 0 {
		fallbackDocumentAccount = entries[0].FundingAccount
		if fallbackDocumentAccount == "" && len(entries[0].Postings) > 0 {
			fallbackDocumentAccount = entries[0].Postings[len(entries[0].Postings)-1].Account
		}
	}
	outputFile := uniquePath(importOutputPath(s.cfg, summary.DateStart, summary.DateEnd, provider, importID[:min(len(importID), 6)]))
	documentFile := uniquePath(importDocumentPath(s.cfg, summary.DateStart, summary.DateEnd, provider, meta.OriginalFilename, importID[:min(len(importID), 6)]))
	monthFile := transactionFileForDate(s.cfg, summary.DateStart)
	documentAccount := providerDocumentAccount(provider, accountSet, fallbackDocumentAccount)
	if err := s.writeImportedBeanFile(outputFile, monthFile, beanText, provider, summary.DateStart, summary.DateEnd, meta.InputFile, documentFile, documentAccount); err != nil {
		return nil, err
	}
	return ginH{"ok": true, "outputFile": outputFile, "includeFile": monthFile, "documentFile": documentFile, "count": summary.CandidateCount, "beanText": beanText}, nil
}

func (s *Server) saveImportUpload(header *multipart.FileHeader, providerOverride, importID string) (importMeta, error) {
	if header.Size > 10*1024*1024 {
		return importMeta{}, errors.New("账单文件超过 10MB")
	}
	originalName := header.Filename
	if strings.TrimSpace(originalName) == "" {
		originalName = "bill"
	}
	ext := strings.ToLower(filepath.Ext(originalName))
	content, err := readMultipartFile(header)
	if err != nil {
		return importMeta{}, err
	}
	detection, err := detectBillProvider(originalName, content, providerOverride)
	if err != nil {
		return importMeta{}, err
	}
	cfg := importProviderConfigs[detection.Provider]
	if !stringIn(ext, cfg.Extensions) {
		return importMeta{}, fmt.Errorf("%s账单文件类型不正确，应为 %s", cfg.Label, strings.Join(cfg.Extensions, "/"))
	}
	dir := importRuntimeDir(s.cfg, importID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return importMeta{}, err
	}
	inputFile := filepath.Join(dir, "original"+ext)
	if err := os.WriteFile(inputFile, content, 0o600); err != nil {
		return importMeta{}, err
	}
	meta := importMeta{Provider: detection.Provider, OriginalFilename: originalName, InputFile: inputFile, ProviderDetection: detection, StatementHash: sha256Hex(content)}
	if err := s.writeImportMeta(importID, meta); err != nil {
		return importMeta{}, err
	}
	return meta, nil
}

func (s *Server) ensureImportRequirements(provider string) error {
	cfg, ok := importProviderConfigs[provider]
	if !ok {
		return errors.New("provider must be alipay, wechat or cmb")
	}
	required := []string{"main.bean", cfg.Config, "scripts/dedup_import.py"}
	for _, relative := range required {
		if _, err := os.Stat(filepath.Join(s.cfg.LedgerRoot, relative)); err != nil {
			return fmt.Errorf("账本缺少必要文件: %s", relative)
		}
	}
	return nil
}

func (s *Server) prepareProviderInput(provider, inputFile, originalFilename, importID string) (preparedImportInput, error) {
	if provider != "cmb" {
		return preparedImportInput{InputFile: inputFile}, nil
	}
	ext := strings.ToLower(filepath.Ext(originalFilename))
	warnings := []string{}
	normalizedFile := inputFile
	if ext == ".pdf" {
		converted, err := writeCmbPDFCSV(inputFile, previewPath(s.cfg, importID, "cmb-normalized.csv"))
		if err != nil {
			return preparedImportInput{}, err
		}
		normalizedFile = converted.InputFile
		warnings = append(warnings, converted.Warnings...)
	} else if ext == ".csv" {
		warnings = append(warnings, "当前上传的是招商银行信用卡 CSV；如 CSV 来自外部 PDF 转换且卡号列错位，建议改传原始 PDF。")
	}
	prefilteredFile := previewPath(s.cfg, importID, "cmb-prefiltered.csv")
	prefilter, err := s.prefilterCmbCSV(normalizedFile, prefilteredFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	warnings = append(warnings, prefilter.Warnings...)
	return preparedImportInput{InputFile: prefilteredFile, Warnings: warnings, RawRowCount: prefilter.RawRowCount, FilteredRowCount: prefilter.FilteredRowCount, PrefilterSkipped: prefilter.Skipped}, nil
}

type cmbCSVPrefilter struct {
	RawRowCount      int
	FilteredRowCount int
	Skipped          int
	Warnings         []string
}

func (s *Server) prefilterCmbCSV(inputFile, outputFile string) (cmbCSVPrefilter, error) {
	textBytes, err := os.ReadFile(inputFile)
	if err != nil {
		return cmbCSVPrefilter{}, err
	}
	text := normalizeCmbCSVText(string(textBytes))
	lines := nonEmptyLines(text)
	if len(lines) < 2 {
		return cmbCSVPrefilter{}, errors.New("招商银行信用卡 CSV 缺少表头")
	}
	title, header, body := lines[0], lines[1], lines[2:]
	prefixes := s.cmbPaymentSourcePrefixes()
	kept := []string{}
	skipped, suspicious := 0, 0
	amountShiftRe := regexp.MustCompile(`^-?\d[\d,]*\.\d{2}\([A-Z]+\)$`)
	for _, line := range body {
		cells := parseCSVLine(line)
		if len(cells) > 4 && amountShiftRe.MatchString(cells[4]) && (len(cells) <= 5 || cells[5] == "") {
			suspicious++
		}
		summary := ""
		if len(cells) > 2 {
			summary = cells[2]
		}
		handledExternally := false
		for _, prefix := range prefixes {
			if strings.HasPrefix(summary, prefix) {
				handledExternally = true
				break
			}
		}
		if handledExternally {
			skipped++
			continue
		}
		kept = append(kept, line)
	}
	warnings := []string{fmt.Sprintf("招商银行信用卡账单 Web 前置过滤 %d 条严格前缀匹配的支付宝/财付通/微信支付明细，避免重复导入。", skipped)}
	if suspicious > 0 {
		warnings = append(warnings, fmt.Sprintf("检测到 %d 条 CSV 疑似卡号末四位丢失/列错位；建议上传原始 PDF 以恢复卡号列。", suspicious))
	}
	if err := os.WriteFile(outputFile, []byte(strings.Join(append([]string{title, header}, kept...), "\n")), 0o600); err != nil {
		return cmbCSVPrefilter{}, err
	}
	return cmbCSVPrefilter{RawRowCount: len(body), FilteredRowCount: len(kept), Skipped: skipped, Warnings: warnings}, nil
}

func (s *Server) runTranslate(provider, inputFile, outputFile string) error {
	cfg := importProviderConfigs[provider]
	args := []string{"translate", "-p", provider, "--target", "beancount", "--config", cfg.Config, "--output", outputFile, inputFile}
	_, err := s.runCommand(env("DOUBLE_ENTRY_GENERATOR_BIN", "double-entry-generator"), args)
	return err
}

func (s *Server) runDedup(provider, generatedFile, outputFile string, alipayFundRounding bool, dryRun bool) (string, error) {
	args := []string{"scripts/dedup_import.py", generatedFile}
	if provider == "cmb" {
		args = append(args, "--credit-card")
	}
	if dryRun {
		args = append(args, "--dry-run")
	}
	if outputFile != "" {
		args = append(args, "-o", outputFile)
	}
	if alipayFundRounding {
		args = append(args, "--alipay-fund-rounding")
	}
	return s.runCommand(env("PYTHON_BIN", "python3"), args)
}

func (s *Server) runDedupToFile(provider, generatedFile, outputFile string, alipayFundRounding bool) error {
	_, err := s.runDedup(provider, generatedFile, outputFile, alipayFundRounding, false)
	return err
}

func (s *Server) runCommand(command string, args []string) (string, error) {
	cmd := exec.Command(command, args...)
	cmd.Dir = s.cfg.LedgerRoot
	cmd.Env = commandEnv()
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return "", fmt.Errorf("找不到命令 %s。请设置 DOUBLE_ENTRY_GENERATOR_BIN/PYTHON_BIN 为绝对路径，或确认 Web 服务 PATH 中可以访问 double-entry-generator / python3", command)
		}
		detail := strings.TrimSpace(strings.Join([]string{stderr.String(), stdout.String(), err.Error()}, "\n"))
		return "", errors.New(detail)
	}
	return stdout.String(), nil
}

func commandEnv() []string {
	pathParts := []string{os.Getenv("PATH")}
	if home := os.Getenv("HOME"); home != "" {
		pathParts = append(pathParts, filepath.Join(home, ".local", "bin"))
	}
	pathParts = append(pathParts, "/opt/homebrew/bin", "/usr/local/bin")
	envs := os.Environ()
	envs = append(envs, "PATH="+strings.Join(pathParts, string(os.PathListSeparator)))
	return envs
}

func (s *Server) validateAndRenderImportEntries(entries []ImportEntry) (string, error) {
	accounts, err := ParseAccounts(s.cfg)
	if err != nil {
		return "", err
	}
	accountSet := map[string]bool{}
	for _, account := range accounts {
		accountSet[account.Account] = true
	}
	blocks := make([]string, 0, len(entries))
	for index, entry := range entries {
		if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`).MatchString(entry.Date) {
			return "", fmt.Errorf("第 %d 条日期无效", index+1)
		}
		if !accountSet[entry.CategoryAccount] {
			return "", fmt.Errorf("账户不存在: %s", entry.CategoryAccount)
		}
		if entry.FundingAccount != "" && !accountSet[entry.FundingAccount] {
			return "", fmt.Errorf("账户不存在: %s", entry.FundingAccount)
		}
		postings := append([]EntryPosting{}, entry.Postings...)
		if len(postings) == 0 {
			amount := cents(fmt.Sprintf("%.2f", entry.Amount))
			postings = []EntryPosting{{Account: entry.CategoryAccount, Amount: fromCents(amount), Currency: entry.Currency}, {Account: entry.FundingAccount, Amount: fromCents(-amount), Currency: entry.Currency}}
		}
		categoryIndex := -1
		for i, posting := range postings {
			if posting.Account == entry.CategoryAccount || strings.HasPrefix(posting.Account, "Expenses:") || strings.HasPrefix(posting.Account, "Income:") {
				categoryIndex = i
				break
			}
		}
		if categoryIndex >= 0 {
			postings[categoryIndex].Account = entry.CategoryAccount
		}
		for _, posting := range postings {
			if !accountSet[posting.Account] {
				return "", fmt.Errorf("账户不存在: %s", posting.Account)
			}
		}
		metadata := map[string]MetadataValue{}
		for key, value := range entry.Metadata {
			if key == "filename" || strings.TrimSpace(value) == "" || !regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*$`).MatchString(key) {
				continue
			}
			metadata[key] = value
		}
		flag := entry.Flag
		if flag != "!" {
			flag = "*"
		}
		lines := []string{fmt.Sprintf(`%s %s "%s" "%s"`, entry.Date, flag, escapeBean(entry.Payee), escapeBean(entry.Narration))}
		keys := make([]string, 0, len(metadata))
		for key := range metadata {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			lines = append(lines, fmt.Sprintf("  %s: %s", key, metadataValueToBean(metadata[key])))
		}
		for _, posting := range postings {
			currency := posting.Currency
			if currency == "" {
				currency = "CNY"
			}
			lines = append(lines, fmt.Sprintf("  %-34s %12s %s", posting.Account, posting.Amount, currency))
		}
		blocks = append(blocks, strings.Join(lines, "\n"))
	}
	return strings.TrimSpace(strings.Join(blocks, "\n\n")), nil
}

func (s *Server) writeImportedBeanFile(outputFile, monthFile, beanText, provider, start, end, sourceFile, documentFile, documentAccount string) error {
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
				_ = os.MkdirAll(filepath.Dir(file), 0o755)
				_ = os.WriteFile(file, snap.content, 0o644)
			} else {
				_ = os.Remove(file)
			}
		}
	}
	if err := s.writer.ensureMonthlyFileAndInclude(monthFile, start, snapshot); err != nil {
		return err
	}
	for _, file := range []string{monthFile, outputFile, documentFile} {
		if file != "" {
			if err := snapshot(file); err != nil {
				restore()
				return err
			}
		}
	}
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o755); err != nil {
		restore()
		return err
	}
	documentLine := ""
	if sourceFile != "" && documentFile != "" {
		if err := os.MkdirAll(filepath.Dir(documentFile), 0o755); err != nil {
			restore()
			return err
		}
		if err := copyFile(sourceFile, documentFile); err != nil {
			restore()
			return err
		}
		documentLine = documentDirective(end, documentAccount, outputFile, documentFile) + "\n\n"
	}
	header := fmt.Sprintf("; %s import: %s .. %s\n", importProviderTitle(provider), start, end)
	if err := os.WriteFile(outputFile, []byte(header+documentLine+strings.TrimRight(beanText, "\n")+"\n"), 0o644); err != nil {
		restore()
		return err
	}
	includeLine := includeLineRelative(monthFile, outputFile)
	monthBefore, err := os.ReadFile(monthFile)
	if err != nil {
		restore()
		return err
	}
	hasInclude := false
	for _, line := range strings.Split(string(monthBefore), "\n") {
		if strings.TrimSpace(line) == includeLine {
			hasInclude = true
			break
		}
	}
	if !hasInclude {
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

type ginH map[string]any

func detectBillProvider(filename string, content []byte, override string) (providerDetection, error) {
	if override == "alipay" || override == "wechat" || override == "cmb" {
		return providerDetection{Provider: override, Reason: "手动指定", Confidence: "high"}, nil
	}
	ext := strings.ToLower(filepath.Ext(filename))
	sample := string(content)
	if len(content) > 32768 {
		sample = string(content[:32768])
	}
	if ext == ".xlsx" || ext == ".xls" {
		return providerDetection{Provider: "wechat", Reason: "Excel 文件通常为微信支付账单", Confidence: "high"}, nil
	}
	if ext == ".pdf" && strings.HasPrefix(sample, "%PDF-") {
		return providerDetection{Provider: "cmb", Reason: "PDF 文件将按招商银行信用卡账单解析", Confidence: "medium"}, nil
	}
	if ext == ".csv" {
		if regexp.MustCompile(`招商银行信用卡对账单|交易日,记账日,交易摘要,人民币金额,卡号末四位,交易地金额`).MatchString(sample) {
			return providerDetection{Provider: "cmb", Reason: "CSV 内容包含招商银行信用卡账单字段", Confidence: "high"}, nil
		}
		if regexp.MustCompile(`支付宝|交易号|商家订单号|交易创建时间|收支`).MatchString(sample) {
			return providerDetection{Provider: "alipay", Reason: "CSV 内容包含支付宝账单字段", Confidence: "high"}, nil
		}
		return providerDetection{Provider: "alipay", Reason: "CSV 文件默认按支付宝账单处理", Confidence: "medium"}, nil
	}
	return providerDetection{}, errors.New("无法自动识别账单类型，请上传支付宝 CSV、微信 XLSX/XLS 或招商银行信用卡 PDF。需要时可使用手动覆盖。")
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
	configFile := filepath.Join(s.cfg.LedgerRoot, importProviderConfigs["cmb"].Config)
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
			options = append(options, ginH{"account": account.Account, "label": account.Label, "group": account.Group, "active": account.Active})
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
	preferred := map[string]string{"alipay": "Assets:CN:Alipay:Balance", "wechat": "Assets:CN:Wechat:Balance", "cmb": "Liabilities:CN:CMB:CreditCard"}[provider]
	if accounts[preferred] {
		return preferred
	}
	if fallback != "" && accounts[fallback] {
		return fallback
	}
	return preferred
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
	switch provider {
	case "alipay":
		return "Alipay"
	case "wechat":
		return "WeChat Pay"
	case "cmb":
		return "CMB Credit Card"
	default:
		return provider
	}
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
