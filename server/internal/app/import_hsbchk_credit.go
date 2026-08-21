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
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
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
var hsbchkAmountPattern = regexp.MustCompile(`^[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)\.\d{2}$`)

const hsbchkCreditDateFormat = "02/01/2006"

var hsbchkCreditDateFormats = []string{
	hsbchkCreditDateFormat,
	"2/1/2006",
	"2006-01-02",
}

func (s *Server) prepareHsbcHKCreditInput(inputFile, importID string) (preparedImportInput, error) {
	raw, err := os.ReadFile(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	text, err := decodeHsbcHKCreditCSV(raw)
	if err != nil {
		return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 编码无效: %w", err)
	}

	// HSBC HK exports may place tab characters after quoted numeric fields.
	// DEG v2.15.1 cannot parse those records directly, so normalize a private
	// runtime copy before handing the statement to the upstream provider.
	text = stripHsbcHKCSVPaddingTabs(normalizeCmbCSVText(text))
	reader := csv.NewReader(strings.NewReader(text))
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true

	header, err := readHsbcHKCreditHeader(reader)
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
		if err := validateHsbcHKCreditTextFields(record); err != nil {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行%s", rowCount+1, err)
		}
		date, err := parseHsbcHKCreditDate(record[0])
		if err != nil {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行交易日期无效: %s", rowCount+1, record[0])
		}
		postDate, err := parseHsbcHKCreditDate(record[1])
		if err != nil {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行入账日期无效: %s", rowCount+1, record[1])
		}
		if !hsbchkAmountPattern.MatchString(record[3]) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行账单金额无效: %s", rowCount+1, record[3])
		}
		amount, err := strconv.ParseFloat(strings.ReplaceAll(record[3], ",", ""), 64)
		if err != nil || amount == 0 || math.IsNaN(amount) || math.IsInf(amount, 0) {
			return preparedImportInput{}, fmt.Errorf("HSBC HK 信用卡 CSV 第 %d 行账单金额无效: %s", rowCount+1, record[3])
		}
		record[0] = date.Format(hsbchkCreditDateFormat)
		record[1] = postDate.Format(hsbchkCreditDateFormat)
		record[3] = strings.TrimPrefix(strings.ReplaceAll(record[3], ",", ""), "+")
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
		if normalizeHsbcHKCreditHeader(header[index]) != normalizeHsbcHKCreditHeader(expected) {
			return fmt.Errorf("HSBC HK 信用卡 CSV 缺少或错置字段 %q", expected)
		}
	}
	return nil
}

func decodeHsbcHKCreditCSV(raw []byte) (string, error) {
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
	if utf8.Valid(raw) {
		return string(raw), nil
	}
	type candidate struct {
		text  string
		score int
	}
	candidates := []candidate{}
	for _, decoder := range []func([]byte) ([]byte, error){
		traditionalchinese.Big5.NewDecoder().Bytes,
		simplifiedchinese.GB18030.NewDecoder().Bytes,
	} {
		decoded, err := decoder(raw)
		if err != nil || !utf8.Valid(decoded) || bytes.ContainsRune(decoded, unicode.ReplacementChar) {
			continue
		}
		text := strings.TrimPrefix(string(decoded), "\uFEFF")
		candidates = append(candidates, candidate{text: text, score: legacyChineseDecodeScore(text)})
	}
	if len(candidates) == 0 {
		return "", errors.New("既不是 UTF-8、Big5，也不是 GB18030")
	}
	best := candidates[0]
	for _, current := range candidates[1:] {
		if current.score < best.score {
			best = current
			continue
		}
		if current.score == best.score && current.text != best.text {
			return "", errors.New("Big5 与 GB18030 编码无法可靠区分，请先另存为 UTF-8 CSV")
		}
	}
	return best.text, nil
}

func legacyChineseDecodeScore(text string) int {
	// Big5 and GB18030 byte ranges overlap, so both decoders can sometimes
	// succeed. Prefer the result without common cross-decoding artifacts while
	// keeping Big5 as the tie-breaker for a Hong Kong bank export.
	score := 0
	for _, char := range text {
		switch {
		case char >= 0xE000 && char <= 0xF8FF:
			score += 10
		case unicode.In(char, unicode.Hiragana, unicode.Katakana):
			score += 5
		case char > 0xFFFF:
			score += 2
		}
	}
	return score
}

func stripHsbcHKCSVPaddingTabs(text string) string {
	var output strings.Builder
	output.Grow(len(text))
	inQuotes := false
	for index := 0; index < len(text); index++ {
		char := text[index]
		if char == '"' {
			output.WriteByte(char)
			if inQuotes && index+1 < len(text) && text[index+1] == '"' {
				output.WriteByte(text[index+1])
				index++
				continue
			}
			inQuotes = !inQuotes
			continue
		}
		if char == '\t' && !inQuotes {
			continue
		}
		output.WriteByte(char)
	}
	return output.String()
}

func readHsbcHKCreditHeader(reader *csv.Reader) ([]string, error) {
	for {
		header, err := reader.Read()
		if err != nil {
			return nil, err
		}
		if !csvRecordEmpty(header) {
			return header, nil
		}
	}
}

func parseHsbcHKCreditDate(value string) (time.Time, error) {
	for _, format := range hsbchkCreditDateFormats {
		if parsed, err := time.Parse(format, value); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported HSBC HK date %q", value)
}

func normalizeHsbcHKCreditHeader(value string) string {
	normalized := strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(value)), " "))
	return strings.ReplaceAll(normalized, " / ", "/")
}

func validateHsbcHKCreditTextFields(record []string) error {
	for _, index := range []int{2, 5, 6, 7, 8} {
		if strings.IndexFunc(record[index], unicode.IsControl) >= 0 {
			return fmt.Errorf("字段 %q 包含不允许的控制字符", hsbchkCreditCSVHeaders[index])
		}
	}
	return nil
}

func looksLikeHsbcHKCreditCSV(sample string) bool {
	// The official header is ASCII in every supported encoding. Parse it from
	// the original sample so a 32 KiB detection sample cut through a later
	// multibyte merchant name cannot hide an otherwise valid statement.
	text := strings.TrimPrefix(sample, "\uFEFF")
	reader := csv.NewReader(strings.NewReader(stripHsbcHKCSVPaddingTabs(normalizeCmbCSVText(text))))
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true
	header, err := readHsbcHKCreditHeader(reader)
	return err == nil && validateHsbcHKCreditHeader(header) == nil
}
