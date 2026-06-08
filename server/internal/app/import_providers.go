package app

import (
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type importFileInput struct {
	InputFile        string
	OriginalFilename string
	ImportID         string
}

type importDedupOptions struct {
	AlipayFundRounding bool
}

type billImporter interface {
	ProviderID() string
	ProviderLabel() string
	ProviderTitle() string
	DisplayOrder() int
	ProviderConfig() importProviderConfig
	Detect(filename, sample, ext string) (providerDetection, bool)
	Prepare(*Server, importFileInput) (preparedImportInput, error)
	Generate(*Server, preparedImportInput, string) error
	AnalyzeSource(*Server, preparedImportInput, string) (providerSourceAnalysis, []string)
	DedupArgs(importDedupOptions) []string
	DecorateEntries(importMeta, []ImportEntry)
	ExcludedRowCount(preparedImportInput, providerSourceAnalysis, beanSummary) int
	PreviewWarnings(preparedImportInput, providerSourceAnalysis, beanSummary, beanSummary, string) ([]string, error)
	RowCounts(preparedImportInput, providerSourceAnalysis, beanSummary) (int, int)
	DocumentAccount(map[string]bool, string) string
}

type staticBillImporter struct {
	id              string
	label           string
	title           string
	uiOrder         int
	config          importProviderConfig
	detect          func(filename, sample, ext string) (providerDetection, bool)
	prepare         func(*Server, importFileInput) (preparedImportInput, error)
	generate        func(*Server, preparedImportInput, string) error
	analyze         func(*Server, preparedImportInput, string) (providerSourceAnalysis, []string)
	dedupArgs       func(importDedupOptions) []string
	decorateEntries func(importMeta, []ImportEntry)
	excludedRows    func(preparedImportInput, providerSourceAnalysis, beanSummary) int
	previewWarnings func(preparedImportInput, providerSourceAnalysis, beanSummary, beanSummary, string) ([]string, error)
	rowCounts       func(preparedImportInput, providerSourceAnalysis, beanSummary) (int, int)
	documentAccount string
}

func (i staticBillImporter) ProviderID() string {
	return i.id
}

func (i staticBillImporter) ProviderLabel() string {
	return i.label
}

func (i staticBillImporter) ProviderTitle() string {
	return i.title
}

func (i staticBillImporter) DisplayOrder() int {
	return i.uiOrder
}

func (i staticBillImporter) ProviderConfig() importProviderConfig {
	return i.config
}

func (i staticBillImporter) Detect(filename, sample, ext string) (providerDetection, bool) {
	if i.detect == nil {
		return providerDetection{}, false
	}
	return i.detect(filename, sample, ext)
}

func (i staticBillImporter) Prepare(s *Server, input importFileInput) (preparedImportInput, error) {
	if i.prepare != nil {
		return i.prepare(s, input)
	}
	return preparedImportInput{InputFile: input.InputFile}, nil
}

func (i staticBillImporter) Generate(s *Server, prepared preparedImportInput, outputFile string) error {
	if i.generate != nil {
		return i.generate(s, prepared, outputFile)
	}
	return s.runTranslate(i.ProviderID(), prepared.InputFile, outputFile)
}

func (i staticBillImporter) AnalyzeSource(s *Server, prepared preparedImportInput, generatedBean string) (providerSourceAnalysis, []string) {
	if i.analyze != nil {
		return i.analyze(s, prepared, generatedBean)
	}
	return providerSourceAnalysis{}, nil
}

func (i staticBillImporter) DedupArgs(options importDedupOptions) []string {
	if i.dedupArgs != nil {
		return i.dedupArgs(options)
	}
	return nil
}

func (i staticBillImporter) DecorateEntries(meta importMeta, entries []ImportEntry) {
	if i.decorateEntries != nil {
		i.decorateEntries(meta, entries)
	}
}

func (i staticBillImporter) ExcludedRowCount(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) int {
	if i.excludedRows != nil {
		return i.excludedRows(prepared, analysis, generated)
	}
	return 0
}

func (i staticBillImporter) PreviewWarnings(prepared preparedImportInput, analysis providerSourceAnalysis, generated, deduped beanSummary, generatedBean string) ([]string, error) {
	if i.previewWarnings != nil {
		return i.previewWarnings(prepared, analysis, generated, deduped, generatedBean)
	}
	return nil, nil
}

func (i staticBillImporter) RowCounts(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) (int, int) {
	if i.rowCounts != nil {
		return i.rowCounts(prepared, analysis, generated)
	}
	return generated.CandidateCount, generated.CandidateCount
}

func (i staticBillImporter) DocumentAccount(accounts map[string]bool, fallback string) string {
	preferred := i.documentAccount
	if accounts[preferred] {
		return preferred
	}
	if fallback != "" && accounts[fallback] {
		return fallback
	}
	return preferred
}

var billImporters = []billImporter{
	staticBillImporter{
		id:              "wechat",
		label:           "微信支付",
		title:           "WeChat Pay",
		uiOrder:         20,
		config:          importProviderConfig{Config: "imports/wechat-config.yaml", Output: "wechat-output.bean", Extensions: []string{".xlsx", ".xls"}, Label: "微信支付", Detail: "微信支付导出的明细表"},
		documentAccount: "Assets:CN:Wechat:Balance",
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			if ext == ".xlsx" || ext == ".xls" {
				return providerDetection{Provider: "wechat", Reason: "Excel 文件通常为微信支付账单", Confidence: "high"}, true
			}
			return providerDetection{}, false
		},
	},
	staticBillImporter{
		id:              "cmb-checking",
		label:           "招商银行储蓄卡",
		title:           "CMB Checking",
		uiOrder:         40,
		config:          importProviderConfig{Config: "imports/cmb-checking-config.yaml", Output: "cmb-checking-output.bean", Extensions: []string{".pdf", ".csv"}, Label: "招商银行储蓄卡", Detail: "储蓄卡交易流水 CSV，PDF 可尝试"},
		documentAccount: "Assets:CN:CMB:Checking",
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			if ext == ".pdf" && strings.HasPrefix(sample, "%PDF-") && strings.Contains(filename, "交易流水") {
				return providerDetection{Provider: "cmb-checking", Reason: "PDF 文件名包含招商银行交易流水", Confidence: "medium"}, true
			}
			if ext == ".csv" && regexp.MustCompile(`记账日期,货币,交易金额,联机余额,交易摘要,对手信息`).MatchString(sample) {
				return providerDetection{Provider: "cmb-checking", Reason: "CSV 内容包含招商银行储蓄卡流水字段", Confidence: "high"}, true
			}
			return providerDetection{}, false
		},
		prepare: func(s *Server, input importFileInput) (preparedImportInput, error) {
			return s.prepareCmbCheckingInput(input.InputFile, input.OriginalFilename, input.ImportID)
		},
		generate: func(s *Server, prepared preparedImportInput, outputFile string) error {
			return s.generateCmbCheckingBean(prepared.InputFile, outputFile)
		},
		dedupArgs: func(options importDedupOptions) []string {
			return []string{"--bank-card"}
		},
		decorateEntries: decorateStatementHashEntries,
		previewWarnings: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated, deduped beanSummary, generatedBean string) ([]string, error) {
			return []string{fmt.Sprintf("招商银行储蓄卡行数核对通过：CSV 明细 %d 条，生成 %d 条，去重后待写入 %d 条。", generated.CandidateCount, generated.CandidateCount, deduped.CandidateCount)}, nil
		},
	},
	staticBillImporter{
		id:              "cmb",
		label:           "招商银行信用卡",
		title:           "CMB Credit Card",
		uiOrder:         30,
		config:          importProviderConfig{Config: "imports/cmb-credit-card-config.yaml", Output: "cmb-credit-output.bean", Extensions: []string{".pdf", ".csv"}, Label: "招商银行信用卡", Detail: "信用卡 PDF 或已转换 CSV"},
		documentAccount: "Liabilities:CN:CMB:CreditCard",
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			if ext == ".pdf" && strings.HasPrefix(sample, "%PDF-") {
				return providerDetection{Provider: "cmb", Reason: "PDF 文件将按招商银行信用卡账单解析", Confidence: "medium"}, true
			}
			if ext == ".csv" && regexp.MustCompile(`招商银行信用卡对账单|交易日,记账日,交易摘要,人民币金额,卡号末四位,交易地金额`).MatchString(sample) {
				return providerDetection{Provider: "cmb", Reason: "CSV 内容包含招商银行信用卡账单字段", Confidence: "high"}, true
			}
			return providerDetection{}, false
		},
		prepare: func(s *Server, input importFileInput) (preparedImportInput, error) {
			return s.prepareCmbInput(input.InputFile, input.OriginalFilename, input.ImportID)
		},
		dedupArgs: func(options importDedupOptions) []string {
			return []string{"--credit-card"}
		},
		decorateEntries: decorateStatementHashEntries,
		excludedRows: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) int {
			excluded := prepared.FilteredRowCount - generated.CandidateCount
			if excluded < 0 {
				return 0
			}
			return excluded
		},
		previewWarnings: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated, deduped beanSummary, generatedBean string) ([]string, error) {
			if generated.CandidateCount != prepared.FilteredRowCount {
				return nil, fmt.Errorf("招商银行信用卡行数核对失败：PDF/CSV 明细 %d 条，Web 前置过滤后 %d 条，但 DEG 生成 %d 条。已停止导入，请检查 PDF 解析或 DEG 配置", prepared.RawRowCount, prepared.FilteredRowCount, generated.CandidateCount)
			}
			return []string{fmt.Sprintf("招商银行信用卡行数核对通过：PDF/CSV 明细 %d 条，Web 前置过滤后 %d 条，DEG 生成 %d 条，去重后待写入 %d 条。", prepared.RawRowCount, prepared.FilteredRowCount, generated.CandidateCount, deduped.CandidateCount)}, nil
		},
		rowCounts: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) (int, int) {
			return prepared.RawRowCount, prepared.FilteredRowCount
		},
	},
	staticBillImporter{
		id:              "alipay",
		label:           "支付宝",
		title:           "Alipay",
		uiOrder:         10,
		config:          importProviderConfig{Config: "imports/alipay-config.yaml", Output: "alipay-output.bean", Extensions: []string{".csv"}, Label: "支付宝", Detail: "CSV 账单，支持基金补差选项"},
		documentAccount: "Assets:CN:Alipay:Balance",
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			if ext != ".csv" {
				return providerDetection{}, false
			}
			if regexp.MustCompile(`支付宝|交易号|商家订单号|交易创建时间|收支`).MatchString(sample) {
				return providerDetection{Provider: "alipay", Reason: "CSV 内容包含支付宝账单字段", Confidence: "high"}, true
			}
			return providerDetection{Provider: "alipay", Reason: "CSV 文件默认按支付宝账单处理", Confidence: "medium"}, true
		},
		prepare: func(s *Server, input importFileInput) (preparedImportInput, error) {
			return s.prepareAlipayCSVForDEG(input.InputFile, input.ImportID)
		},
		analyze: func(s *Server, prepared preparedImportInput, generatedBean string) (providerSourceAnalysis, []string) {
			analysis, err := s.analyzeAlipayImportSource(prepared.InputFile, generatedBean)
			if err != nil {
				return providerSourceAnalysis{}, []string{"支付宝原始明细核对失败：" + err.Error()}
			}
			return analysis, analysis.Warnings
		},
		dedupArgs: func(options importDedupOptions) []string {
			if options.AlipayFundRounding {
				return []string{"--alipay-fund-rounding"}
			}
			return nil
		},
		excludedRows: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) int {
			return analysis.ExcludedRowCount
		},
		rowCounts: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) (int, int) {
			if analysis.RawRowCount > 0 {
				return analysis.RawRowCount, analysis.FilteredRowCount
			}
			return generated.CandidateCount, generated.CandidateCount
		},
	},
}

