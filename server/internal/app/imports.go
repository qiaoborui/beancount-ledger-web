package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"mime/multipart"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
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
	Config        string
	Output        string
	Extensions    []string
	Label         string
	Detail        string
	DEGProviderID string
}

type providerDetection struct {
	Provider   string `json:"provider"`
	Reason     string `json:"reason"`
	Confidence string `json:"confidence"`
}

type importMeta struct {
	Provider           string            `json:"provider"`
	OriginalFilename   string            `json:"originalFilename"`
	InputFilename      string            `json:"inputFilename,omitempty"`
	InputFile          string            `json:"inputFile"`
	InputFileKey       string            `json:"inputFileKey,omitempty"`
	DocumentFile       string            `json:"documentFile,omitempty"`
	DocumentFileKey    string            `json:"documentFileKey,omitempty"`
	GeneratedFileKey   string            `json:"generatedFileKey,omitempty"`
	DedupedFileKey     string            `json:"dedupedFileKey,omitempty"`
	ProviderDetection  providerDetection `json:"providerDetection"`
	StatementHash      string            `json:"statementHash"`
	DateStart          string            `json:"dateStart,omitempty"`
	DateEnd            string            `json:"dateEnd,omitempty"`
	ExpectedEntryCount *int              `json:"expectedEntryCount,omitempty"`
}

type preparedImportInput struct {
	InputFile        string
	Warnings         []string
	RawRowCount      int
	FilteredRowCount int
	PrefilterSkipped int
	DateStart        string
	DateEnd          string
}

type beanSummary struct {
	CandidateCount int
	DateStart      string
	DateEnd        string
}

type ImportDocument struct {
	Path      string `json:"path"`
	Name      string `json:"name"`
	Year      string `json:"year"`
	Ext       string `json:"ext"`
	Provider  string `json:"provider,omitempty"`
	DateStart string `json:"dateStart,omitempty"`
	DateEnd   string `json:"dateEnd,omitempty"`
	Size      int64  `json:"size"`
	ModTime   string `json:"modTime"`
}

