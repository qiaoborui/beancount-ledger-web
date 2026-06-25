package app

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const alipaySmallPurseCashAccount = "Assets:CN:Alipay:SmallPurse"

type alipaySmallPurseConfig struct {
	DefaultMinusAccount string                        `yaml:"defaultMinusAccount"`
	DefaultPlusAccount  string                        `yaml:"defaultPlusAccount"`
	DefaultCashAccount  string                        `yaml:"defaultCashAccount"`
	DefaultCurrency     string                        `yaml:"defaultCurrency"`
	Alipay              alipaySmallPurseConfigSection `yaml:"alipay"`
	AlipaySmallPurse    alipaySmallPurseConfigSection `yaml:"alipaySmallPurse"`
}

type alipaySmallPurseConfigSection struct {
	CashAccount             string                 `yaml:"cashAccount"`
	PartnerLiabilityAccount string                 `yaml:"partnerLiabilityAccount"`
	SharedExpenseSplit      *bool                  `yaml:"sharedExpenseSplit"`
	Rules                   []alipaySmallPurseRule `yaml:"rules"`
}

type alipaySmallPurseRule struct {
	Peer          string   `yaml:"peer"`
	Item          string   `yaml:"item"`
	Category      string   `yaml:"category"`
	Type          string   `yaml:"type"`
	Method        string   `yaml:"method"`
	Separator     string   `yaml:"sep"`
	TargetAccount string   `yaml:"targetAccount"`
	MethodAccount string   `yaml:"methodAccount"`
	FullMatch     bool     `yaml:"fullMatch"`
	Tag           string   `yaml:"tag"`
	Ignore        bool     `yaml:"ignore"`
	MinPrice      *float64 `yaml:"minPrice"`
	MaxPrice      *float64 `yaml:"maxPrice"`
}

type alipaySmallPurseStatement struct {
	WalletName  string
	AccountID   string
	CreatedAt   string
	PeriodStart string
	PeriodEnd   string
	Rows        []alipaySmallPurseRow
}

type alipaySmallPurseRow struct {
	OrderID      string
	DateTime     string
	Description  string
	Remark       string
	OperatorNick string
	OperatorName string
	Income       string
	Expense      string
	RowNumber    int
}

func (s *Server) prepareAlipaySmallPurseInput(inputFile, importID string) (preparedImportInput, error) {
	statement, err := parseAlipaySmallPurseXLSX(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	start, end := alipaySmallPurseDateRange(statement)
	filtered := 0
	for _, row := range statement.Rows {
		if cents(row.Income) != 0 || cents(row.Expense) != 0 {
			filtered++
		}
	}
	warnings := []string{fmt.Sprintf("已识别支付宝小荷包“%s”明细 %d 条。", valueOr(statement.WalletName, "未命名小荷包"), len(statement.Rows))}
	if statement.PeriodStart != "" && statement.PeriodEnd != "" {
		warnings = append(warnings, fmt.Sprintf("小荷包账单期间：%s 至 %s。", statement.PeriodStart, statement.PeriodEnd))
	}
	return preparedImportInput{
		InputFile:        inputFile,
		Warnings:         warnings,
		RawRowCount:      len(statement.Rows),
		FilteredRowCount: filtered,
		DateStart:        start,
		DateEnd:          end,
	}, nil
}

func (s *Server) generateAlipaySmallPurseBean(inputFile, outputFile string) error {
	config, err := s.loadAlipaySmallPurseConfig()
	if err != nil {
		return err
	}
	statement, err := parseAlipaySmallPurseXLSX(inputFile)
	if err != nil {
		return err
	}
	blocks := make([]string, 0, len(statement.Rows))
	for _, row := range statement.Rows {
		block, ignore, err := renderAlipaySmallPurseEntry(statement, row, config)
		if err != nil {
			return err
		}
		if ignore || block == "" {
			continue
		}
		blocks = append(blocks, block)
	}
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return err
	}
	if len(blocks) == 0 {
		return os.WriteFile(outputFile, []byte(""), 0o600)
	}
	return os.WriteFile(outputFile, []byte(strings.Join(blocks, "\n\n")+"\n"), 0o600)
}