var importProviderConfigs = buildImportProviderConfigs()

func buildImportProviderConfigs() map[string]importProviderConfig {
	configs := make(map[string]importProviderConfig, len(billImporters))
	for _, importer := range billImporters {
		configs[importer.ProviderID()] = importer.ProviderConfig()
	}
	return configs
}

type importProviderOption struct {
	ID         string   `json:"id"`
	Label      string   `json:"label"`
	Detail     string   `json:"detail"`
	Extensions []string `json:"extensions"`
	Accept     string   `json:"accept"`
}

func importProviderOptions() []importProviderOption {
	ordered := append([]billImporter{}, billImporters...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].DisplayOrder() < ordered[j].DisplayOrder()
	})
	options := make([]importProviderOption, 0, len(ordered))
	for _, importer := range ordered {
		cfg := importer.ProviderConfig()
		options = append(options, importProviderOption{
			ID:         importer.ProviderID(),
			Label:      cfg.Label,
			Detail:     cfg.Detail,
			Extensions: append([]string{}, cfg.Extensions...),
			Accept:     strings.Join(cfg.Extensions, " / "),
		})
	}
	return options
}

func importProvider(provider string) (billImporter, bool) {
	for _, importer := range billImporters {
		if importer.ProviderID() == provider {
			return importer, true
		}
	}
	return nil, false
}