func (s *Server) createImportPreview(ctx context.Context, providerOverride string, alipayFundRounding bool, header *multipart.FileHeader, originalHeader *multipart.FileHeader) (ginH, error) {
	importID := randomID()
	upload, err := s.saveImportUpload(ctx, header, originalHeader, providerOverride, importID)
	if err != nil {
		return nil, err
	}
	importer, err := s.ensureImportRequirements(upload.Provider)
	if err != nil {
		return nil, err
	}

	generatedFile := previewPath(s.cfg, importID, importer.ProviderConfig().Output)
	dedupedFile := previewPath(s.cfg, importID, upload.Provider+"-preview-deduped.bean")
	inputFilename := upload.InputFilename
	if inputFilename == "" {
		inputFilename = upload.OriginalFilename
	}
	prepared, err := importer.Prepare(s, importFileInput{InputFile: upload.InputFile, OriginalFilename: inputFilename, ImportID: importID})
	if err != nil {
		return nil, err
	}
	if err := importer.Generate(ctx, s, prepared, generatedFile); err != nil {
		return nil, err
	}
	rawGeneratedBean, err := os.ReadFile(generatedFile)
	if err != nil {
		return nil, err
	}
	generatedKey, err := s.putImportFile(ctx, importID, "generated", rawGeneratedBean)
	if err != nil {
		return nil, err
	}
	upload.GeneratedFileKey = generatedKey
	sourceAnalysis, sourceWarnings := importer.AnalyzeSource(s, prepared, string(rawGeneratedBean))
	prepared.Warnings = append(prepared.Warnings, sourceWarnings...)
	generatedBean := transactionOnlyBeanText(string(rawGeneratedBean))
	generatedSummary := parseBeanSummary(generatedBean)
	dedupReport := ""
	if generatedSummary.CandidateCount == 0 && prepared.RawRowCount > 0 && prepared.FilteredRowCount == 0 {
		dedupReport = "前置过滤后没有候选交易，已跳过去重。"
		if err := os.WriteFile(dedupedFile, []byte(""), 0o600); err != nil {
			return nil, err
		}
	} else if githubAPIEnabled(s.cfg) {
		dedupedBean, skipped, err := s.dedupGeneratedBeanWithReadModel(ctx, generatedBean, upload.StatementHash)
		if err != nil {
			return nil, err
		}
		dedupReport = fmt.Sprintf("GitHub API 读模型去重：生成 %d 条，跳过 %d 条已存在，待写入 %d 条。", generatedSummary.CandidateCount, skipped, generatedSummary.CandidateCount-skipped)
		if err := os.WriteFile(dedupedFile, []byte(dedupedBean), 0o600); err != nil {
			return nil, err
		}
	} else {
		dedupReport, err = s.runDedup(importer, generatedFile, "", alipayFundRounding, true)
		if err != nil {
			return nil, err
		}
		if err := s.runDedupToFile(importer, generatedFile, dedupedFile, alipayFundRounding); err != nil {
			return nil, err
		}
	}
	dedupedRaw := []byte{}
	if raw, err := os.ReadFile(dedupedFile); err == nil {
		dedupedRaw = raw
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	dedupedKey, err := s.putImportFile(ctx, importID, "deduped", dedupedRaw)
	if err != nil {
		return nil, err
	}
	upload.DedupedFileKey = dedupedKey

	dedupedBean := transactionOnlyBeanText(string(dedupedRaw))
	entries, err := parsePreviewEntries(dedupedBean)
	if err != nil {
		return nil, err
	}
	importer.DecorateEntries(upload, entries)
	summary := parseBeanSummary(dedupedBean)
	skippedDuplicateCount := generatedSummary.CandidateCount - summary.CandidateCount
	if skippedDuplicateCount < 0 {
		skippedDuplicateCount = 0
	}
	excludedRowCount := importer.ExcludedRowCount(prepared, sourceAnalysis, generatedSummary)
	warnings := append([]string{}, prepared.Warnings...)
	if githubAPIEnabled(s.cfg) {
		warnings = append(warnings, "GitHub API 写入模式使用 Postgres 读模型做预览去重；提交后等待本地 worker 索引更新。")
	}
	if summary.CandidateCount == 0 {
		warnings = append(warnings, "去重后没有发现可写入的新交易。")
	}
	if !strings.Contains(generatedBean, "orderId") {
		warnings = append(warnings, "生成结果中没有发现 orderId，将只能使用 fallback 去重。")
	}
	providerWarnings, err := importer.PreviewWarnings(prepared, sourceAnalysis, generatedSummary, summary, generatedBean)
	if err != nil {
		return nil, err
	}
	warnings = append(warnings, providerWarnings...)
	dateStart := valueOr(summary.DateStart, prepared.DateStart)
	dateEnd := valueOr(summary.DateEnd, prepared.DateEnd)
	expected := len(entries)
	upload.ExpectedEntryCount = &expected
	upload.DateStart = dateStart
	upload.DateEnd = dateEnd
	if err := s.writeImportMeta(ctx, importID, upload); err != nil {
		return nil, err
	}
	accountOptions, err := s.importAccountOptions()
	if err != nil {
		return nil, err
	}
	rawRowCount, filteredRowCount := importer.RowCounts(prepared, sourceAnalysis, generatedSummary)
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
		"dateStart":             nullableString(dateStart),
		"dateEnd":               nullableString(dateEnd),
		"warnings":              warnings,
	}, nil
}

func (s *Server) dedupGeneratedBeanWithReadModel(ctx context.Context, beanText, statementHash string) (string, int, error) {
	snapshot, err := s.ledgerSnapshotLite(ctx)
	if err != nil {
		return "", 0, err
	}
	return dedupImportBeanText(snapshot.Transactions, beanText, statementHash)
}

