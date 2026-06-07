package app

import (
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	pdf "github.com/ledongthuc/pdf"
	"gopkg.in/yaml.v3"
)

var cmbCheckingCSVHeaders = []string{"记账日期", "货币", "交易金额", "联机余额", "交易摘要", "对手信息"}

type cmbCheckingConfig struct {
	DefaultDebitAccount  string                   `yaml:"defaultDebitAccount"`
	DefaultCreditAccount string                   `yaml:"defaultCreditAccount"`
	CashAccount          string                   `yaml:"cashAccount"`
	DefaultCurrency      string                   `yaml:"defaultCurrency"`
	Title                string                   `yaml:"title"`
	CMBChecking          cmbCheckingConfigSection `yaml:"cmbChecking"`
}

type cmbCheckingConfigSection struct {
	Rules []cmbCheckingRule `yaml:"rules"`
}

type cmbCheckingRule struct {
	Item          string `yaml:"item"`
	TargetAccount string `yaml:"targetAccount"`
}

type cmbCheckingRow struct {
	Date          string
	Currency      string
	Amount        string
	OnlineBalance string
	Summary       string
	Counterparty  string
	RowNumber     int
}

func (s *Server) prepareCmbCheckingInput(inputFile, originalFilename, importID string) (preparedImportInput, error) {
	ext := strings.ToLower(filepath.Ext(originalFilename))
	if ext != ".pdf" {
		return preparedImportInput{InputFile: inputFile}, nil
	}
	result, err := parseCmbCheckingPDFToCSV(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	outputFile := previewPath(s.cfg, importID, "cmb-checking-normalized.csv")
	if err := os.WriteFile(outputFile, []byte(result.CSV), 0o600); err != nil {
		return preparedImportInput{}, err
	}
	return preparedImportInput{InputFile: outputFile, Warnings: result.Warnings, RawRowCount: result.RowCount, FilteredRowCount: result.RowCount}, nil
}

func (s *Server) generateCmbCheckingBean(inputFile, outputFile string) error {
	config, err := s.loadCmbCheckingConfig()
	if err != nil {
		return err
	}
	rows, err := readCmbCheckingCSVRows(inputFile)
	if err != nil {
		return err
	}
	blocks := make([]string, 0, len(rows))
	for _, row := range rows {
		amount := cents(row.Amount)
		if amount == 0 {
			continue
		}
		blocks = append(blocks, renderCmbCheckingEntry(row, amount, config))
	}
	if len(blocks) == 0 {
		return errors.New("招商银行储蓄卡流水没有可生成的交易")
	}
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return err
	}
	return os.WriteFile(outputFile, []byte(strings.Join(blocks, "\n\n")+"\n"), 0o600)
}

func (s *Server) loadCmbCheckingConfig() (cmbCheckingConfig, error) {
	config := cmbCheckingConfig{
		DefaultDebitAccount:  "Expenses:Unknown",
		DefaultCreditAccount: "Income:Other",
		CashAccount:          "Assets:CN:CMB:Checking",
		DefaultCurrency:      "CNY",
		Title:                "招商银行储蓄卡流水",
	}
	raw, err := os.ReadFile(filepath.Join(s.cfg.LedgerRoot, importProviderConfigs["cmb-checking"].Config))
	if err != nil {
		return config, err
	}
	if err := yaml.Unmarshal(raw, &config); err != nil {
		return config, err
	}
	if config.DefaultDebitAccount == "" {
		config.DefaultDebitAccount = "Expenses:Unknown"
	}
	if config.DefaultCreditAccount == "" {
		config.DefaultCreditAccount = "Income:Other"
	}
	if config.CashAccount == "" {
		config.CashAccount = "Assets:CN:CMB:Checking"
	}
	if config.DefaultCurrency == "" {
		config.DefaultCurrency = "CNY"
	}
	return config, nil
}

