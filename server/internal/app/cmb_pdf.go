package app

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	pdf "github.com/ledongthuc/pdf"
)

var cmbPDFHeaders = []string{"交易日", "记账日", "交易摘要", "人民币金额", "卡号末四位", "交易地金额"}

type cmbPDFParseResult struct {
	CSV                   string
	Title                 string
	RowCount              int
	MissingCardLast4Count int
	Warnings              []string
}

type pdfTextItem struct {
	Text string
	X    float64
	Y    float64
	W    float64
}

type pdfTextLine struct {
	Y     float64
	Items []pdfTextItem
}

type cmbPDFHeaderInfo struct {
	Title  string
	Ranges []cmbPDFColumnRange
}

type cmbPDFColumnRange struct {
	Title string
	Index int
	Left  float64
	Right float64
}

func parseCmbCreditPDFToCSV(inputFile string) (cmbPDFParseResult, error) {
	file, reader, err := pdf.Open(inputFile)
	if err != nil {
		return cmbPDFParseResult{}, err
	}
	defer file.Close()

	if reader.NumPage() == 0 {
		return cmbPDFParseResult{}, errors.New("招商银行信用卡 PDF 没有页面")
	}
	headerInfo, err := extractCmbPDFHeaderInfo(reader.Page(1))
	if err != nil {
		return cmbPDFParseResult{}, err
	}

	rows := [][]string{}
	rawRows := 0
	for pageNo := 1; pageNo <= reader.NumPage(); pageNo++ {
		pageRows := extractCmbPDFRows(reader.Page(pageNo), headerInfo)
		rawRows += len(pageRows)
		for _, row := range pageRows {
			normalized := normalizeCmbPDFRow(row)
			if looksLikeCmbPDFDataRow(normalized) {
				rows = append(rows, normalized)
			}
		}
	}

	warnings := []string{}
	if len(rows) == 0 {
		warnings = append(warnings, "未从招商银行信用卡 PDF 中解析到交易明细。")
	}
	missingCardLast4 := 0
	for _, row := range rows {
		if row[4] == "" {
			missingCardLast4++
		}
	}
	if missingCardLast4 > 0 {
		warnings = append(warnings, fmt.Sprintf("%d 条交易缺少卡号末四位，已保留空列避免金额错位。", missingCardLast4))
	}
	if skipped := rawRows - len(rows); skipped > 0 {
		warnings = append(warnings, fmt.Sprintf("PDF 中有 %d 行表格文本未匹配为交易明细，已跳过。", skipped))
	}

	csvRows := []string{headerInfo.Title, csvLine(cmbPDFHeaders)}
	for _, row := range rows {
		csvRows = append(csvRows, csvLine(row))
	}
	return cmbPDFParseResult{CSV: strings.Join(csvRows, "\n"), Title: headerInfo.Title, RowCount: len(rows), MissingCardLast4Count: missingCardLast4, Warnings: warnings}, nil
}

func extractCmbPDFHeaderInfo(page pdf.Page) (cmbPDFHeaderInfo, error) {
	lines := groupPDFTextLines(pageTextItems(page))
	var title string
	var headerLine pdfTextLine
	for _, line := range lines {
		text := compactPDFLineText(line)
		if strings.Contains(text, "招商银行信用卡对账单") {
			title = text
		}
		matchesAllHeaders := true
		for _, header := range cmbPDFHeaders {
			if !strings.Contains(text, header) {
				matchesAllHeaders = false
				break
			}
		}
		if matchesAllHeaders {
			headerLine = line
		}
	}
	if title == "" {
		return cmbPDFHeaderInfo{}, errors.New("未识别到招商银行信用卡对账单标题")
	}
	if len(headerLine.Items) == 0 {
		return cmbPDFHeaderInfo{}, fmt.Errorf("未找到招行信用卡 PDF 表头: %s", strings.Join(cmbPDFHeaders, ", "))
	}

	ranges := []cmbPDFColumnRange{}
	for index, header := range cmbPDFHeaders {
		x, ok := findHeaderX(headerLine, header)
		if !ok {
			return cmbPDFHeaderInfo{}, fmt.Errorf("未找到招行信用卡 PDF 表头: %s", header)
		}
		ranges = append(ranges, cmbPDFColumnRange{Title: header, Index: index, Left: x, Right: 9999})
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].Left < ranges[j].Left })
	for i := range ranges {
		if i+1 < len(ranges) {
			ranges[i].Right = ranges[i+1].Left - 0.01
		}
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].Index < ranges[j].Index })
	return cmbPDFHeaderInfo{Title: title, Ranges: ranges}, nil
}

func extractCmbPDFRows(page pdf.Page, headerInfo cmbPDFHeaderInfo) [][]string {
	lines := groupPDFTextLines(pageTextItems(page))
	rows := [][]string{}
	for _, line := range lines {
		cells := make([]string, len(cmbPDFHeaders))
		hasCell := false
		for _, item := range line.Items {
			col := cmbPDFColumnForX(item.X, headerInfo.Ranges)
			if col < 0 {
				continue
			}
			cells[col] += strings.TrimSpace(item.Text)
			hasCell = true
		}
		if !hasCell {
			continue
		}
		rows = append(rows, cells)
	}
	return rows
}