func dedupImportBeanText(existing []Transaction, beanText, statementHash string) (string, int, error) {
	result := ParseBeanLines(beanTextLines("<import-dedup>", beanText))
	if len(result.Errors) > 0 {
		return "", 0, result.Errors[0]
	}
	index := newImportDuplicateIndex(existing)
	kept := []string{}
	skipped := 0
	for _, entry := range result.Entries {
		if entry.Kind != "transaction" || len(entry.RawLines) == 0 {
			continue
		}
		if index.seenBeanEntry(entry, statementHash) {
			skipped++
			continue
		}
		kept = append(kept, strings.TrimRight(strings.Join(entry.RawLines, "\n"), "\n"))
	}
	return strings.TrimSpace(strings.Join(kept, "\n\n")), skipped, nil
}

type importDuplicateIndex struct {
	orderIDs            map[string]bool
	signatures          map[string]bool
	postingSignatures   map[string]bool
	statementSignatures map[string]bool
}

func newImportDuplicateIndex(existing []Transaction) importDuplicateIndex {
	index := importDuplicateIndex{
		orderIDs:            map[string]bool{},
		signatures:          map[string]bool{},
		postingSignatures:   map[string]bool{},
		statementSignatures: map[string]bool{},
	}
	for _, txn := range existing {
		if orderID := metadataString(txn.Metadata["orderId"]); orderID != "" {
			index.orderIDs[orderID] = true
		}
		signature := transactionDuplicateSignature(txn.Date, txn.Payee, txn.Narration, txn.Postings)
		if signature != "" {
			index.signatures[signature] = true
			if statementHash := metadataString(txn.Metadata["statementHash"]); statementHash != "" {
				index.statementSignatures[statementHash+"|"+signature] = true
			}
		}
		for _, signature := range importDuplicatePostingSignatures(txn.Date, txn.Postings) {
			index.postingSignatures[signature] = true
		}
	}
	return index
}

func (index importDuplicateIndex) seenBeanEntry(entry BeanEntry, fallbackStatementHash string) bool {
	if orderID := metadataString(entry.Metadata["orderId"]); orderID != "" && index.orderIDs[orderID] {
		return true
	}
	signature := beanEntryDuplicateSignature(entry)
	if signature == "" {
		return false
	}
	statementHash := metadataString(entry.Metadata["statementHash"])
	if statementHash == "" {
		statementHash = fallbackStatementHash
	}
	if statementHash != "" && index.statementSignatures[statementHash+"|"+signature] {
		return true
	}
	for _, postingSignature := range beanEntryDuplicatePostingSignatures(entry) {
		if index.postingSignatures[postingSignature] {
			return true
		}
	}
	return index.signatures[signature]
}

func beanEntryDuplicateSignature(entry BeanEntry) string {
	postings := make([]Posting, 0, len(entry.Postings))
	for _, posting := range entry.Postings {
		if posting.Account == "" {
			continue
		}
		postings = append(postings, Posting{Account: posting.Account, Amount: posting.Amount, Currency: posting.Currency})
	}
	return transactionDuplicateSignature(entry.Date, entry.Payee, entry.Narration, postings)
}

