package app

import (
	"bytes"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

type providerSourceAnalysis struct {
	RawRowCount      int
	FilteredRowCount int
	ExcludedRowCount int
	Warnings         []string
}

type alipaySourceRow struct {
	DateTime string
	Category string
	Payee    string
	Merchant string
	Item     string
	Type     string
	Amount   string
	Method   string
	Status   string
	OrderID  string
}

func (s *Server) prepareAlipayCSVForDEG(inputFile, importID string) (preparedImportInput, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	text, err := decodeAlipayCSV(raw)
	if err != nil {
		return preparedImportInput{}, err
	}
	info, err := alipayCSVHeaderInfo(text)
	if err != nil {
		return preparedImportInput{
			InputFile: inputFile,
			Warnings: []string{"支付宝 CSV 表头位置检测失败：" + err.Error()},
		}, nil
	}
	if info.RecordIndex == 23 {
		return preparedImportInput{InputFile: inputFile}, nil
	}
	if info.RecordIndex <= 0 || info.LineIndex < 0 {
		return preparedImportInput{InputFile: inputFile}, nil
	}
	if info.RecordIndex > 23 {
		return preparedImportInput{
			InputFile: inputFile,
			Warnings:  []string{fmt.Sprintf("支付宝 CSV 表头位于第 %d 条 record，DEG 期望第 23 条；未自动调整。", info.RecordIndex)},
		}, nil
	}

	paddingCount := 23 - info.RecordIndex
	lines := strings.Split(normalizeCmbCSVText(text), "\n")
	padding := make([]string, 0, paddingCount)
	for i := 0; i < paddingCount; i++ {
		padding = append(padding, fmt.Sprintf("; DEG 支付宝表头兼容占位行 %d", i+1))
	}
	adjustedLines := append([]string{}, lines[:info.LineIndex]...)
	adjustedLines = append(adjustedLines, padding...)
	adjustedLines = append(adjustedLines, lines[info.LineIndex:]...)
	adjustedText := strings.Join(adjustedLines, "\n") + "\n"
	outputFile := previewPath(s.cfg, importID, "alipay-deg-compatible.csv")
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return preparedImportInput{}, err
	}
	if err := os.WriteFile(outputFile, encodeAlipayCSV(adjustedText), 0o600); err != nil {
		return preparedImportInput{}, err
	}
	return preparedImportInput{
		InputFile:        outputFile,
		Warnings:         []string{fmt.Sprintf("已插入 %d 条临时占位行修正支付宝 CSV 表头位置，避免 DEG 跳过第一条交易。", paddingCount)},
		RawRowCount:      0,
		FilteredRowCount: 0,
	}, nil
}

type alipayHeaderInfo struct {
	RecordIndex int
	LineIndex   int
}

func alipayCSVHeaderInfo(text string) (alipayHeaderInfo, error) {
	normalized := normalizeCmbCSVText(text)
	reader := csv.NewReader(strings.NewReader(normalized))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	recordIndex := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return alipayHeaderInfo{}, err
		}
		recordIndex++
		if alipayRecordLooksLikeHeader(record) {
			lineIndex := -1
			for index, line := range strings.Split(normalized, "\n") {
				if strings.Contains(line, "交易时间") && strings.Contains(line, "交易订单号") {
					lineIndex = index
					break
				}
			}
			return alipayHeaderInfo{RecordIndex: recordIndex, LineIndex: lineIndex}, nil
		}
	}
	return alipayHeaderInfo{}, errors.New("找不到支付宝 CSV 表头")
}

func alipayRecordLooksLikeHeader(record []string) bool {
	hasTime, hasOrderID := false, false
	for _, field := range record {
		switch strings.TrimSpace(field) {
		case "交易时间":
			hasTime = true
		case "交易订单号":
			hasOrderID = true
		}
	}
	return hasTime && hasOrderID
}

func (s *Server) analyzeAlipayImportSource(inputFile, generatedBean string) (providerSourceAnalysis, error) {
	rows, err := readAlipaySourceRows(inputFile)
	if err != nil {
		return providerSourceAnalysis{}, err
	}
	generatedIDs := orderIDsFromBean(generatedBean)
	missing := []alipaySourceRow{}
	for _, row := range rows {
		if row.OrderID == "" {
			continue
		}
		if !generatedIDs[row.OrderID] {
			missing = append(missing, row)
		}
	}
	analysis := providerSourceAnalysis{
		RawRowCount:      len(rows),
		FilteredRowCount: len(rows) - len(missing),
		ExcludedRowCount: len(missing),
	}
	if len(missing) == 0 {
		return analysis, nil
	}
	statusCounts := map[string]int{}
	for _, row := range missing {
		statusCounts[valueOr(row.Status, "未知状态")]++
	}
	analysis.Warnings = append(analysis.Warnings, fmt.Sprintf(
		"支付宝原始账单有 %d 条明细没有进入 DEG 生成结果（原始 %d 条，生成 %d 条）；按状态：%s。",
		len(missing),
		len(rows),
		parseBeanSummary(generatedBean).CandidateCount,
		formatStatusCounts(statusCounts),
	))
	analysis.Warnings = append(analysis.Warnings, "未生成示例："+formatAlipayRowExamples(missing, 3))
	return analysis, nil
}

