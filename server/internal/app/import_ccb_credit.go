package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/net/html"
	"gopkg.in/yaml.v3"
)

var ccbCreditCSVHeaders = []string{"交易日", "银行记账日", "卡号后四位", "交易描述", "交易币种", "交易金额", "结算币种", "结算金额"}

type ccbCreditConfig struct {
	DefaultMinusAccount string                 `yaml:"defaultMinusAccount"`
	DefaultPlusAccount  string                 `yaml:"defaultPlusAccount"`
	DefaultCashAccount  string                 `yaml:"defaultCashAccount"`
	DefaultCurrency     string                 `yaml:"defaultCurrency"`
	Title               string                 `yaml:"title"`
	CCBCredit           ccbCreditConfigSection `yaml:"ccbCredit"`
	CCB                 ccbCreditConfigSection `yaml:"ccb"`
}

type ccbCreditConfigSection struct {
	PaymentSourceHandledExternally []string        `yaml:"paymentSourceHandledExternally"`
	Rules                          []ccbCreditRule `yaml:"rules"`
}

type ccbCreditRule struct {
	Peer          string   `yaml:"peer"`
	Item          string   `yaml:"item"`
	Type          string   `yaml:"type"`
	TxType        string   `yaml:"txType"`
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

type ccbCreditRow struct {
	TransactionDate     string
	PostingDate         string
	CardLast4           string
	Description         string
	TransactionCurrency string
	TransactionAmount   string
	SettlementCurrency  string
	SettlementAmount    string
	RowNumber           int
}

type ccbCreditParsedStatement struct {
	Rows        []ccbCreditRow
	Statement   string
	Cycle       string
	DueDate     string
	NewBalance  string
	MinPayment  string
	RawRowCount int
}

func (s *Server) prepareCcbCreditInput(inputFile, originalFilename, importID string) (preparedImportInput, error) {
	ext := strings.ToLower(filepath.Ext(originalFilename))
	normalizedFile := inputFile
	warnings := []string{}
	rawRowCount := 0
	if ext == ".eml" || ext == ".html" || ext == ".htm" {
		statement, err := parseCcbCreditStatementFile(inputFile)
		if err != nil {
			return preparedImportInput{}, err
		}
		rawRowCount = len(statement.Rows)
		normalizedFile = previewPath(s.cfg, importID, "ccb-credit-normalized.csv")
		if err := writeCcbCreditCSV(statement.Rows, normalizedFile); err != nil {
			return preparedImportInput{}, err
		}
		warnings = append(warnings, fmt.Sprintf("已从建设银行信用卡邮件解析 %d 条账单明细。", len(statement.Rows)))
		if statement.Cycle != "" {
			warnings = append(warnings, "建行信用卡账单周期："+statement.Cycle)
		}
		if statement.DueDate != "" {
			warnings = append(warnings, "建行信用卡到期还款日："+statement.DueDate)
		}
	} else if ext == ".csv" {
		rows, err := readCcbCreditCSVRows(inputFile)
		if err != nil {
			return preparedImportInput{}, err
		}
		rawRowCount = len(rows)
		warnings = append(warnings, "当前上传的是建设银行信用卡标准 CSV。")
	} else {
		return preparedImportInput{}, fmt.Errorf("建设银行信用卡账单文件类型不正确，应为 .eml/.html/.csv")
	}

	prefilteredFile := previewPath(s.cfg, importID, "ccb-credit-prefiltered.csv")
	prefilter, err := s.prefilterCcbCreditCSV(normalizedFile, prefilteredFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	if rawRowCount == 0 {
		rawRowCount = prefilter.RawRowCount
	}
	warnings = append(warnings, prefilter.Warnings...)
	return preparedImportInput{InputFile: prefilteredFile, Warnings: warnings, RawRowCount: rawRowCount, FilteredRowCount: prefilter.FilteredRowCount, PrefilterSkipped: prefilter.Skipped}, nil
}

type ccbCreditCSVPrefilter struct {
	RawRowCount      int
	FilteredRowCount int
	Skipped          int
	Warnings         []string
}

func (s *Server) prefilterCcbCreditCSV(inputFile, outputFile string) (ccbCreditCSVPrefilter, error) {
	rows, err := readCcbCreditCSVRows(inputFile)
	if err != nil {
		return ccbCreditCSVPrefilter{}, err
	}
	config, err := s.loadCcbCreditConfig()
	if err != nil {
		return ccbCreditCSVPrefilter{}, err
	}
	prefixes := config.CreditSection().PaymentSourceHandledExternally
	if len(prefixes) == 0 {
		prefixes = []string{"支付宝-", "财付通-", "微信支付-"}
	}
	kept := []ccbCreditRow{}
	skipped := 0
	for _, row := range rows {
		if ccbCreditHasPrefix(row.Description, prefixes) {
			skipped++
			continue
		}
		kept = append(kept, row)
	}
	if err := writeCcbCreditCSV(kept, outputFile); err != nil {
		return ccbCreditCSVPrefilter{}, err
	}
	warnings := []string{fmt.Sprintf("建设银行信用卡账单 Web 前置过滤 %d 条支付宝/财付通/微信支付明细，避免重复导入。", skipped)}
	return ccbCreditCSVPrefilter{RawRowCount: len(rows), FilteredRowCount: len(kept), Skipped: skipped, Warnings: warnings}, nil
}

func (s *Server) generateCcbCreditBean(inputFile, outputFile string) error {
	config, err := s.loadCcbCreditConfig()
	if err != nil {
		return err
	}
	rows, err := readCcbCreditCSVRows(inputFile)
	if err != nil {
		return err
	}
	statement := normalizedCcbCreditStatement(rows, ccbCreditParsedStatement{})
	blocks := make([]string, 0, len(statement.Transactions))
	for _, transaction := range statement.Transactions {
		amount := transaction.Amount
		if amount == 0 {
			continue
		}
		row := ccbCreditRowFromNormalized(transaction)
		block, ignore := renderCcbCreditEntry(row, amount, config)
		if ignore {
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

func normalizedCcbCreditStatement(rows []ccbCreditRow, parsed ccbCreditParsedStatement) normalizedStatement {
	statement := normalizedStatement{
		Provider:        "ccb-credit",
		Title:           "建设银行信用卡账单",
		StatementDate:   parsed.Statement,
		Cycle:           parsed.Cycle,
		DueDate:         parsed.DueDate,
		DefaultCurrency: "CNY",
		Transactions:    make([]normalizedTransaction, 0, len(rows)),
	}
	for _, row := range rows {
		statement.Transactions = append(statement.Transactions, normalizedCcbCreditTransaction(row))
	}
	return statement
}

func normalizedCcbCreditTransaction(row ccbCreditRow) normalizedTransaction {
	return normalizedTransaction{
		Date:                row.TransactionDate,
		PostingDate:         row.PostingDate,
		AccountLast4:        row.CardLast4,
		Description:         row.Description,
		TransactionCurrency: row.TransactionCurrency,
		TransactionAmount:   row.TransactionAmount,
		SettlementCurrency:  valueOr(row.SettlementCurrency, "CNY"),
		SettlementAmount:    row.SettlementAmount,
		Amount:              cents(row.SettlementAmount),
		RowNumber:           row.RowNumber,
		Source:              "ccb-credit",
	}
}

func ccbCreditRowFromNormalized(transaction normalizedTransaction) ccbCreditRow {
	return ccbCreditRow{
		TransactionDate:     transaction.Date,
		PostingDate:         transaction.PostingDate,
		CardLast4:           transaction.AccountLast4,
		Description:         transaction.Description,
		TransactionCurrency: transaction.TransactionCurrency,
		TransactionAmount:   transaction.TransactionAmount,
		SettlementCurrency:  valueOr(transaction.SettlementCurrency, "CNY"),
		SettlementAmount:    transaction.SettlementAmount,
		RowNumber:           transaction.RowNumber,
	}
}

func (s *Server) loadCcbCreditConfig() (ccbCreditConfig, error) {
	config := ccbCreditConfig{
		DefaultMinusAccount: "Expenses:Unknown",
		DefaultPlusAccount:  "Expenses:Unknown",
		DefaultCashAccount:  "Liabilities:CN:CCB:CreditCard:7720",
		DefaultCurrency:     "CNY",
		Title:               "建设银行信用卡账单",
	}
	raw, err := os.ReadFile(filepath.Join(s.cfg.LedgerRoot, "imports/ccb-credit-card-config.yaml"))
	if err != nil {
		return config, err
	}
	if err := yaml.Unmarshal(raw, &config); err != nil {
		return config, err
	}
	if config.DefaultMinusAccount == "" {
		config.DefaultMinusAccount = "Expenses:Unknown"
	}
	if config.DefaultPlusAccount == "" {
		config.DefaultPlusAccount = "Expenses:Unknown"
	}
	if config.DefaultCashAccount == "" {
		config.DefaultCashAccount = "Liabilities:CN:CCB:CreditCard:7720"
	}
	if config.DefaultCurrency == "" {
		config.DefaultCurrency = "CNY"
	}
	return config, nil
}

func (config ccbCreditConfig) CreditSection() ccbCreditConfigSection {
	if len(config.CCBCredit.Rules) > 0 || len(config.CCBCredit.PaymentSourceHandledExternally) > 0 {
		return config.CCBCredit
	}
	return config.CCB
}

func renderCcbCreditEntry(row ccbCreditRow, amount int, config ccbCreditConfig) (string, bool) {
	currency := valueOr(row.SettlementCurrency, config.DefaultCurrency)
	txType := "charge"
	target := ccbCreditTargetAccount(row, amount, txType, config)
	if amount < 0 {
		txType = "refund"
		target = ccbCreditTargetAccount(row, amount, txType, config)
	}
	ignore, target, tags := ccbCreditApplyRules(row, amount, txType, target, config)
	if ignore {
		return "", true
	}
	payee := ccbCreditPayee(row.Description)
	lines := []string{fmt.Sprintf(`%s * "%s" "%s"`, row.TransactionDate, escapeBean(payee), escapeBean(row.Description))}
	lines = append(lines,
		fmt.Sprintf(`  cardLast4: "%s"`, escapeBean(row.CardLast4)),
		fmt.Sprintf(`  method: "%s"`, escapeBean("建设银行信用卡")),
		fmt.Sprintf(`  orderId: "%s"`, ccbCreditOrderID(row)),
		fmt.Sprintf(`  postingDate: "%s"`, escapeBean(row.PostingDate)),
		fmt.Sprintf(`  row: "%d"`, row.RowNumber),
		`  source: "ccb-credit"`,
		fmt.Sprintf(`  txType: "%s"`, txType),
	)
	if row.TransactionCurrency != "" {
		lines = append(lines, fmt.Sprintf(`  transactionCurrency: "%s"`, escapeBean(row.TransactionCurrency)))
	}
	if row.TransactionAmount != "" {
		lines = append(lines, fmt.Sprintf(`  transactionAmount: "%s"`, escapeBean(row.TransactionAmount)))
	}
	for _, tag := range tags {
		if tag != "" {
			lines[0] += " #" + sanitizeBeanTag(tag)
		}
	}
	if amount < 0 {
		lines = append(lines,
			fmt.Sprintf("  %-34s %12s %s", target, fromCents(amount), currency),
			fmt.Sprintf("  %-34s %12s %s", config.DefaultCashAccount, fromCents(-amount), currency),
		)
		return strings.Join(lines, "\n"), false
	}
	lines = append(lines,
		fmt.Sprintf("  %-34s %12s %s", target, fromCents(amount), currency),
		fmt.Sprintf("  %-34s %12s %s", config.DefaultCashAccount, fromCents(-amount), currency),
	)
	return strings.Join(lines, "\n"), false
}

func ccbCreditTargetAccount(row ccbCreditRow, amount int, txType string, config ccbCreditConfig) string {
	if amount < 0 || txType == "refund" {
		return config.DefaultMinusAccount
	}
	return config.DefaultPlusAccount
}

func ccbCreditApplyRules(row ccbCreditRow, amount int, txType, currentTarget string, config ccbCreditConfig) (bool, string, []string) {
	section := config.CreditSection()
	target := currentTarget
	tags := []string{}
	typeLabel := "支出"
	if amount < 0 || txType == "refund" {
		typeLabel = "收入"
	}
	for _, rule := range section.Rules {
		if !ccbCreditRuleMatches(rule, row, abs(amount), txType, typeLabel) {
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

func ccbCreditRuleMatches(rule ccbCreditRule, row ccbCreditRow, amount int, txType, typeLabel string) bool {
	sep := valueOr(rule.Separator, ",")
	matchFunc := splitContains
	if rule.FullMatch {
		matchFunc = splitEquals
	}
	if rule.Item != "" && !matchFunc(rule.Item, row.Description, sep) {
		return false
	}
	if rule.Peer != "" && !matchFunc(rule.Peer, row.Description, sep) {
		return false
	}
	if rule.TxType != "" && !matchFunc(rule.TxType, txType, sep) {
		return false
	}
	if rule.Type != "" && !matchFunc(rule.Type, typeLabel, sep) {
		return false
	}
	if rule.Method != "" && !matchFunc(rule.Method, "建设银行信用卡", sep) && !matchFunc(rule.Method, row.CardLast4, sep) {
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

func splitContains(pattern, value, sep string) bool {
	for _, item := range strings.Split(pattern, sep) {
		item = strings.TrimSpace(item)
		if item != "" && strings.Contains(value, item) {
			return true
		}
	}
	return false
}

func splitEquals(pattern, value, sep string) bool {
	for _, item := range strings.Split(pattern, sep) {
		item = strings.TrimSpace(item)
		if item != "" && value == item {
			return true
		}
	}
	return false
}

func ccbCreditPayee(description string) string {
	payee := strings.TrimSpace(description)
	for _, prefix := range []string{"财付通-微信支付-", "支付宝-支付宝-消费-", "支付宝-", "财付通-", "微信支付-"} {
		payee = strings.TrimPrefix(payee, prefix)
	}
	return valueOr(payee, "建设银行信用卡")
}

func ccbCreditOrderID(row ccbCreditRow) string {
	canonical := strings.Join([]string{row.TransactionDate, row.PostingDate, row.CardLast4, row.Description, row.SettlementCurrency, row.SettlementAmount}, "\x00")
	sum := sha256.Sum256([]byte(canonical))
	return "ccb-credit-" + hex.EncodeToString(sum[:8])
}

func sanitizeBeanTag(value string) string {
	value = strings.TrimSpace(value)
	value = regexp.MustCompile(`[^A-Za-z0-9_-]+`).ReplaceAllString(value, "-")
	return strings.Trim(value, "-")
}

func ccbCreditHasPrefix(description string, prefixes []string) bool {
	for _, prefix := range prefixes {
		prefix = strings.TrimSpace(prefix)
		if prefix != "" && strings.HasPrefix(description, prefix) {
			return true
		}
	}
	return false
}

func readCcbCreditCSVRows(inputFile string) ([]ccbCreditRow, error) {
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
	if errors.Is(err, io.EOF) {
		return []ccbCreditRow{}, nil
	}
	if err != nil {
		return nil, err
	}
	columns := map[string]int{}
	for index, name := range header {
		columns[strings.TrimSpace(name)] = index
	}
	columnNames := ccbCreditCSVColumnNames{
		TransactionDate:     "交易日",
		PostingDate:         "银行记账日",
		CardLast4:           "卡号后四位",
		Description:         "交易描述",
		TransactionCurrency: "交易币种",
		TransactionAmount:   "交易金额",
		SettlementCurrency:  "结算币种",
		SettlementAmount:    "结算金额",
	}
	if _, ok := columns[columnNames.TransactionDate]; !ok {
		columnNames = ccbCreditCSVColumnNames{
			TransactionDate:     "transactionDate",
			PostingDate:         "postingDate",
			CardLast4:           "cardLast4",
			Description:         "description",
			TransactionCurrency: "transactionCurrency",
			TransactionAmount:   "transactionAmount",
			SettlementCurrency:  "settlementCurrency",
			SettlementAmount:    "settlementAmount",
		}
	}
	for _, name := range columnNames.Required() {
		if _, ok := columns[name]; !ok {
			return nil, fmt.Errorf("建设银行信用卡 CSV 缺少字段: %s", name)
		}
	}
	rows := []ccbCreditRow{}
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
		row := ccbCreditRow{
			TransactionDate:     csvField(record, columns[columnNames.TransactionDate]),
			PostingDate:         csvField(record, columns[columnNames.PostingDate]),
			CardLast4:           csvField(record, columns[columnNames.CardLast4]),
			Description:         csvField(record, columns[columnNames.Description]),
			TransactionCurrency: ccbCreditCurrency(csvField(record, columns[columnNames.TransactionCurrency])),
			TransactionAmount:   csvField(record, columns[columnNames.TransactionAmount]),
			SettlementCurrency:  ccbCreditCurrency(valueOr(csvField(record, columns[columnNames.SettlementCurrency]), "CNY")),
			SettlementAmount:    csvField(record, columns[columnNames.SettlementAmount]),
			RowNumber:           rowNumber,
		}
		if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`).MatchString(row.TransactionDate) {
			return nil, fmt.Errorf("第 %d 行交易日无效: %s", rowNumber, row.TransactionDate)
		}
		if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`).MatchString(row.PostingDate) {
			return nil, fmt.Errorf("第 %d 行银行记账日无效: %s", rowNumber, row.PostingDate)
		}
		rows = append(rows, row)
	}
	return rows, nil
}

type ccbCreditCSVColumnNames struct {
	TransactionDate     string
	PostingDate         string
	CardLast4           string
	Description         string
	TransactionCurrency string
	TransactionAmount   string
	SettlementCurrency  string
	SettlementAmount    string
}

func (names ccbCreditCSVColumnNames) Required() []string {
	return []string{names.TransactionDate, names.PostingDate, names.CardLast4, names.Description, names.TransactionCurrency, names.TransactionAmount, names.SettlementCurrency, names.SettlementAmount}
}

func ccbCreditCurrency(value string) string {
	switch strings.TrimSpace(value) {
	case "", "人民币", "人民币元", "CNY":
		return "CNY"
	case "美元", "USD":
		return "USD"
	default:
		return strings.TrimSpace(value)
	}
}

func writeCcbCreditCSV(rows []ccbCreditRow, outputFile string) error {
	csvRows := []string{csvLine(ccbCreditCSVHeaders)}
	for _, row := range rows {
		csvRows = append(csvRows, csvLine([]string{
			row.TransactionDate,
			row.PostingDate,
			row.CardLast4,
			row.Description,
			row.TransactionCurrency,
			row.TransactionAmount,
			row.SettlementCurrency,
			row.SettlementAmount,
		}))
	}
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return err
	}
	return os.WriteFile(outputFile, []byte(strings.Join(csvRows, "\n")+"\n"), 0o600)
}

func parseCcbCreditStatementFile(inputFile string) (ccbCreditParsedStatement, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return ccbCreditParsedStatement{}, err
	}
	ext := strings.ToLower(filepath.Ext(inputFile))
	if ext == ".eml" || bytes.Contains(raw, []byte("Content-Type:")) {
		htmlBody, err := extractHTMLFromEML(raw)
		if err != nil {
			return ccbCreditParsedStatement{}, err
		}
		return parseCcbCreditStatementHTML(htmlBody)
	}
	return parseCcbCreditStatementHTML(string(raw))
}

func extractHTMLFromEML(raw []byte) (string, error) {
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	contentType := msg.Header.Get("Content-Type")
	mediaType, params, _ := mime.ParseMediaType(contentType)
	if strings.HasPrefix(mediaType, "multipart/") {
		boundary := params["boundary"]
		if boundary == "" {
			return "", errors.New("建设银行信用卡邮件缺少 multipart boundary")
		}
		reader := multipart.NewReader(msg.Body, boundary)
		for {
			part, err := reader.NextPart()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return "", err
			}
			partMediaType, _, _ := mime.ParseMediaType(part.Header.Get("Content-Type"))
			body, err := readMIMEPartBody(part.Header, part)
			if err != nil {
				return "", err
			}
			if partMediaType == "text/html" {
				return string(body), nil
			}
		}
	}
	body, err := readMIMEPartBody(msg.Header, msg.Body)
	if err != nil {
		return "", err
	}
	if mediaType == "text/html" || strings.Contains(string(body), "<html") {
		return string(body), nil
	}
	return "", errors.New("未在建设银行信用卡邮件中找到 HTML 正文")
}

type mimeHeader interface {
	Get(string) string
}

func readMIMEPartBody(header mimeHeader, reader io.Reader) ([]byte, error) {
	encoding := strings.ToLower(strings.TrimSpace(header.Get("Content-Transfer-Encoding")))
	switch encoding {
	case "base64":
		return io.ReadAll(base64.NewDecoder(base64.StdEncoding, reader))
	case "quoted-printable":
		return io.ReadAll(quotedPrintableReader(reader))
	default:
		return io.ReadAll(reader)
	}
}

func quotedPrintableReader(reader io.Reader) io.Reader {
	return quotedprintable.NewReader(reader)
}

func parseCcbCreditStatementHTML(raw string) (ccbCreditParsedStatement, error) {
	tokens, err := htmlTextTokens(raw)
	if err != nil {
		return ccbCreditParsedStatement{}, err
	}
	statement := ccbCreditParsedStatement{
		Statement:  firstDateAfter(tokens, "本期账单日"),
		Cycle:      firstCycleAfter(tokens, "账单周期"),
		DueDate:    firstDateAfter(tokens, "本期到期还款日"),
		NewBalance: "",
		MinPayment: "",
	}
	rows := parseCcbCreditRowsFromTokens(tokens)
	if len(rows) == 0 {
		return ccbCreditParsedStatement{}, errors.New("未从建设银行信用卡邮件中解析到交易明细")
	}
	statement.Rows = rows
	statement.RawRowCount = len(rows)
	return statement, nil
}

func htmlTextTokens(raw string) ([]string, error) {
	root, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		return nil, err
	}
	tokens := []string{}
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if node.Type == html.TextNode {
			text := strings.ReplaceAll(node.Data, "\u00a0", " ")
			for _, field := range strings.Fields(text) {
				field = strings.TrimSpace(field)
				if field != "" {
					tokens = append(tokens, field)
				}
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(root)
	return tokens, nil
}

func parseCcbCreditRowsFromTokens(tokens []string) []ccbCreditRow {
	start := 0
	for index, token := range tokens {
		if token == "【交易明细】" {
			start = index
			break
		}
	}
	rows := []ccbCreditRow{}
	dateRe := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	cardRe := regexp.MustCompile(`^\d{4}$`)
	moneyRe := regexp.MustCompile(`^-?[\d,]+\.\d{2}$`)
	for i := start; i+7 < len(tokens); i++ {
		if !dateRe.MatchString(tokens[i]) || !dateRe.MatchString(tokens[i+1]) || !cardRe.MatchString(tokens[i+2]) {
			continue
		}
		row := ccbCreditRow{TransactionDate: tokens[i], PostingDate: tokens[i+1], CardLast4: tokens[i+2], RowNumber: len(rows) + 1}
		j := i + 3
		descriptionParts := []string{}
		for j < len(tokens) && !ccbCreditCurrencyToken(tokens[j]) {
			descriptionParts = append(descriptionParts, tokens[j])
			j++
		}
		if len(descriptionParts) == 0 || j+3 >= len(tokens) {
			continue
		}
		if !moneyRe.MatchString(tokens[j+1]) || !ccbCreditCurrencyToken(tokens[j+2]) || !moneyRe.MatchString(tokens[j+3]) {
			continue
		}
		row.Description = strings.Join(descriptionParts, "")
		row.TransactionCurrency = tokens[j]
		row.TransactionAmount = strings.ReplaceAll(tokens[j+1], ",", "")
		row.SettlementCurrency = tokens[j+2]
		row.SettlementAmount = strings.ReplaceAll(tokens[j+3], ",", "")
		rows = append(rows, row)
		i = j + 3
	}
	return rows
}

func ccbCreditCurrencyToken(value string) bool {
	return regexp.MustCompile(`^[A-Z]{3}$`).MatchString(value)
}

func firstDateAfter(tokens []string, marker string) string {
	dateRe := regexp.MustCompile(`^\d{4}[-/]\d{2}[-/]\d{2}$`)
	for index, token := range tokens {
		if token != marker {
			continue
		}
		for _, candidate := range tokens[index+1:] {
			if dateRe.MatchString(candidate) {
				return strings.ReplaceAll(candidate, "/", "-")
			}
		}
	}
	return ""
}

func firstCycleAfter(tokens []string, marker string) string {
	cycleRe := regexp.MustCompile(`^\d{4}/\d{2}/\d{2}-\d{4}/\d{2}/\d{2}$`)
	for index, token := range tokens {
		if token != marker {
			continue
		}
		for _, candidate := range tokens[index+1:] {
			if cycleRe.MatchString(candidate) {
				return candidate
			}
		}
	}
	return ""
}