func transactionDuplicateSignature(date, payee, narration string, postings []Posting) string {
	if date == "" || len(postings) == 0 {
		return ""
	}
	parts := make([]string, 0, len(postings))
	for _, posting := range postings {
		if posting.Account == "" {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s:%d:%s", posting.Account, posting.Amount, posting.Currency))
	}
	if len(parts) == 0 {
		return ""
	}
	sort.Strings(parts)
	return strings.Join([]string{date, strings.TrimSpace(payee), strings.TrimSpace(narration), strings.Join(parts, ",")}, "|")
}

func beanEntryDuplicatePostingSignatures(entry BeanEntry) []string {
	postings := make([]Posting, 0, len(entry.Postings))
	for _, posting := range entry.Postings {
		if posting.Account == "" {
			continue
		}
		postings = append(postings, Posting{Account: posting.Account, Amount: posting.Amount, Currency: posting.Currency})
	}
	return importDuplicatePostingSignatures(entry.Date, postings)
}

func importDuplicatePostingSignatures(date string, postings []Posting) []string {
	if date == "" {
		return nil
	}
	signatures := []string{}
	for _, posting := range postings {
		if !importDuplicateFundingAccount(posting.Account) || posting.Amount == 0 {
			continue
		}
		signatures = append(signatures, fmt.Sprintf("%s|%s|%d|%s", date, posting.Account, posting.Amount, posting.Currency))
	}
	sort.Strings(signatures)
	return signatures
}

func importDuplicateFundingAccount(account string) bool {
	return strings.HasPrefix(account, "Assets:") || strings.HasPrefix(account, "Liabilities:")
}

func (s *Server) commitImport(ctx context.Context, importID, provider string, entries []ImportEntry) (ginH, error) {
	if _, err := s.ensureImportRequirements(provider); err != nil {
		return nil, err
	}
	meta, err := s.readImportMeta(ctx, importID)
	if err != nil {
		return nil, errors.New("找不到导入预览，请重新上传账单")
	}
	if meta.Provider != provider {
		return nil, errors.New("导入 provider 与预览不一致")
	}
	if err := s.materializeImportMetaFiles(ctx, importID, &meta); err != nil {
		return nil, err
	}
	hash, err := fileSHA256(meta.InputFile)
	if err != nil {
		return nil, err
	}
	if meta.StatementHash != "" && hash != meta.StatementHash {
		return nil, errors.New("原始账单文件哈希与预览不一致，请重新上传账单")
	}
	if meta.ExpectedEntryCount != nil && len(entries) > *meta.ExpectedEntryCount {
		return nil, fmt.Errorf("待写入交易数量超过预览数量：预览 %d 条，提交 %d 条，请重新生成预览", *meta.ExpectedEntryCount, len(entries))
	}
	beanText := ""
	summary := beanSummary{DateStart: meta.DateStart, DateEnd: meta.DateEnd}
	if len(entries) > 0 {
		var err error
		beanText, err = s.validateAndRenderImportEntries(entries)
		if err != nil {
			return nil, err
		}
		summary = parseBeanSummary(beanText)
	}
	if summary.DateStart == "" || summary.DateEnd == "" {
		return nil, errors.New("账单没有可归档的日期范围，请重新上传账单")
	}
	snapshot, err := s.ledgerSnapshot(ctx)
	if err != nil {
		return nil, err
	}
	accountSet := map[string]bool{}
	for _, account := range snapshot.Accounts {
		accountSet[account.Account] = true
	}
	fallbackDocumentAccount := ""
	if len(entries) > 0 {
		fallbackDocumentAccount = entries[0].FundingAccount
		if fallbackDocumentAccount == "" && len(entries[0].Postings) > 0 {
			fallbackDocumentAccount = entries[0].Postings[len(entries[0].Postings)-1].Account
		}
	}
	outputFile := importOutputPath(s.cfg, summary.DateStart, summary.DateEnd, provider, importID[:min(len(importID), 6)])
	documentFile := importDocumentPath(s.cfg, summary.DateStart, summary.DateEnd, provider, meta.OriginalFilename, importID[:min(len(importID), 6)])
	monthFile := transactionFileForDate(s.cfg, summary.DateStart)
	documentAccount := providerDocumentAccount(provider, accountSet, fallbackDocumentAccount)
	sourceDocumentFile := meta.InputFile
	if meta.DocumentFile != "" {
		sourceDocumentFile = meta.DocumentFile
	}
	written, err := s.writeImportedBeanFile(outputFile, monthFile, beanText, provider, summary.DateStart, summary.DateEnd, sourceDocumentFile, documentFile, documentAccount)
	if err != nil {
		return nil, err
	}
	return ginH{"ok": true, "outputFile": written.OutputFile, "includeFile": written.MonthFile, "documentFile": written.DocumentFile, "count": summary.CandidateCount, "beanText": beanText, "readModelPending": ledgerReadModelEnabled(s.cfg)}, nil
}

func (s *Server) listImportDocuments() ([]ImportDocument, error) {
	if githubAPIEnabled(s.cfg) {
		client, err := newGitHubLedgerClient(s.cfg)
		if err != nil {
			return nil, err
		}
		return client.listImportDocuments(context.Background())
	}
	root := transactionsDir(s.cfg)
	documents := []ImportDocument{}
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return documents, nil
		}
		return nil, err
	}
	for _, yearEntry := range entries {
		if !yearEntry.IsDir() || !regexp.MustCompile(`^\d{4}$`).MatchString(yearEntry.Name()) {
			continue
		}
		dir := filepath.Join(root, yearEntry.Name(), "documents", "imports")
		files, err := os.ReadDir(dir)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return nil, err
		}
		for _, file := range files {
			if file.IsDir() {
				continue
			}
			info, err := file.Info()
			if err != nil {
				return nil, err
			}
			rel, err := filepath.Rel(s.cfg.LedgerRoot, filepath.Join(dir, file.Name()))
			if err != nil {
				return nil, err
			}
			document := importDocumentInfo(filepath.ToSlash(rel), yearEntry.Name(), info.Name(), info.Size(), info.ModTime())
			documents = append(documents, document)
		}
	}
	sort.Slice(documents, func(i, j int) bool {
		if documents[i].ModTime == documents[j].ModTime {
			return documents[i].Path > documents[j].Path
		}
		return documents[i].ModTime > documents[j].ModTime
	})
	return documents, nil
}