func (s *Server) loadAlipaySmallPurseConfig() (alipaySmallPurseConfig, error) {
	config := alipaySmallPurseConfig{
		DefaultMinusAccount: "Income:Other",
		DefaultPlusAccount:  "Expenses:Unknown",
		DefaultCashAccount:  alipaySmallPurseCashAccount,
		DefaultCurrency:     "CNY",
	}
	raw, err := os.ReadFile(filepath.Join(s.cfg.LedgerRoot, "imports/alipay-config.yaml"))
	if err != nil {
		return config, err
	}
	if err := yaml.Unmarshal(raw, &config); err != nil {
		return config, err
	}
	if config.DefaultMinusAccount == "" {
		config.DefaultMinusAccount = "Income:Other"
	}
	if config.DefaultPlusAccount == "" {
		config.DefaultPlusAccount = "Expenses:Unknown"
	}
	if config.DefaultCashAccount == "" {
		config.DefaultCashAccount = alipaySmallPurseCashAccount
	}
	if config.DefaultCurrency == "" {
		config.DefaultCurrency = "CNY"
	}
	return config, nil
}

func renderAlipaySmallPurseEntry(statement alipaySmallPurseStatement, row alipaySmallPurseRow, config alipaySmallPurseConfig) (string, bool, error) {
	income := cents(row.Income)
	expense := cents(row.Expense)
	if income == 0 && expense == 0 {
		return "", true, nil
	}
	if income != 0 && expense != 0 {
		return "", false, fmt.Errorf("支付宝小荷包第 %d 行同时包含收入和支出", row.RowNumber)
	}
	date := alipaySmallPurseDate(row.DateTime)
	if date == "" {
		return "", false, fmt.Errorf("支付宝小荷包第 %d 行交易时间无效: %s", row.RowNumber, row.DateTime)
	}
	currency := config.DefaultCurrency
	payee := alipaySmallPursePayee(row.Description, statement.WalletName)
	narration := alipaySmallPurseNarration(row.Description, payee)
	txType := "支出"
	target := config.DefaultPlusAccount
	amount := expense
	if income > 0 {
		txType = "收入"
		target = alipaySmallPursePartnerLiabilityAccount(config)
		amount = income
	}
	ignore, target, tags := alipaySmallPurseApplyRules(row, payee, amount, txType, target, config)
	if ignore {
		return "", true, nil
	}

	lines := []string{fmt.Sprintf(`%s * "%s" "%s"`, date, escapeBean(payee), escapeBean(narration))}
	for _, tag := range tags {
		if tag != "" {
			lines[0] += " #" + sanitizeBeanTag(tag)
		}
	}
	lines = append(lines,
		fmt.Sprintf(`  orderId: "%s"`, escapeBean(row.OrderID)),
		fmt.Sprintf(`  payTime: "%s"`, escapeBean(alipaySmallPursePayTime(row.DateTime))),
		`  source: "支付宝小荷包"`,
		`  method: "支付宝小荷包"`,
		fmt.Sprintf(`  type: "%s"`, txType),
		fmt.Sprintf(`  wallet: "%s"`, escapeBean(statement.WalletName)),
		fmt.Sprintf(`  row: "%d"`, row.RowNumber),
	)
	if statement.AccountID != "" {
		lines = append(lines, fmt.Sprintf(`  walletId: "%s"`, escapeBean(statement.AccountID)))
	}
	if row.OperatorName != "" {
		lines = append(lines, fmt.Sprintf(`  person: "%s"`, escapeBean(row.OperatorName)))
	}
	if row.OperatorNick != "" {
		lines = append(lines, fmt.Sprintf(`  operatorNick: "%s"`, escapeBean(row.OperatorNick)))
	}
	if row.Remark != "" {
		lines = append(lines, fmt.Sprintf(`  note: "%s"`, escapeBean(row.Remark)))
	}
	if row.Description != "" && row.Description != narration {
		lines = append(lines, fmt.Sprintf(`  description: "%s"`, escapeBean(row.Description)))
	}
	if merchant := alipaySmallPurseMerchantID(row.Description); merchant != "" {
		lines = append(lines, fmt.Sprintf(`  merchantId: "%s"`, escapeBean(merchant)))
	}
	if income > 0 {
		lines = append(lines,
			fmt.Sprintf("  %-38s %12s %s", alipaySmallPurseCashAccountForConfig(config), fromCents(amount), currency),
			fmt.Sprintf("  %-38s %12s %s", target, fromCents(-amount), currency),
		)
		return strings.Join(lines, "\n"), false, nil
	}
	if alipaySmallPurseSharedExpenseSplit(config) {
		ownShare := amount / 2
		partnerShare := amount - ownShare
		lines = append(lines,
			fmt.Sprintf("  %-38s %12s %s", target, fromCents(ownShare), currency),
			fmt.Sprintf("  %-38s %12s %s", alipaySmallPursePartnerLiabilityAccount(config), fromCents(partnerShare), currency),
			fmt.Sprintf("  %-38s %12s %s", alipaySmallPurseCashAccountForConfig(config), fromCents(-amount), currency),
		)
		return strings.Join(lines, "\n"), false, nil
	}
	lines = append(lines,
		fmt.Sprintf("  %-38s %12s %s", target, fromCents(amount), currency),
		fmt.Sprintf("  %-38s %12s %s", alipaySmallPurseCashAccountForConfig(config), fromCents(-amount), currency),
	)
	return strings.Join(lines, "\n"), false, nil
}

