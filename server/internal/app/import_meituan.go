package app

import (
	"bytes"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Meituan (美团) exports a CSV with a preamble (用户名, 起止时间, 统计, 特别提示)
// before the table. DEG's mt provider reads it, but it slices the amount by
// bytes, panics on short rows and only accepts the half-width yuan sign, so the
// import hands it a normalized private copy: the header row and validated
// data rows only.

var meituanCSVHeaders = []string{
	"交易创建时间",
	"交易成功时间",
	"交易类型",
	"订单标题",
	"收/支",
	"支付方式",
	"订单金额",
	"实付金额",
	"交易单号",
	"商家单号",
	"备注",
}

const (
	meituanCSVTimeFormat = "2006-01-02 15:04:05"
	// meituanRequiredColumns are the columns DEG reads (up to 商家单号); 备注
	// is optional and padded when missing.
	meituanRequiredColumns = 10
)

func looksLikeMeituanCSV(filename, sample string) bool {
	if strings.Contains(sample, "美团交易账单明细") || strings.Contains(sample, "美团用户名") {
		return true
	}
	if strings.Contains(sample, strings.Join(meituanCSVHeaders[:meituanRequiredColumns], ",")) {
		return true
	}
	return strings.Contains(filename, "美团") && strings.Contains(sample, "交易单号,商家单号")
}

func (s *Server) prepareMeituanInput(inputFile, importID string) (preparedImportInput, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	text, err := decodeAlipayCSV(raw)
	if err != nil {
		return preparedImportInput{}, fmt.Errorf("美团账单 CSV 编码无效: %w", err)
	}
	output, prepared, err := normalizeMeituanCSV(normalizeCmbCSVText(text))
	if err != nil {
		return preparedImportInput{}, err
	}
	outputFile := previewPath(s.cfg, importID, "meituan-normalized.csv")
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return preparedImportInput{}, err
	}
	if err := os.WriteFile(outputFile, output, 0o600); err != nil {
		return preparedImportInput{}, err
	}
	prepared.InputFile = outputFile
	return prepared, nil
}

func normalizeMeituanCSV(text string) ([]byte, preparedImportInput, error) {
	reader := csv.NewReader(strings.NewReader(text))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true

	line := 0
	headerFound := false
	for !headerFound {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return nil, preparedImportInput{}, errors.New("美团账单 CSV 中没有找到明细表头（交易创建时间,交易成功时间,…）")
		}
		line++
		if err != nil {
			// The preamble is free text; only the table must be valid CSV.
			continue
		}
		if len(record) > 0 && strings.HasPrefix(strings.TrimSpace(record[0]), meituanCSVHeaders[0]) {
			if err := validateMeituanHeader(record); err != nil {
				return nil, preparedImportInput{}, err
			}
			headerFound = true
		}
	}

	var output bytes.Buffer
	writer := csv.NewWriter(&output)
	if err := writer.Write(meituanCSVHeaders); err != nil {
		return nil, preparedImportInput{}, err
	}
	rowCount := 0
	dateStart, dateEnd := "", ""
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		line++
		if err != nil {
			return nil, preparedImportInput{}, fmt.Errorf("读取美团账单 CSV 第 %d 行失败: %w", line, err)
		}
		if csvRecordEmpty(record) {
			continue
		}
		rowCount++
		row, payTime, err := normalizeMeituanRow(record)
		if err != nil {
			return nil, preparedImportInput{}, fmt.Errorf("美团账单 CSV 第 %d 行%s", line, err)
		}
		isoDate := payTime.Format("2006-01-02")
		if dateStart == "" || isoDate < dateStart {
			dateStart = isoDate
		}
		if dateEnd == "" || isoDate > dateEnd {
			dateEnd = isoDate
		}
		if err := writer.Write(row); err != nil {
			return nil, preparedImportInput{}, err
		}
	}
	if rowCount == 0 {
		return nil, preparedImportInput{}, errors.New("美团账单 CSV 没有交易明细")
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		return nil, preparedImportInput{}, err
	}
	return output.Bytes(), preparedImportInput{
		RawRowCount:      rowCount,
		FilteredRowCount: rowCount,
		DateStart:        dateStart,
		DateEnd:          dateEnd,
	}, nil
}

func validateMeituanHeader(header []string) error {
	if len(header) < meituanRequiredColumns {
		return fmt.Errorf("美团账单 CSV 表头字段数为 %d，预期至少 %d", len(header), meituanRequiredColumns)
	}
	for index, expected := range meituanCSVHeaders[:meituanRequiredColumns] {
		if got := strings.TrimSpace(header[index]); got != expected {
			return fmt.Errorf("美团账单 CSV 第 %d 列表头为 %q，预期 %q", index+1, got, expected)
		}
	}
	return nil
}

func normalizeMeituanRow(record []string) ([]string, time.Time, error) {
	if len(record) < meituanRequiredColumns {
		return nil, time.Time{}, fmt.Errorf("字段数为 %d，预期至少 %d", len(record), meituanRequiredColumns)
	}
	row := make([]string, len(meituanCSVHeaders))
	for index := range row {
		if index < len(record) {
			// Order numbers are exported with trailing tabs.
			row[index] = strings.TrimSpace(record[index])
		}
	}
	payTime, err := time.ParseInLocation(meituanCSVTimeFormat, row[0], time.FixedZone("CST", 8*3600))
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("交易创建时间无效: %s", row[0])
	}
	switch row[4] {
	case "支出", "收入", "不计收支", "":
	default:
		return nil, time.Time{}, fmt.Errorf("收/支无效: %s", row[4])
	}
	for _, index := range []int{6, 7} {
		if index == 6 && row[index] == "" {
			continue
		}
		amount, err := normalizeMeituanAmount(row[index])
		if err != nil {
			return nil, time.Time{}, fmt.Errorf("%s无效: %s", meituanCSVHeaders[index], row[index])
		}
		row[index] = amount
	}
	if row[8] == "" {
		return nil, time.Time{}, errors.New("缺少交易单号")
	}
	return row, payTime, nil
}

// normalizeMeituanAmount returns the amount as DEG expects it: a half-width
// yuan sign (two bytes, which DEG strips by byte offset) and a plain decimal.
func normalizeMeituanAmount(value string) (string, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "¥")
	value = strings.TrimPrefix(value, "￥")
	value = strings.ReplaceAll(strings.TrimSpace(value), ",", "")
	amount, err := strconv.ParseFloat(value, 64)
	if err != nil || amount < 0 || math.IsNaN(amount) || math.IsInf(amount, 0) {
		return "", errors.New("invalid amount")
	}
	formatted := strconv.FormatFloat(amount, 'f', 2, 64)
	// DEG parses the amount as a float32; refuse amounts it would round to a
	// different cent instead of writing a wrong number.
	if strconv.FormatFloat(float64(float32(amount)), 'f', 2, 64) != formatted {
		return "", errors.New("amount exceeds parser precision")
	}
	return "¥" + formatted, nil
}