func importDocumentInfo(path, year, name string, size int64, modTime time.Time) ImportDocument {
	document := ImportDocument{
		Path:    path,
		Name:    name,
		Year:    year,
		Ext:     strings.ToLower(filepath.Ext(name)),
		Size:    size,
		ModTime: modTime.Format(time.RFC3339),
	}
	base := strings.TrimSuffix(name, filepath.Ext(name))
	if before, after, ok := strings.Cut(base, "_"); ok {
		document.DateStart = before
		if len(after) > len("2006-01-02-") && after[10] == '-' {
			document.DateEnd = after[:10]
			providerPart := after[11:]
			providers := importProviderIDs()
			sort.Slice(providers, func(i, j int) bool { return len(providers[i]) > len(providers[j]) })
			for _, provider := range providers {
				if providerPart == provider || strings.HasPrefix(providerPart, provider+"-") {
					document.Provider = provider
					break
				}
			}
		}
	}
	return document
}

func cleanImportDocumentPath(cfg Config, rawPath string) (string, string, error) {
	path, err := cleanImportDocumentRel(rawPath)
	if err != nil {
		return "", "", err
	}
	full := filepath.Join(cfg.LedgerRoot, filepath.FromSlash(path))
	rel, err := filepath.Rel(cfg.LedgerRoot, full)
	if err != nil || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || rel == ".." || filepath.IsAbs(rel) {
		return "", "", errors.New("invalid import document path")
	}
	if githubAPIEnabled(cfg) {
		return path, full, nil
	}
	info, err := os.Stat(full)
	if err != nil {
		return "", "", err
	}
	if info.IsDir() {
		return "", "", errors.New("import document path is a directory")
	}
	return path, full, nil
}