func alipaySmallPurseApplyRules(row alipaySmallPurseRow, payee string, amount int, txType, currentTarget string, config alipaySmallPurseConfig) (bool, string, []string) {
	target := currentTarget
	tags := []string{}
	for _, rule := range alipaySmallPurseRules(config) {
		if !alipaySmallPurseRuleMatches(rule, row, payee, abs(amount), txType) {
			continue
		}
		if rule.Ignore {
			return true, target, tags
		}
		if rule.TargetAccount != "" {
			target = rule.TargetAccount
		}
		if rule.Tag != "" {
			tags = strings.FieldsFunc(rule.Tag, func(r rune) bool { return r == ',' || r == '，' })
		}
	}
	return false, target, tags
}

func alipaySmallPurseCashAccountForConfig(config alipaySmallPurseConfig) string {
	if config.AlipaySmallPurse.CashAccount != "" {
		return config.AlipaySmallPurse.CashAccount
	}
	return valueOr(config.DefaultCashAccount, alipaySmallPurseCashAccount)
}

func alipaySmallPursePartnerLiabilityAccount(config alipaySmallPurseConfig) string {
	return valueOr(config.AlipaySmallPurse.PartnerLiabilityAccount, "Liabilities:Payable:Friends")
}

func alipaySmallPurseSharedExpenseSplit(config alipaySmallPurseConfig) bool {
	if config.AlipaySmallPurse.SharedExpenseSplit != nil {
		return *config.AlipaySmallPurse.SharedExpenseSplit
	}
	return true
}

func alipaySmallPurseRules(config alipaySmallPurseConfig) []alipaySmallPurseRule {
	if len(config.AlipaySmallPurse.Rules) > 0 {
		return config.AlipaySmallPurse.Rules
	}
	rules := make([]alipaySmallPurseRule, 0, len(config.Alipay.Rules))
	for _, rule := range config.Alipay.Rules {
		if strings.TrimSpace(rule.Type) == "收入" {
			continue
		}
		rules = append(rules, rule)
	}
	return rules
}

func alipaySmallPurseRuleMatches(rule alipaySmallPurseRule, row alipaySmallPurseRow, payee string, amount int, txType string) bool {
	sep := valueOr(rule.Separator, ",")
	matchFunc := splitContains
	if rule.FullMatch {
		matchFunc = splitEquals
	}
	description := row.Description
	if rule.Peer != "" && !matchFunc(rule.Peer, payee, sep) && !matchFunc(rule.Peer, description, sep) {
		return false
	}
	if rule.Item != "" && !matchFunc(rule.Item, description, sep) {
		return false
	}
	if rule.Category != "" {
		return false
	}
	if rule.Type != "" && !matchFunc(rule.Type, txType, sep) {
		return false
	}
	if rule.Method != "" && !matchFunc(rule.Method, "支付宝小荷包", sep) {
		return false
	}
	price := float64(amount) / 100
	if rule.MinPrice != nil && price < *rule.MinPrice {
		return false
	}
	if rule.MaxPrice != nil && price > *rule.MaxPrice {
		return false
	}
	return true
}