func importProviderIDs() []string {
	ids := make([]string, 0, len(billImporters))
	for _, importer := range billImporters {
		ids = append(ids, importer.ProviderID())
	}
	return ids
}

func detectImportProvider(filename string, content []byte, override string) (providerDetection, error) {
	ext := strings.ToLower(filepath.Ext(filename))
	if override != "" {
		if importer, ok := importProvider(override); ok {
			return providerDetection{Provider: importer.ProviderID(), Reason: "手动指定", Confidence: "high"}, nil
		}
		return providerDetection{}, fmt.Errorf("provider must be %s", strings.Join(importProviderIDs(), ", "))
	}

	sample := string(content)
	if len(content) > 32768 {
		sample = string(content[:32768])
	}
	for _, importer := range billImporters {
		if detection, ok := importer.Detect(filename, sample, ext); ok {
			return detection, nil
		}
	}
	return providerDetection{}, errorsUnsupportedBillType()
}

func errorsUnsupportedBillType() error {
	return fmt.Errorf("无法自动识别账单类型，请上传支付宝 CSV、微信 XLSX/XLS、招商银行信用卡 PDF/CSV 或招商银行储蓄卡流水 PDF/CSV。需要时可使用手动覆盖。")
}

func decorateStatementHashEntries(meta importMeta, entries []ImportEntry) {
	for i := range entries {
		if entries[i].Metadata == nil {
			entries[i].Metadata = map[string]string{}
		}
		entries[i].Metadata["statementHash"] = meta.StatementHash
	}
}