func readAlipaySourceRows(inputFile string) ([]alipaySourceRow, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return nil, err
	}
	text, err := decodeAlipayCSV(raw)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(normalizeCmbCSVText(text), "\n")
	headerIndex := -1
	for index, line := range lines {
		if strings.Contains(line, "交易时间") && strings.Contains(line, "交易订单号") {
			headerIndex = index
			break
		}
	}
	if headerIndex < 0 {
		return nil, errors.New("找不到支付宝 CSV 表头")
	}
	reader := csv.NewReader(strings.NewReader(strings.Join(lines[headerIndex:], "\n")))
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
	required := []string{"交易时间", "交易分类", "交易对方", "商品说明", "收/支", "金额", "收/付款方式", "交易状态", "交易订单号", "商家订单号"}
	for _, name := range required {
		if _, ok := columns[name]; !ok {
			return nil, fmt.Errorf("支付宝 CSV 缺少字段: %s", name)
		}
	}
	rows := []alipaySourceRow{}
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
		row := alipaySourceRow{
			DateTime: csvField(record, columns["交易时间"]),
			Category: csvField(record, columns["交易分类"]),
			Payee:    csvField(record, columns["交易对方"]),
			Merchant: csvField(record, columns["商家订单号"]),
			Item:     csvField(record, columns["商品说明"]),
			Type:     csvField(record, columns["收/支"]),
			Amount:   csvField(record, columns["金额"]),
			Method:   csvField(record, columns["收/付款方式"]),
			Status:   csvField(record, columns["交易状态"]),
			OrderID:  csvField(record, columns["交易订单号"]),
		}
		if row.DateTime == "" && row.OrderID == "" {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func decodeAlipayCSV(raw []byte) (string, error) {
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
	if utf8.Valid(raw) {
		return string(raw), nil
	}
	decoded, err := simplifiedchinese.GB18030.NewDecoder().Bytes(raw)
	if err != nil {
		return "", err
	}
	return strings.TrimPrefix(string(decoded), "\uFEFF"), nil
}

func encodeAlipayCSV(text string) []byte {
	encoded, err := simplifiedchinese.GB18030.NewEncoder().Bytes([]byte(text))
	if err != nil {
		return []byte(text)
	}
	return encoded
}

func orderIDsFromBean(beanText string) map[string]bool {
	ids := map[string]bool{}
	for _, match := range regexp.MustCompile(`(?m)^\s+orderId:\s+"?([^"\n]+)"?`).FindAllStringSubmatch(beanText, -1) {
		ids[strings.TrimSpace(match[1])] = true
	}
	return ids
}

func csvField(record []string, index int) string {
	if index < 0 || index >= len(record) {
		return ""
	}
	return strings.TrimSpace(record[index])
}

func csvRecordEmpty(record []string) bool {
	for _, value := range record {
		if strings.TrimSpace(value) != "" {
			return false
		}
	}
	return true
}

func formatStatusCounts(counts map[string]int) string {
	statuses := make([]string, 0, len(counts))
	for status := range counts {
		statuses = append(statuses, status)
	}
	sort.Strings(statuses)
	parts := make([]string, 0, len(statuses))
	for _, status := range statuses {
		parts = append(parts, fmt.Sprintf("%s %d 条", status, counts[status]))
	}
	return strings.Join(parts, "，")
}

func formatAlipayRowExamples(rows []alipaySourceRow, limit int) string {
	examples := []string{}
	for index, row := range rows {
		if index >= limit {
			break
		}
		name := row.Item
		if name == "" {
			name = row.Payee
		}
		examples = append(examples, fmt.Sprintf("%s %s %s ¥%s", row.DateTime, row.Status, name, row.Amount))
	}
	if len(rows) > limit {
		examples = append(examples, fmt.Sprintf("另外 %d 条", len(rows)-limit))
	}
	return strings.Join(examples, "；")
}