func cleanImportDocumentRel(rawPath string) (string, error) {
	trimmed := strings.TrimSpace(rawPath)
	if trimmed == "" {
		return "", errors.New("path is required")
	}
	if strings.Contains(trimmed, "\x00") || filepath.IsAbs(trimmed) {
		return "", errors.New("invalid import document path")
	}
	path := filepath.ToSlash(filepath.Clean(trimmed))
	if path == "." || strings.HasPrefix(path, "../") || strings.Contains(path, "/../") {
		return "", errors.New("invalid import document path")
	}
	parts := strings.Split(path, "/")
	if len(parts) != 5 || parts[0] != "transactions" || !regexp.MustCompile(`^\d{4}$`).MatchString(parts[1]) || parts[2] != "documents" || parts[3] != "imports" || parts[4] == "" {
		return "", errors.New("path is outside import documents")
	}
	return path, nil
}

func (s *Server) saveImportUpload(ctx context.Context, header, originalHeader *multipart.FileHeader, providerOverride, importID string) (importMeta, error) {
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
	inputFileKey, err := s.putImportFile(ctx, importID, "original", content)
	if err != nil {
		return importMeta{}, err
	}
	if err := os.WriteFile(inputFile, content, 0o600); err != nil {
		return importMeta{}, err
	}
	meta := importMeta{Provider: detection.Provider, OriginalFilename: originalName, InputFilename: originalName, InputFile: inputFile, InputFileKey: inputFileKey, ProviderDetection: detection, StatementHash: sha256Hex(content)}
	if originalHeader != nil {
		if originalHeader.Size > 10*1024*1024 {
			return importMeta{}, errors.New("原始账单文件超过 10MB")
		}
		originalDocumentName := strings.TrimSpace(originalHeader.Filename)
		if originalDocumentName == "" {
			originalDocumentName = originalName
		}
		originalContent, err := readMultipartFile(originalHeader)
		if err != nil {
			return importMeta{}, err
		}
		originalExt := strings.ToLower(filepath.Ext(originalDocumentName))
		if originalExt == "" {
			originalExt = ".pdf"
		}
		documentFile := filepath.Join(dir, "document"+originalExt)
		documentFileKey, err := s.putImportFile(ctx, importID, "document", originalContent)
		if err != nil {
			return importMeta{}, err
		}
		if err := os.WriteFile(documentFile, originalContent, 0o600); err != nil {
			return importMeta{}, err
		}
		meta.OriginalFilename = originalDocumentName
		meta.DocumentFile = documentFile
		meta.DocumentFileKey = documentFileKey
	}
	if err := s.writeImportMeta(ctx, importID, meta); err != nil {
		return importMeta{}, err
	}
	return meta, nil
}

func (s *Server) ensureImportRequirements(provider string) (billImporter, error) {
	importer, ok := importProvider(provider)
	if !ok {
		return nil, fmt.Errorf("provider must be %s", strings.Join(importProviderIDs(), ", "))
	}
	cfg := importer.ProviderConfig()
	if githubAPIEnabled(s.cfg) {
		return importer, s.ensureGitHubImportRequirementFiles(context.Background(), importer.ImportEngine().RequiredFiles(cfg))
	}
	required := importer.ImportEngine().RequiredFiles(cfg)
	for _, relative := range required {
		if _, err := os.Stat(filepath.Join(s.cfg.LedgerRoot, relative)); err != nil {
			return nil, fmt.Errorf("账本缺少必要文件: %s", relative)
		}
	}
	return importer, nil
}