func pageTextItems(page pdf.Page) []pdfTextItem {
	content := page.Content()
	items := make([]pdfTextItem, 0, len(content.Text))
	for _, text := range content.Text {
		value := strings.TrimSpace(text.S)
		if value == "" {
			continue
		}
		items = append(items, pdfTextItem{Text: value, X: text.X, Y: text.Y, W: text.W})
	}
	return items
}

func groupPDFTextLines(items []pdfTextItem) []pdfTextLine {
	sort.Slice(items, func(i, j int) bool {
		if absFloat(items[i].Y-items[j].Y) > 1.5 {
			return items[i].Y > items[j].Y
		}
		return items[i].X < items[j].X
	})
	lines := []pdfTextLine{}
	for _, item := range items {
		found := -1
		for i := range lines {
			if absFloat(lines[i].Y-item.Y) <= 2.0 {
				found = i
				break
			}
		}
		if found < 0 {
			lines = append(lines, pdfTextLine{Y: item.Y, Items: []pdfTextItem{item}})
			continue
		}
		lines[found].Items = append(lines[found].Items, item)
		lines[found].Y = (lines[found].Y + item.Y) / 2
	}
	for i := range lines {
		sort.Slice(lines[i].Items, func(a, b int) bool { return lines[i].Items[a].X < lines[i].Items[b].X })
	}
	sort.Slice(lines, func(i, j int) bool { return lines[i].Y > lines[j].Y })
	return lines
}

func compactPDFLineText(line pdfTextLine) string {
	var builder strings.Builder
	for _, item := range line.Items {
		builder.WriteString(strings.TrimSpace(item.Text))
	}
	return builder.String()
}

func findHeaderX(line pdfTextLine, header string) (float64, bool) {
	type charPos struct {
		Char rune
		X    float64
	}
	chars := []charPos{}
	for _, item := range line.Items {
		for _, ch := range []rune(strings.TrimSpace(item.Text)) {
			chars = append(chars, charPos{Char: ch, X: item.X})
		}
	}
	text := make([]rune, len(chars))
	for i, item := range chars {
		text[i] = item.Char
	}
	target := []rune(header)
	for i := 0; i+len(target) <= len(text); i++ {
		matched := true
		for j := range target {
			if text[i+j] != target[j] {
				matched = false
				break
			}
		}
		if matched {
			return chars[i].X, true
		}
	}
	return 0, false
}

func cmbPDFColumnForX(x float64, ranges []cmbPDFColumnRange) int {
	for _, column := range ranges {
		if x >= column.Left && x <= column.Right {
			return column.Index
		}
	}
	return -1
}

func normalizeCmbPDFRow(row []string) []string {
	out := make([]string, len(cmbPDFHeaders))
	for i := range out {
		if i < len(row) {
			out[i] = strings.TrimSpace(row[i])
		}
	}
	return out
}

func looksLikeCmbPDFDataRow(row []string) bool {
	if len(row) < len(cmbPDFHeaders) {
		return false
	}
	dateRe := regexp.MustCompile(`^(0[1-9]|1[0-2])/(0[1-9]|[12][0-9]|3[01])$`)
	moneyRe := regexp.MustCompile(`^-?\d[\d,]*\.\d{2}(?:\([A-Z]+\))?$`)
	cardRe := regexp.MustCompile(`^\d{4}$`)
	return (row[0] == "" || dateRe.MatchString(row[0])) &&
		dateRe.MatchString(row[1]) &&
		row[2] != "" &&
		moneyRe.MatchString(row[3]) &&
		(row[4] == "" || cardRe.MatchString(row[4])) &&
		moneyRe.MatchString(row[5])
}

func csvLine(cells []string) string {
	quoted := make([]string, len(cells))
	for i, cell := range cells {
		quoted[i] = csvCell(cell)
	}
	return strings.Join(quoted, ",")
}

func csvCell(value string) string {
	if strings.ContainsAny(value, "\",\n\r") {
		return `"` + strings.ReplaceAll(value, `"`, `""`) + `"`
	}
	return value
}

func writeCmbPDFCSV(inputFile, outputFile string) (preparedImportInput, error) {
	parsed, err := parseCmbCreditPDFToCSV(inputFile)
	if err != nil {
		return preparedImportInput{}, err
	}
	if err := os.WriteFile(outputFile, []byte(parsed.CSV), 0o600); err != nil {
		return preparedImportInput{}, err
	}
	warnings := []string{fmt.Sprintf("已从招商银行信用卡 PDF 解析 %d 条账单明细。", parsed.RowCount)}
	warnings = append(warnings, parsed.Warnings...)
	return preparedImportInput{InputFile: outputFile, Warnings: warnings, RawRowCount: parsed.RowCount, FilteredRowCount: parsed.RowCount}, nil
}

func absFloat(value float64) float64 {
	if value < 0 {
		return -value
	}
	return value
}