func parseAlipaySmallPurseXLSX(inputFile string) (alipaySmallPurseStatement, error) {
	rows, err := readXLSXRows(inputFile)
	if err != nil {
		return alipaySmallPurseStatement{}, err
	}
	statement := alipaySmallPurseStatement{}
	headerIndex := -1
	for index, row := range rows {
		first := strings.TrimSpace(cellAt(row, 0))
		switch {
		case strings.HasPrefix(first, "支付宝小荷包名称："):
			statement.WalletName = strings.TrimSpace(strings.TrimPrefix(first, "支付宝小荷包名称："))
		case strings.HasPrefix(first, "支付宝小荷包账户ID："):
			statement.AccountID = strings.TrimSpace(strings.TrimPrefix(first, "支付宝小荷包账户ID："))
		case strings.HasPrefix(first, "支付宝小荷包创建时间："):
			statement.CreatedAt = strings.TrimSpace(strings.TrimPrefix(first, "支付宝小荷包创建时间："))
		case strings.HasPrefix(first, "收支明细对应的期间："):
			statement.PeriodStart, statement.PeriodEnd = parseAlipaySmallPursePeriod(first)
		case alipaySmallPurseHeaderColumns(row) != nil:
			headerIndex = index
		}
	}
	if headerIndex < 0 {
		return alipaySmallPurseStatement{}, errors.New("找不到支付宝小荷包收支明细表头")
	}
	columns := alipaySmallPurseHeaderColumns(rows[headerIndex])
	required := []string{"订单号", "交易时间", "交易说明", "备注", "操作人昵称", "操作人姓名", "收入金额", "支出金额"}
	for _, name := range required {
		if _, ok := columns[name]; !ok {
			return alipaySmallPurseStatement{}, fmt.Errorf("支付宝小荷包 XLSX 缺少字段: %s", name)
		}
	}
	for index, row := range rows[headerIndex+1:] {
		if rowCellsEmpty(row) {
			continue
		}
		item := alipaySmallPurseRow{
			OrderID:      strings.TrimSpace(cellAt(row, columns["订单号"])),
			DateTime:     strings.TrimSpace(cellAt(row, columns["交易时间"])),
			Description:  strings.TrimSpace(cellAt(row, columns["交易说明"])),
			Remark:       strings.TrimSpace(cellAt(row, columns["备注"])),
			OperatorNick: strings.TrimSpace(cellAt(row, columns["操作人昵称"])),
			OperatorName: strings.TrimSpace(cellAt(row, columns["操作人姓名"])),
			Income:       strings.TrimSpace(cellAt(row, columns["收入金额"])),
			Expense:      strings.TrimSpace(cellAt(row, columns["支出金额"])),
			RowNumber:    headerIndex + index + 2,
		}
		if item.OrderID == "" && item.DateTime == "" {
			continue
		}
		statement.Rows = append(statement.Rows, item)
	}
	if len(statement.Rows) == 0 {
		return alipaySmallPurseStatement{}, errors.New("支付宝小荷包 XLSX 没有收支明细")
	}
	return statement, nil
}

func alipaySmallPurseHeaderColumns(row []string) map[string]int {
	columns := map[string]int{}
	for index, value := range row {
		name := strings.TrimSpace(value)
		if name != "" {
			columns[name] = index
		}
	}
	if _, ok := columns["订单号"]; !ok {
		return nil
	}
	if _, ok := columns["交易时间"]; !ok {
		return nil
	}
	if _, ok := columns["收入金额"]; !ok {
		return nil
	}
	if _, ok := columns["支出金额"]; !ok {
		return nil
	}
	return columns
}

func parseAlipaySmallPursePeriod(value string) (string, string) {
	match := regexp.MustCompile(`自\[(\d{4}年\d{2}月\d{2}日)\]至\[(\d{4}年\d{2}月\d{2}日)\]`).FindStringSubmatch(value)
	if match == nil {
		return "", ""
	}
	return normalizeChineseDate(match[1]), normalizeChineseDate(match[2])
}

func normalizeChineseDate(value string) string {
	match := regexp.MustCompile(`^(\d{4})年(\d{2})月(\d{2})日$`).FindStringSubmatch(strings.TrimSpace(value))
	if match == nil {
		return ""
	}
	return fmt.Sprintf("%s-%s-%s", match[1], match[2], match[3])
}

func alipaySmallPurseDateRange(statement alipaySmallPurseStatement) (string, string) {
	start := statement.PeriodStart
	end := statement.PeriodEnd
	for _, row := range statement.Rows {
		date := alipaySmallPurseDate(row.DateTime)
		if date == "" {
			continue
		}
		if start == "" || date < start {
			start = date
		}
		if end == "" || date > end {
			end = date
		}
	}
	return start, end
}