func (s *Server) ensureGitHubImportRequirementFiles(ctx context.Context, required []string) error {
	client, err := newGitHubLedgerClient(s.cfg)
	if err != nil {
		return err
	}
	remoteTx, err := client.beginTransaction(ctx)
	if err != nil {
		return err
	}
	for _, relative := range required {
		relative = filepath.ToSlash(filepath.Clean(relative))
		if relative == "." || relative == "main.bean" || relative == "scripts/dedup_import.py" {
			continue
		}
		content, err := remoteTx.readFile(filepath.Join(s.cfg.LedgerRoot, filepath.FromSlash(relative)))
		if err != nil {
			return fmt.Errorf("账本缺少必要文件: %s", relative)
		}
		full := filepath.Join(s.cfg.LedgerRoot, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(full), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(full, content, 0o600); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) prepareCmbInput(inputFile, originalFilename, importID string) (preparedImportInput, error) {
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

func (s *Server) runDedup(importer billImporter, generatedFile, outputFile string, alipayFundRounding bool, dryRun bool) (string, error) {
	args := []string{"scripts/dedup_import.py", generatedFile}
	args = append(args, importer.DedupArgs(importDedupOptions{AlipayFundRounding: alipayFundRounding})...)
	if dryRun {
		args = append(args, "--dry-run")
	}
	if outputFile != "" {
		args = append(args, "-o", outputFile)
	}
	return s.runCommand(env("PYTHON_BIN", "python3"), args)
}

func (s *Server) runDedupToFile(importer billImporter, generatedFile, outputFile string, alipayFundRounding bool) error {
	_, err := s.runDedup(importer, generatedFile, outputFile, alipayFundRounding, false)
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
			return "", fmt.Errorf("找不到命令 %s。请设置 PYTHON_BIN 为绝对路径，或确认 Web 服务 PATH 中可以访问 python3", command)
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
	snapshot, err := s.ledgerSnapshot(context.Background())
	if err != nil {
		return "", err
	}
	accountSet := map[string]bool{}
	for _, account := range snapshot.Accounts {
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
			if err := validateKnownCurrency("currency", posting.Currency, snapshot.Commodities); err != nil {
				return "", fmt.Errorf("第 %d 条: %w", index+1, err)
			}
			if posting.PriceCurrency != "" {
				if err := validateKnownCurrency("priceCurrency", posting.PriceCurrency, snapshot.Commodities); err != nil {
					return "", fmt.Errorf("第 %d 条: %w", index+1, err)
				}
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
			posting.Currency = currency
			lines = append(lines, renderEntryPosting(posting))
		}
		blocks = append(blocks, strings.Join(lines, "\n"))
	}
	return strings.TrimSpace(strings.Join(blocks, "\n\n")), nil
}

type writtenImportFiles struct {
	OutputFile   string
	MonthFile    string
	DocumentFile string
}

func (s *Server) writeImportedBeanFile(outputFile, monthFile, beanText, provider, start, end, sourceFile, documentFile, documentAccount string) (writtenImportFiles, error) {
	written := writtenImportFiles{MonthFile: monthFile}
	err := s.writer.RunTransactionWithSource(ledgerWriteSourceImportCommit, func(tx *LedgerWriteTransaction) error {
		var err error
		outputFile, err = tx.UniquePath(outputFile)
		if err != nil {
			return err
		}
		written.OutputFile = outputFile
		if err := s.writer.ensureMonthlyFileAndInclude(tx, monthFile, start); err != nil {
			return err
		}
		documentLine := ""
		if sourceFile != "" && documentFile != "" {
			documentFile, err = tx.UniquePath(documentFile)
			if err != nil {
				return err
			}
			if err := tx.CopyFile(sourceFile, documentFile, 0o600); err != nil {
				return err
			}
			written.DocumentFile = documentFile
			documentLine = documentDirective(end, documentAccount, outputFile, documentFile) + "\n\n"
		}
		header := fmt.Sprintf("; %s import: %s .. %s\n", importProviderTitle(provider), start, end)
		if err := tx.WriteFile(outputFile, []byte(header+documentLine+strings.TrimRight(beanText, "\n")+"\n"), 0o644); err != nil {
			return err
		}
		includeLine := includeLineRelative(monthFile, outputFile)
		monthBefore, err := tx.ReadFile(monthFile)
		if err != nil {
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
			if err := tx.WriteFile(monthFile, []byte(string(monthBefore)+sep+includeLine+"\n"), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
	return written, err
}