func readCmbCheckingCSVRows(inputFile string) ([]cmbCheckingRow, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return nil, err
	}
	text, err := decodeAlipayCSV(raw)
	if err != nil {
		return nil, err
	}
	reader := csv.NewReader(strings.NewReader(normalizeCmbCSVText(text)))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true
	header, err := reader.Read()
	if err != nil {
		return nil, err
	}
	columns := map[string]int{}
	for index, name := range header {
		columns[strings.TrimSpace(name)] = index
	}
	for _, name := range cmbCheckingCSVHeaders {
		if _, ok := columns[name]; !ok {
			return nil, fmt.Errorf("招商银行储蓄卡 CSV 缺少字段: %s", name)
		}
	}
	rows := []cmbCheckingRow{}
	rowNumber := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if csvRecordEmpty(record) {
			continue
		}
		rowNumber++
		row := cmbCheckingRow{
			Date:          csvField(record, columns["记账日期"]),
			Currency:      valueOr(csvField(record, columns["货币"]), "CNY"),
			Amount:        csvField(record, columns["交易金额"]),
			OnlineBalance: csvField(record, columns["联机余额"]),
			Summary:       csvField(record, columns["交易摘要"]),
			Counterparty:  csvField(record, columns["对手信息"]),
			RowNumber:     rowNumber,
		}
		if row.Date == "" && row.Amount == "" {
			continue
		}
		if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`).MatchString(row.Date) {
			return nil, fmt.Errorf("第 %d 行记账日期无效: %s", rowNumber, row.Date)
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func renderCmbCheckingEntry(row cmbCheckingRow, amount int, config cmbCheckingConfig) string {
	target := cmbCheckingTargetAccount(row, amount, config)
	currency := valueOr(row.Currency, config.DefaultCurrency)
	payee := cmbCheckingPayee(row.Counterparty, row.Summary)
	orderID := cmbCheckingOrderID(row)
	txType := "credit"
	if amount < 0 {
		txType = "debit"
	}
	lines := []string{fmt.Sprintf(`%s * "%s" "%s"`, row.Date, escapeBean(payee), escapeBean(row.Summary))}
	lines = append(lines,
		fmt.Sprintf(`  method: "%s"`, escapeBean(row.Summary)),
		fmt.Sprintf(`  onlineBalance: "%s"`, escapeBean(row.OnlineBalance)),
		fmt.Sprintf(`  orderId: "%s"`, orderID),
		fmt.Sprintf(`  row: "%d"`, row.RowNumber),
		`  source: "cmb-checking"`,
		fmt.Sprintf(`  txType: "%s"`, txType),
	)
	if strings.TrimSpace(row.Counterparty) != "" {
		lines = append(lines, fmt.Sprintf(`  counterparty: "%s"`, escapeBean(row.Counterparty)))
	}
	if amount < 0 {
		lines = append(lines,
			fmt.Sprintf("  %-34s %12s %s", target, fromCents(-amount), currency),
			fmt.Sprintf("  %-34s %12s %s", config.CashAccount, fromCents(amount), currency),
		)
		return strings.Join(lines, "\n")
	}
	lines = append(lines,
		fmt.Sprintf("  %-34s %12s %s", config.CashAccount, fromCents(amount), currency),
		fmt.Sprintf("  %-34s %12s %s", target, fromCents(-amount), currency),
	)
	return strings.Join(lines, "\n")
}

func cmbCheckingTargetAccount(row cmbCheckingRow, amount int, config cmbCheckingConfig) string {
	text := row.Summary + " " + row.Counterparty
	for _, rule := range config.CMBChecking.Rules {
		for _, item := range strings.FieldsFunc(rule.Item, func(r rune) bool { return r == ',' || r == '，' }) {
			item = strings.TrimSpace(item)
			if item != "" && strings.Contains(text, item) && rule.TargetAccount != "" {
				return rule.TargetAccount
			}
		}
	}
	if amount > 0 {
		return config.DefaultCreditAccount
	}
	return config.DefaultDebitAccount
}

func cmbCheckingPayee(counterparty, summary string) string {
	payee := strings.TrimSpace(counterparty)
	payee = regexp.MustCompile(`\s*\d{6,}$`).ReplaceAllString(payee, "")
	payee = strings.TrimSpace(payee)
	if payee != "" {
		return payee
	}
	return valueOr(strings.TrimSpace(summary), "招商银行储蓄卡")
}

func cmbCheckingOrderID(row cmbCheckingRow) string {
	canonical := strings.Join([]string{row.Date, row.Currency, row.Amount, row.OnlineBalance, row.Summary, row.Counterparty}, "\x00")
	sum := sha256.Sum256([]byte(canonical))
	return "cmb-checking-" + hex.EncodeToString(sum[:8])
}

type cmbCheckingPDFResult struct {
	CSV      string
	RowCount int
	Warnings []string
}

func parseCmbCheckingPDFToCSV(inputFile string) (cmbCheckingPDFResult, error) {
	file, reader, err := pdf.Open(inputFile)
	if err != nil {
		return cmbCheckingPDFResult{}, err
	}
	defer file.Close()
	if reader.NumPage() == 0 {
		return cmbCheckingPDFResult{}, errors.New("招商银行储蓄卡 PDF 没有页面")
	}
	headerInfo, err := extractCmbCheckingPDFHeaderInfo(reader.Page(1))
	if err == nil {
		rows := [][]string{}
		for pageNo := 1; pageNo <= reader.NumPage(); pageNo++ {
			for _, row := range extractCmbCheckingPDFRows(reader.Page(pageNo), headerInfo) {
				if looksLikeCmbCheckingPDFDataRow(row) {
					rows = append(rows, row)
				}
			}
		}
		if len(rows) > 0 {
			return cmbCheckingPDFRowsResult(rows), nil
		}
	}
	rows := [][]string{}
	lineRe := regexp.MustCompile(`^\s*(\d{4}-\d{2}-\d{2})\s+(CNY)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s+(.+?)\s{2,}(.+?)\s*$`)
	for pageNo := 1; pageNo <= reader.NumPage(); pageNo++ {
		lines := groupPDFTextLines(pageTextItems(reader.Page(pageNo)))
		for _, line := range lines {
			text := strings.TrimSpace(compactPDFLineText(line))
			m := lineRe.FindStringSubmatch(text)
			if m == nil {
				continue
			}
			rows = append(rows, []string{m[1], m[2], m[3], m[4], strings.TrimSpace(m[5]), strings.TrimSpace(m[6])})
		}
	}
	if len(rows) == 0 {
		return cmbCheckingPDFResult{}, errors.New("未从招商银行储蓄卡 PDF 中解析到交易明细，请上传已转换 CSV")
	}
	return cmbCheckingPDFRowsResult(rows), nil
}

func cmbCheckingPDFRowsResult(rows [][]string) cmbCheckingPDFResult {
	csvRows := []string{csvLine(cmbCheckingCSVHeaders)}
	for _, row := range rows {
		csvRows = append(csvRows, csvLine(row))
	}
	return cmbCheckingPDFResult{
		CSV:      strings.Join(csvRows, "\n"),
		RowCount: len(rows),
		Warnings: []string{"招商银行储蓄卡 PDF 已转换为 CSV；请在预览中核对商户、金额和分类。"},
	}
}

func extractCmbCheckingPDFHeaderInfo(page pdf.Page) (cmbPDFHeaderInfo, error) {
	lines := groupPDFTextLines(pageTextItems(page))
	var headerLine pdfTextLine
	for _, line := range lines {
		text := compactPDFLineText(line)
		matchesAllHeaders := true
		for _, header := range cmbCheckingCSVHeaders {
			if !strings.Contains(text, header) {
				matchesAllHeaders = false
				break
			}
		}
		if matchesAllHeaders {
			headerLine = line
			break
		}
	}
	if len(headerLine.Items) == 0 {
		return cmbPDFHeaderInfo{}, fmt.Errorf("未找到招行储蓄卡 PDF 表头: %s", strings.Join(cmbCheckingCSVHeaders, ", "))
	}
	ranges := []cmbPDFColumnRange{}
	for index, header := range cmbCheckingCSVHeaders {
		x, ok := findHeaderX(headerLine, header)
		if !ok {
			return cmbPDFHeaderInfo{}, fmt.Errorf("未找到招行储蓄卡 PDF 表头: %s", header)
		}
		ranges = append(ranges, cmbPDFColumnRange{Title: header, Index: index, Left: x, Right: 9999})
	}
	for i := range ranges {
		if i+1 < len(ranges) {
			ranges[i].Right = ranges[i+1].Left - 0.01
		}
	}
	return cmbPDFHeaderInfo{Title: "招商银行储蓄卡交易流水", Ranges: ranges}, nil
}

func extractCmbCheckingPDFRows(page pdf.Page, headerInfo cmbPDFHeaderInfo) [][]string {
	lines := groupPDFTextLines(pageTextItems(page))
	rows := [][]string{}
	for _, line := range lines {
		cells := make([]string, len(cmbCheckingCSVHeaders))
		hasCell := false
		for _, item := range line.Items {
			col := cmbPDFColumnForX(item.X, headerInfo.Ranges)
			if col < 0 {
				continue
			}
			cells[col] += strings.TrimSpace(item.Text)
			hasCell = true
		}
		if hasCell {
			rows = append(rows, cells)
		}
	}
	return rows
}

func looksLikeCmbCheckingPDFDataRow(row []string) bool {
	if len(row) < len(cmbCheckingCSVHeaders) {
		return false
	}
	dateRe := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	moneyRe := regexp.MustCompile(`^-?\d[\d,]*\.\d{2}$`)
	return dateRe.MatchString(strings.TrimSpace(row[0])) &&
		strings.TrimSpace(row[1]) != "" &&
		moneyRe.MatchString(strings.TrimSpace(row[2])) &&
		moneyRe.MatchString(strings.TrimSpace(row[3])) &&
		strings.TrimSpace(row[4]) != ""
}
