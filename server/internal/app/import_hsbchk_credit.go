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
	"regexp"
	"strconv"
	"strings"
	"time"
)

var hsbchkCreditCSVHeaders = []string{
	"Transaction date",
	"Post date",
	"Description",
	"Billing amount",
	"Billing currency",
	"Transaction status",
	"Merchant name",
	"Country / region",
	"Area / district",
	"Credit / Debit",
}

var hsbchkCurrencyPattern = regexp.MustCompile(`^[A-Z]{3}$`)
var hsbchkAmountPattern = regexp.MustCompile(`^-?(?:\d+|\d{1,3}(?:,\d{3})+)\.\d{2}$`)

const hsbchkCreditDateFormat = "02/01/2006"

func (s *Server) prepareHsbcHKCreditInput(inputFile, importID string) (preparedImportInput, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	text, err := decodeAlipayCSV(raw)
	if err != nil {
		return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 编码无效: %w", err)
	}

	// HSBC HK exports may place tab characters after quoted numeric fields.
	// DEG v2.15.1 cannot parse those records directly, so normalize a private
	// runtime copy before handing the statement to the upstream provider.
	text = strings.ReplaceAll(normalizeCmbCSVText(text), "\t", "")
	reader := csv.NewReader(strings.NewReader(text))
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if errors.Is(err, io.EOF) {
		return preparedImportInput{}, errors.New("HSBC HK 信用卡 CSV 为空")
	}
	if err != nil {
		return preparedImportInput{}, fmt.Errorf("读取 HSBC HK 信用卡 CSV 表头失败: %w", err)
	}
	if err := validateHsbcHKCreditHeader(header); err != nil {
		return preparedImportInput{}, err
	}

	var output bytes.Buffer
	writer := csv.NewWriter(&output)
	if err := writer.Write(hsbchkCreditCSVHeaders); err != nil {
		return preparedImportInput{}, err
	}

	rowCount := 0
	dateStart := ""
	dateEnd := ""
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return preparedImportInput{}, fmt.Errorf("读取 HSBC HK 信用卡 CSV 第 %d 行失败: %w", rowCount+2, err)
		}
		if csvRecordEmpty(record) {
			continue
		}
		rowCount++
		if len(record) != len(hsbchkCreditCSVHeaders) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行字段数为 %d，预期 %d", rowCount+1, len(record), len(hsbchkCreditCSVHeaders))
		}
		for index := range record {
			record[index] = strings.TrimSpace(record[index])
		}
		date, err := time.Parse(hsbchkCreditDateFormat, record[0])
		if err != nil {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行交易日期无效: %s", rowCount+1, record[0])
		}
		if _, err := time.Parse(hsbchkCreditDateFormat, record[1]); err != nil {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行入账日期无效: %s", rowCount+1, record[1])
		}
		if !hsbchkAmountPattern.MatchString(record[3]) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行账单金额无效: %s", rowCount+1, record[3])
		}
		amount, err := strconv.ParseFloat(strings.ReplaceAll(record[3], ",", ""), 64)
		if err != nil || amount == 0 || math.IsNaN(amount) || math.IsInf(amount, 0) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行账单金额无效: %s", rowCount+1, record[3])
		}
		currency := strings.ToUpper(record[4])
		if !hsbchkCurrencyPattern.MatchString(currency) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行币种无效: %s", rowCount+1, record[4])
		}
		record[4] = currency
		direction := strings.ToUpper(record[9])
		switch direction {
		case "DEBIT":
			if amount >= 0 {
				return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行 DEBIT 金额应为负数: %s", rowCount+1, record[3])
			}
		case "CREDIT":
			if amount <= 0 {
				return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行 CREDIT 金额应为正数: %s", rowCount+1, record[3])
			}
		default:
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行收支方向无效: %s", rowCount+1, record[9])
		}
		record[9] = direction
		isoDate := date.Format("2006-01-02")
		if dateStart == "" || isoDate < dateStart {
			dateStart = isoDate
		}
		if dateEnd == "" || isoDate > dateEnd {
			dateEnd = isoDate
		}
		if err := writer.Write(record); err != nil {
			return preparedImportInput{}, err
		}
	}
	if rowCount == 0 {
		return preparedImportInput{}, errors.New("HSBC HK 信用卡 CSV 没有交易明细")
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		return preparedImportInput{}, err
	}

	outputFile := previewPath(s.cfg, importID, "hsbchk-credit-normalized.csv")
	if err := os.MkdirAll(filepath.Dir(outputFile), 0o700); err != nil {
		return preparedImportInput{}, err
	}
	if err := os.WriteFile(outputFile, output.Bytes(), 0o600); err != nil {
		return preparedImportInput{}, err
	}
	return preparedImportInput{
		InputFile:        outputFile,
		RawRowCount:      rowCount,
		FilteredRowCount: rowCount,
		DateStart:        dateStart,
		DateEnd:          dateEnd,
	}, nil
}

func validateHsbcHKCreditHeader(header []string) error {
	if len(header) != len(hsbchkCreditCSVHeaders) {
		return fmt.Errorf("HSBC HK 信用卡 CSV 表头字段数为 %d，预期 %d", len(header), len(hsbchkCreditCSVHeaders))
	}
	for index, expected := range hsbchkCreditCSVHeaders {
		if strings.TrimSpace(header[index]) != expected {
			return fmt.Errorf("HSBC HK 信用卡 CSV 缺少或错置字段 %q", expected)
		}
	}
	return nil
}
