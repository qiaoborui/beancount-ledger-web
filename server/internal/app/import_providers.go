package app

import (
	"context"
	"fmt"
	"regexp"
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
	ImportEngine() importEngine
	Detect(filename, sample, ext string) (providerDetection, bool)
	Prepare(*Server, importFileInput) (preparedImportInput, error)
	Generate(context.Context, *Server, preparedImportInput, string) error
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
	engine          importEngine
	detect          func(filename, sample, ext string) (providerDetection, bool)
	prepare         func(*Server, importFileInput) (preparedImportInput, error)
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

func (i staticBillImporter) ImportEngine() importEngine {
	if i.engine != nil {
		return i.engine
	}
	return degImportEngine()
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

func (i staticBillImporter) Generate(ctx context.Context, s *Server, prepared preparedImportInput, outputFile string) error {
	engine := i.ImportEngine()
	return engine.Generate(ctx, s, importEngineInput{ProviderID: i.ProviderID(), Config: i.ProviderConfig(), InputFile: prepared.InputFile, OutputFile: outputFile})
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
		id:              "alipay-small-purse",
		label:           "支付宝小荷包",
		title:           "Alipay Small Purse",
		uiOrder:         15,
		config:          importProviderConfig{Config: "imports/alipay-config.yaml", Output: "alipay-small-purse-output.bean", Extensions: []string{".xlsx"}, Label: "支付宝小荷包", Detail: "小荷包余额收支明细 XLSX，共同资金池消费"},
		engine:          nativeImportEngine("native-alipay-small-purse", (*Server).generateAlipaySmallPurseBean),
		documentAccount: alipaySmallPurseCashAccount,
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			if ext != ".xlsx" {
				return providerDetection{}, false
			}
			if strings.Contains(filename, "支付宝小荷包") || strings.Contains(sample, "支付宝小荷包") {
				return providerDetection{Provider: "alipay-small-purse", Reason: "文件名或内容包含支付宝小荷包账单字段", Confidence: "high"}, true
			}
			return providerDetection{}, false
		},
		prepare: func(s *Server, input importFileInput) (preparedImportInput, error) {
			return s.prepareAlipaySmallPurseInput(input.InputFile, input.ImportID)
		},
		previewWarnings: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated, deduped beanSummary, generatedBean string) ([]string, error) {
			if generated.CandidateCount != prepared.FilteredRowCount {
				return nil, fmt.Errorf("支付宝小荷包行数核对失败：XLSX 明细 %d 条，可导入 %d 条，但生成 %d 条。已停止导入，请检查小荷包解析器", prepared.RawRowCount, prepared.FilteredRowCount, generated.CandidateCount)
			}
			return []string{fmt.Sprintf("支付宝小荷包行数核对通过：XLSX 明细 %d 条，生成 %d 条，去重后待写入 %d 条。共同消费按小荷包配置拆分，对象份额计入配置的对象权益账户。", prepared.RawRowCount, generated.CandidateCount, deduped.CandidateCount)}, nil
		},
		excludedRows: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) int {
			return prepared.RawRowCount - prepared.FilteredRowCount
		},
		rowCounts: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) (int, int) {
			return prepared.RawRowCount, prepared.FilteredRowCount
		},
	},
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
		config:          importProviderConfig{Config: "imports/cmb-checking-config.yaml", Output: "cmb-checking-output.bean", Extensions: []string{".pdf", ".csv"}, Label: "招商银行储蓄卡", Detail: "储蓄卡交易流水 CSV，PDF 可尝试", DEGProviderID: "cmb"},
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
		documentAccount: "Liabilities:CN:CMB:CreditCard:0016",
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
		id:              "ccb-credit",
		label:           "建设银行信用卡",
		title:           "CCB Credit Card",
		uiOrder:         35,
		config:          importProviderConfig{Config: "imports/ccb-credit-card-config.yaml", Output: "ccb-credit-output.bean", Extensions: []string{".eml", ".html", ".htm", ".csv"}, Label: "建设银行信用卡", Detail: "信用卡邮件 EML、HTML 或标准 CSV"},
		documentAccount: "Liabilities:CN:CCB:CreditCard:7720",
		detect: func(filename, sample, ext string) (providerDetection, bool) {
			ccbEmailSignature := regexp.MustCompile(`(?i)service@vip\.ccb\.com|vip\.ccb\.com|creditcard\.ccb\.com`)
			ccbStatementSignature := regexp.MustCompile(`中国建设银行信用卡电子账单|龙卡信用卡对账单|Credit Card Statement`)
			if (ext == ".eml" || ext == ".html" || ext == ".htm") && (ccbStatementSignature.MatchString(filename) || ccbStatementSignature.MatchString(sample) || ccbEmailSignature.MatchString(sample)) {
				return providerDetection{Provider: "ccb-credit", Reason: "邮件内容包含建设银行信用卡账单字段", Confidence: "high"}, true
			}
			if ext == ".csv" && regexp.MustCompile(`交易日,银行记账日,卡号后四位,交易描述,交易币种,交易金额,结算币种,结算金额|transactionDate,postingDate,cardLast4,description,transactionCurrency,transactionAmount,settlementCurrency,settlementAmount`).MatchString(sample) {
				return providerDetection{Provider: "ccb-credit", Reason: "CSV 内容包含建设银行信用卡标准字段", Confidence: "high"}, true
			}
			return providerDetection{}, false
		},
		prepare: func(s *Server, input importFileInput) (preparedImportInput, error) {
			return s.prepareCcbCreditInput(input.InputFile, input.OriginalFilename, input.ImportID)
		},
		engine: nativeImportEngine("native-ccb-credit", (*Server).generateCcbCreditBean),
		dedupArgs: func(options importDedupOptions) []string {
			return []string{"--credit-card"}
		},
		decorateEntries: decorateStatementHashEntries,
		excludedRows: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated beanSummary) int {
			excluded := prepared.RawRowCount - prepared.FilteredRowCount
			if excluded < 0 {
				return 0
			}
			return excluded
		},
		previewWarnings: func(prepared preparedImportInput, analysis providerSourceAnalysis, generated, deduped beanSummary, generatedBean string) ([]string, error) {
			if generated.CandidateCount != prepared.FilteredRowCount {
				return nil, fmt.Errorf("建设银行信用卡行数核对失败：邮件/CSV 明细 %d 条，Web 前置过滤后 %d 条，但生成 %d 条。已停止导入，请检查邮件解析或配置", prepared.RawRowCount, prepared.FilteredRowCount, generated.CandidateCount)
			}
			return []string{fmt.Sprintf("建设银行信用卡行数核对通过：邮件/CSV 明细 %d 条，Web 前置过滤后 %d 条，生成 %d 条，去重后待写入 %d 条。", prepared.RawRowCount, prepared.FilteredRowCount, generated.CandidateCount, deduped.CandidateCount)}, nil
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

var defaultBillImporterRegistry = defaultBillImporters()

var importProviderConfigs = buildImportProviderConfigs()

func buildImportProviderConfigs() map[string]importProviderConfig {
	configs := make(map[string]importProviderConfig, len(defaultBillImporterRegistry.ordered))
	for _, importer := range defaultBillImporterRegistry.ordered {
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
	Engine     string   `json:"engine"`
}

func importProviderOptions() []importProviderOption {
	return defaultBillImporterRegistry.Options()
}

func importProvider(provider string) (billImporter, bool) {
	return defaultBillImporterRegistry.Lookup(provider)
}

func importProviderIDs() []string {
	return defaultBillImporterRegistry.IDs()
}

func detectImportProvider(filename string, content []byte, override string) (providerDetection, error) {
	return defaultBillImporterRegistry.Detect(filename, content, override)
}

func errorsUnsupportedBillType() error {
	return fmt.Errorf("无法自动识别账单类型，请上传支付宝 CSV、支付宝小荷包 XLSX、微信 XLSX/XLS、招商银行信用卡 PDF/CSV、建设银行信用卡 EML/HTML/CSV 或招商银行储蓄卡流水 PDF/CSV。需要时可使用手动覆盖。")
}

func decorateStatementHashEntries(meta importMeta, entries []ImportEntry) {
	for i := range entries {
		if entries[i].Metadata == nil {
			entries[i].Metadata = map[string]string{}
		}
		entries[i].Metadata["statementHash"] = meta.StatementHash
	}
}