func alipaySmallPurseDate(value string) string {
	if len(value) < len("2006-01-02") {
		return ""
	}
	date := value[:len("2006-01-02")]
	if regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`).MatchString(date) {
		return date
	}
	return ""
}

func alipaySmallPursePayTime(value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	return strings.TrimSpace(value) + " +0800 CST"
}

func alipaySmallPursePayee(description, wallet string) string {
	description = strings.TrimSpace(description)
	if description == "" || strings.HasPrefix(description, "商户单号") {
		return "支付宝小荷包(" + valueOr(wallet, "未命名小荷包") + ")"
	}
	if strings.HasPrefix(description, "转入") || strings.HasPrefix(description, "转出") {
		return "支付宝小荷包(" + valueOr(wallet, "未命名小荷包") + ")"
	}
	cut := len(description)
	for _, sep := range []string{" ", "　", "("} {
		if idx := strings.Index(description, sep); idx >= 0 && idx < cut {
			cut = idx
		}
	}
	payee := strings.TrimSpace(description[:cut])
	if payee == "" {
		return "支付宝小荷包(" + valueOr(wallet, "未命名小荷包") + ")"
	}
	return payee
}

func alipaySmallPurseNarration(description, payee string) string {
	description = strings.TrimSpace(description)
	if description == "" {
		return "支付宝小荷包交易"
	}
	trimmed := strings.TrimSpace(strings.TrimPrefix(description, payee))
	trimmed = strings.TrimPrefix(trimmed, " ")
	if trimmed == "" {
		return description
	}
	return trimmed
}

func alipaySmallPurseMerchantID(description string) string {
	match := regexp.MustCompile(`商户单号([A-Za-z0-9_-]+)`).FindStringSubmatch(description)
	if match == nil {
		return ""
	}
	return match[1]
}

func rowCellsEmpty(row []string) bool {
	for _, cell := range row {
		if strings.TrimSpace(cell) != "" {
			return false
		}
	}
	return true
}

func cellAt(row []string, index int) string {
	if index < 0 || index >= len(row) {
		return ""
	}
	return row[index]
}

type xlsxWorksheet struct {
	Rows []xlsxRow `xml:"sheetData>row"`
}

type xlsxRow struct {
	Cells []xlsxCell `xml:"c"`
}

type xlsxCell struct {
	Ref    string           `xml:"r,attr"`
	Type   string           `xml:"t,attr"`
	Value  string           `xml:"v"`
	Inline xlsxInlineString `xml:"is"`
}

type xlsxInlineString struct {
	Texts []string `xml:"t"`
}

func readXLSXRows(inputFile string) ([][]string, error) {
	reader, err := zip.OpenReader(inputFile)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	shared, err := readXLSXSharedStrings(&reader.Reader)
	if err != nil {
		return nil, err
	}
	sheet, err := readXLSXSheet(&reader.Reader)
	if err != nil {
		return nil, err
	}
	out := make([][]string, 0, len(sheet.Rows))
	for _, row := range sheet.Rows {
		cells := []string{}
		for _, cell := range row.Cells {
			index := xlsxColumnIndex(cell.Ref)
			if index < 0 {
				index = len(cells)
			}
			for len(cells) <= index {
				cells = append(cells, "")
			}
			cells[index] = xlsxCellValue(cell, shared)
		}
		out = append(out, cells)
	}
	return out, nil
}

func readXLSXSharedStrings(reader *zip.Reader) ([]string, error) {
	file, err := openZipFile(reader, "xl/sharedStrings.xml")
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	decoder := xml.NewDecoder(file)
	shared := []string{}
	inString := false
	var builder strings.Builder
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		switch typed := token.(type) {
		case xml.StartElement:
			if typed.Name.Local == "si" {
				inString = true
				builder.Reset()
			}
			if inString && typed.Name.Local == "t" {
				var text string
				if err := decoder.DecodeElement(&text, &typed); err != nil {
					return nil, err
				}
				builder.WriteString(text)
			}
		case xml.EndElement:
			if typed.Name.Local == "si" && inString {
				shared = append(shared, builder.String())
				inString = false
			}
		}
	}
	return shared, nil
}

func readXLSXSheet(reader *zip.Reader) (xlsxWorksheet, error) {
	file, err := openZipFile(reader, "xl/worksheets/sheet1.xml")
	if err != nil {
		return xlsxWorksheet{}, err
	}
	defer file.Close()
	var sheet xlsxWorksheet
	if err := xml.NewDecoder(file).Decode(&sheet); err != nil {
		return xlsxWorksheet{}, err
	}
	return sheet, nil
}

func openZipFile(reader *zip.Reader, name string) (io.ReadCloser, error) {
	for _, file := range reader.File {
		if file.Name != name {
			continue
		}
		return file.Open()
	}
	return nil, os.ErrNotExist
}

func xlsxCellValue(cell xlsxCell, shared []string) string {
	switch cell.Type {
	case "s":
		index, err := strconv.Atoi(strings.TrimSpace(cell.Value))
		if err == nil && index >= 0 && index < len(shared) {
			return shared[index]
		}
	case "inlineStr":
		return strings.Join(cell.Inline.Texts, "")
	}
	return strings.TrimSpace(cell.Value)
}

func xlsxColumnIndex(ref string) int {
	letters := ""
	for _, r := range ref {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' {
			letters += strings.ToUpper(string(r))
			continue
		}
		break
	}
	if letters == "" {
		return -1
	}
	index := 0
	for _, r := range letters {
		index = index*26 + int(r-'A'+1)
	}
	return index - 1
}
