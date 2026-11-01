package mobileagent

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

// reconcile_attachment compares statement rows with the ledger's postings
// to the reconciled accounts. Matching is done here, deterministically; the
// model only says which columns hold what, and explains the differences.
const (
	maxReconcileListed  = 40
	maxInlineRows       = 600
	defaultToleranceDay = 3
	maxToleranceDay     = 10
)

func decodeStrict(raw []byte, target any) error {
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = []byte(`{}`)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("invalid tool arguments: %w", err)
	}
	return nil
}

type reconcileInput struct {
	ID                 string     `json:"id"`
	Sheet              string     `json:"sheet"`
	HeaderRow          int        `json:"headerRow"`
	DateColumn         string     `json:"dateColumn"`
	AmountColumn       string     `json:"amountColumn"`
	InColumn           string     `json:"inColumn"`
	OutColumn          string     `json:"outColumn"`
	DirectionColumn    string     `json:"directionColumn"`
	InValues           []string   `json:"inValues"`
	OutValues          []string   `json:"outValues"`
	DescriptionColumns []string   `json:"descriptionColumns"`
	AmountSign         string     `json:"amountSign"`
	Rows               []inlineV1 `json:"rows"`
	Accounts           []string   `json:"accounts"`
	Start              string     `json:"start"`
	End                string     `json:"end"`
	ToleranceDays      *int       `json:"toleranceDays"`
	Currency           string     `json:"currency"`
}

type inlineV1 struct {
	Date        string          `json:"date"`
	Amount      json.RawMessage `json:"amount"`
	Description string          `json:"description"`
}

// statementRow is one money movement of the statement, signed as a change
// of the account's balance: money in is positive, money out negative.
type statementRow struct {
	row         int
	date        time.Time
	cents       int
	description string
}

type skippedRow struct {
	Row    int    `json:"row"`
	Reason string `json:"reason"`
}

var (
	defaultInValues  = []string{"收入", "收", "入账", "存入", "转入", "退款", "贷"}
	defaultOutValues = []string{"支出", "支", "出账", "消费", "取出", "转出", "借"}
	dateHeaderWords  = []string{"日期", "时间", "date", "交易日", "记账日"}
	moneyHeaderWords = []string{"金额", "amount", "收入", "支出", "借方", "贷方", "存入", "取出"}
)

// statementRows reads the statement from the attachment's table, or from
// rows the model transcribed out of a PDF or an image.
func (a *attachments) statementRows(input reconcileInput) ([]statementRow, []skippedRow, map[string]any, error) {
	if len(input.Rows) > 0 {
		if len(input.Rows) > maxInlineRows {
			return nil, nil, nil, fmt.Errorf("rows 最多 %d 行；更多时分段对账", maxInlineRows)
		}
		var rows []statementRow
		var skipped []skippedRow
		for index, raw := range input.Rows {
			date, ok := parseStatementDate(raw.Date)
			if !ok {
				skipped = append(skipped, skippedRow{index + 1, "日期无法识别：" + clip(raw.Date, 30)})
				continue
			}
			text := strings.Trim(string(raw.Amount), `"`)
			cents, ok := parseStatementAmount(text)
			if !ok {
				skipped = append(skipped, skippedRow{index + 1, "金额无法识别：" + clip(text, 30)})
				continue
			}
			if input.AmountSign == "expense_positive" {
				cents = -cents
			}
			rows = append(rows, statementRow{row: index + 1, date: date, cents: cents, description: raw.Description})
		}
		return rows, skipped, map[string]any{"source": "rows"}, nil
	}
	if input.ID == "" {
		return nil, nil, nil, errors.New("需要 id（表格附件）或 rows（从 PDF、图片整理出的明细）")
	}
	_, parsed, err := a.load(input.ID)
	if err != nil {
		return nil, nil, nil, err
	}
	sheet, err := parsed.sheet(input.Sheet)
	if err != nil {
		return nil, nil, nil, err
	}
	headerRow := input.HeaderRow
	if headerRow <= 0 {
		headerRow = detectHeaderRow(sheet.rows)
		if headerRow == 0 {
			return nil, nil, nil, errors.New("没有找到表头行；请用 read_attachment 查看后传 headerRow")
		}
	}
	if headerRow > len(sheet.rows) {
		return nil, nil, nil, fmt.Errorf("headerRow %d 超出表格（共 %d 行）", headerRow, len(sheet.rows))
	}
	header := sheet.rows[headerRow-1]
	resolve := func(ref, role string, required bool) (int, error) {
		if strings.TrimSpace(ref) == "" {
			if required {
				return -1, fmt.Errorf("需要 %s", role)
			}
			return -1, nil
		}
		column, ok := resolveColumn(header, ref)
		if !ok {
			return -1, fmt.Errorf("%s %q 不在表头里；表头是：%s", role, ref, strings.Join(header, " | "))
		}
		return column, nil
	}
	dateColumn, err := resolve(input.DateColumn, "dateColumn", true)
	if err != nil {
		return nil, nil, nil, err
	}
	amountColumn, err := resolve(input.AmountColumn, "amountColumn", false)
	if err != nil {
		return nil, nil, nil, err
	}
	inColumn, err := resolve(input.InColumn, "inColumn", false)
	if err != nil {
		return nil, nil, nil, err
	}
	outColumn, err := resolve(input.OutColumn, "outColumn", false)
	if err != nil {
		return nil, nil, nil, err
	}
	directionColumn, err := resolve(input.DirectionColumn, "directionColumn", false)
	if err != nil {
		return nil, nil, nil, err
	}
	if amountColumn < 0 && inColumn < 0 && outColumn < 0 {
		return nil, nil, nil, errors.New("需要 amountColumn，或者 inColumn / outColumn")
	}
	var descriptionColumns []int
	for _, ref := range input.DescriptionColumns {
		column, err := resolve(ref, "descriptionColumns", true)
		if err != nil {
			return nil, nil, nil, err
		}
		descriptionColumns = append(descriptionColumns, column)
	}
	inValues, outValues := input.InValues, input.OutValues
	if len(inValues) == 0 {
		inValues = defaultInValues
	}
	if len(outValues) == 0 {
		outValues = defaultOutValues
	}
	cell := func(row []string, column int) string {
		if column < 0 || column >= len(row) {
			return ""
		}
		return row[column]
	}
	var rows []statementRow
	var skipped []skippedRow
	for index := headerRow; index < len(sheet.rows); index++ {
		row := sheet.rows[index]
		number := index + 1
		if len(row) == 0 {
			continue
		}
		date, ok := parseStatementDate(cell(row, dateColumn))
		if !ok {
			// Totals, footnotes and blank separators sit under many tables.
			skipped = append(skipped, skippedRow{number, "日期无法识别：" + clip(cell(row, dateColumn), 30)})
			continue
		}
		var cents int
		switch {
		case amountColumn >= 0:
			value, ok := parseStatementAmount(cell(row, amountColumn))
			if !ok {
				skipped = append(skipped, skippedRow{number, "金额无法识别：" + clip(cell(row, amountColumn), 30)})
				continue
			}
			cents = value
			if directionColumn >= 0 {
				direction := cell(row, directionColumn)
				switch directionOf(direction, inValues, outValues) {
				case -1:
					cents = -abs(cents)
				case 1:
					cents = abs(cents)
				default:
					skipped = append(skipped, skippedRow{number, "收支方向不明或不计收支：" + clip(direction, 30)})
					continue
				}
			} else if input.AmountSign == "expense_positive" {
				cents = -cents
			}
		default:
			in, inOK := parseStatementAmount(cell(row, inColumn))
			out, outOK := parseStatementAmount(cell(row, outColumn))
			if !inOK && !outOK {
				skipped = append(skipped, skippedRow{number, "收入、支出列都没有金额"})
				continue
			}
			cents = abs(in) - abs(out)
		}
		var parts []string
		for _, column := range descriptionColumns {
			if value := cell(row, column); value != "" && value != "/" {
				parts = append(parts, value)
			}
		}
		rows = append(rows, statementRow{row: number, date: date, cents: cents, description: strings.Join(parts, " ")})
	}
	mapping := map[string]any{"source": "attachment", "id": input.ID, "sheet": sheet.name, "headerRow": headerRow, "dateColumn": cell(header, dateColumn)}
	if amountColumn >= 0 {
		mapping["amountColumn"] = cell(header, amountColumn)
	}
	if directionColumn >= 0 {
		mapping["directionColumn"] = cell(header, directionColumn)
	}
	return rows, skipped, mapping, nil
}

func detectHeaderRow(rows [][]string) int {
	for index, row := range rows[:min(len(rows), 60)] {
		hasDate, hasMoney := false, false
		for _, cell := range row {
			lowered := strings.ToLower(cell)
			if len([]rune(lowered)) > 16 {
				continue
			}
			hasDate = hasDate || containsAny(lowered, dateHeaderWords)
			hasMoney = hasMoney || containsAny(lowered, moneyHeaderWords)
		}
		if hasDate && hasMoney {
			return index + 1
		}
	}
	return 0
}

var columnLetters = regexp.MustCompile(`^[A-Za-z]{1,2}$`)

// resolveColumn finds a column by header text (exact, then the only header
// containing it), by letter (A, B, AA) or by 1-based number.
func resolveColumn(header []string, ref string) (int, bool) {
	ref = strings.TrimSpace(ref)
	for index, name := range header {
		if strings.EqualFold(strings.TrimSpace(name), ref) {
			return index, true
		}
	}
	match := -1
	for index, name := range header {
		if strings.Contains(strings.ToLower(name), strings.ToLower(ref)) {
			if match >= 0 {
				match = -2
				break
			}
			match = index
		}
	}
	if match >= 0 {
		return match, true
	}
	if columnLetters.MatchString(ref) {
		column := 0
		for _, letter := range strings.ToUpper(ref) {
			column = column*26 + int(letter-'A'+1)
		}
		return column - 1, true
	}
	if number, err := strconv.Atoi(ref); err == nil && number > 0 {
		return number - 1, true
	}
	return -1, false
}

// directionOf reads a direction cell: -1 money out, 1 money in, 0 neither
// (for example Alipay's 不计收支). An exact value wins over a contained one.
func directionOf(value string, inValues, outValues []string) int {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" || strings.Contains(value, "不计") {
		return 0
	}
	for _, word := range outValues {
		if strings.EqualFold(strings.TrimSpace(word), value) {
			return -1
		}
	}
	for _, word := range inValues {
		if strings.EqualFold(strings.TrimSpace(word), value) {
			return 1
		}
	}
	out, in := containsAny(value, outValues), containsAny(value, inValues)
	switch {
	case out && !in:
		return -1
	case in && !out:
		return 1
	}
	return 0
}

func containsAny(value string, words []string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return false
	}
	for _, word := range words {
		if word = strings.ToLower(strings.TrimSpace(word)); word != "" && strings.Contains(value, word) {
			return true
		}
	}
	return false
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

var (
	ymdPattern     = regexp.MustCompile(`(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})`)
	compactPattern = regexp.MustCompile(`^(\d{4})(\d{2})(\d{2})(\d{6})?$`)
	excelEpoch     = time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)
)

func parseStatementDate(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if match := ymdPattern.FindStringSubmatch(value); match != nil {
		return civilDate(match[1], match[2], match[3])
	}
	if match := compactPattern.FindStringSubmatch(value); match != nil {
		return civilDate(match[1], match[2], match[3])
	}
	// An Excel serial day, as cells formatted as dates read without format.
	if serial, err := strconv.ParseFloat(value, 64); err == nil && serial > 20000 && serial < 80000 {
		return excelEpoch.AddDate(0, 0, int(serial)), true
	}
	return time.Time{}, false
}

func civilDate(year, month, day string) (time.Time, bool) {
	y, _ := strconv.Atoi(year)
	m, _ := strconv.Atoi(month)
	d, _ := strconv.Atoi(day)
	if y < 1990 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31 {
		return time.Time{}, false
	}
	date := time.Date(y, time.Month(m), d, 0, 0, 0, 0, time.UTC)
	if date.Day() != d {
		return time.Time{}, false
	}
	return date, true
}

// parseStatementAmount reads amounts as statements print them: currency
// signs, thousands separators, a trailing minus, parentheses or CR/DR.
func parseStatementAmount(value string) (int, bool) {
	value = strings.TrimSpace(value)
	if value == "" || value == "-" || value == "/" || value == "--" {
		return 0, false
	}
	negative := false
	upper := strings.ToUpper(value)
	if strings.HasSuffix(upper, "DR") {
		negative, value = true, strings.TrimSpace(value[:len(value)-2])
	} else if strings.HasSuffix(upper, "CR") {
		value = strings.TrimSpace(value[:len(value)-2])
	}
	if strings.HasPrefix(value, "(") && strings.HasSuffix(value, ")") {
		negative, value = true, value[1:len(value)-1]
	}
	value = strings.NewReplacer("¥", "", "￥", "", ",", "", "，", "", " ", "", "元", "", "\u00a0", "", "−", "-", "－", "-", "＋", "+").Replace(value)
	for _, code := range []string{"CNY", "RMB", "USD", "HKD", "人民币"} {
		value = strings.TrimSuffix(strings.TrimPrefix(value, code), code)
	}
	if strings.HasSuffix(value, "-") {
		negative, value = !negative, strings.TrimSuffix(value, "-")
	}
	if value == "" || !strings.ContainsFunc(value, unicode.IsDigit) {
		return 0, false
	}
	number, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsInf(number, 0) || math.Abs(number) > 1e11 {
		return 0, false
	}
	cents := int(math.Round(number * 100))
	if negative {
		cents = -cents
	}
	return cents, true
}

func money(cents int) string {
	sign := ""
	if cents < 0 {
		sign, cents = "-", -cents
	}
	return fmt.Sprintf("%s%d.%02d", sign, cents/100, cents%100)
}

type ledgerPosting struct {
	app.LocalAgentPosting
	date time.Time
}

type reconcileMatch struct {
	statement statementRow
	ledger    ledgerPosting
}

// match pairs rows and postings of the same amount within the tolerance,
// nearest date first and the closer description on a tie, then pairs what
// is left by date and description as amount mismatches.
func match(rows []statementRow, postings []ledgerPosting, tolerance int) (matched, mismatched []reconcileMatch, missing []statementRow, extra []ledgerPosting) {
	used := make([]bool, len(postings))
	rowUsed := make([]bool, len(rows))
	for index, row := range rows {
		best, bestDays, bestScore := -1, 0, 0
		for candidate, posting := range postings {
			if used[candidate] || posting.Amount != row.cents {
				continue
			}
			days := dayDistance(row.date, posting.date)
			if days > tolerance {
				continue
			}
			score := similarity(row.description, posting.Payee+" "+posting.Narration)
			if best < 0 || days < bestDays || (days == bestDays && score > bestScore) {
				best, bestDays, bestScore = candidate, days, score
			}
		}
		if best >= 0 {
			used[best], rowUsed[index] = true, true
			matched = append(matched, reconcileMatch{row, postings[best]})
		}
	}
	for index, row := range rows {
		if rowUsed[index] || strings.TrimSpace(row.description) == "" {
			continue
		}
		best, bestScore, bestDays := -1, 0, 0
		for candidate, posting := range postings {
			if used[candidate] || (posting.Amount < 0) != (row.cents < 0) {
				continue
			}
			days := dayDistance(row.date, posting.date)
			if days > tolerance {
				continue
			}
			score := similarity(row.description, posting.Payee+" "+posting.Narration)
			if score == 0 {
				continue
			}
			if best < 0 || score > bestScore || (score == bestScore && days < bestDays) {
				best, bestScore, bestDays = candidate, score, days
			}
		}
		if best >= 0 {
			used[best], rowUsed[index] = true, true
			mismatched = append(mismatched, reconcileMatch{row, postings[best]})
		}
	}
	for index, row := range rows {
		if !rowUsed[index] {
			missing = append(missing, row)
		}
	}
	for index, posting := range postings {
		if !used[index] {
			extra = append(extra, posting)
		}
	}
	return matched, mismatched, missing, extra
}

func dayDistance(a, b time.Time) int {
	days := int(a.Sub(b).Hours() / 24)
	return abs(days)
}

// similarity is the length of the longest common substring, counted only
// when it is meaningful: two CJK characters, or four other characters.
func similarity(a, b string) int {
	left := []rune(strings.ToLower(clip(a, 80)))
	right := []rune(strings.ToLower(clip(b, 80)))
	if len(left) == 0 || len(right) == 0 {
		return 0
	}
	best, bestEnd := 0, 0
	previous := make([]int, len(right)+1)
	current := make([]int, len(right)+1)
	for i := 1; i <= len(left); i++ {
		for j := 1; j <= len(right); j++ {
			if left[i-1] == right[j-1] && !unicode.IsSpace(left[i-1]) {
				current[j] = previous[j-1] + 1
				if current[j] > best {
					best, bestEnd = current[j], i
				}
			} else {
				current[j] = 0
			}
		}
		previous, current = current, previous
	}
	common := left[bestEnd-best : bestEnd]
	wide := slices.ContainsFunc(common, func(r rune) bool { return r > unicode.MaxASCII })
	if (wide && best >= 2) || best >= 4 {
		return best
	}
	return 0
}

type postingSource interface {
	Postings(start, end string, accounts []string) ([]app.LocalAgentPosting, error)
}

func reconcile(a *attachments, ledger postingSource, raw []byte) (any, error) {
	var input reconcileInput
	if err := decodeStrict(raw, &input); err != nil {
		return nil, err
	}
	if len(input.Accounts) == 0 {
		return nil, errors.New("需要 accounts：要对账的账本账户，例如 Liabilities:CreditCard:CMB（先用 get_accounts 确认）")
	}
	if input.AmountSign != "" && input.AmountSign != "balance" && input.AmountSign != "expense_positive" {
		return nil, errors.New("amountSign 只能是 balance 或 expense_positive")
	}
	tolerance := defaultToleranceDay
	if input.ToleranceDays != nil {
		tolerance = min(max(*input.ToleranceDays, 0), maxToleranceDay)
	}
	if a == nil {
		a = &attachments{}
	}
	rows, skipped, mapping, err := a.statementRows(input)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("没有读到任何明细；跳过的行：%s", describeSkipped(skipped))
	}
	first, last := rows[0].date, rows[0].date
	for _, row := range rows {
		if row.date.Before(first) {
			first = row.date
		}
		if row.date.After(last) {
			last = row.date
		}
	}
	start, end := first.Format(time.DateOnly), last.AddDate(0, 0, 1).Format(time.DateOnly)
	if input.Start != "" {
		if _, err := time.Parse(time.DateOnly, input.Start); err != nil {
			return nil, errors.New("start 需要 YYYY-MM-DD")
		}
		start = input.Start
	}
	if input.End != "" {
		if _, err := time.Parse(time.DateOnly, input.End); err != nil {
			return nil, errors.New("end 需要 YYYY-MM-DD")
		}
		end = input.End
	}
	inRange := rows[:0:0]
	for _, row := range rows {
		day := row.date.Format(time.DateOnly)
		if day >= start && day < end {
			inRange = append(inRange, row)
		}
	}
	rows = inRange
	// Postings just outside the range can still pair with rows inside it;
	// unpaired ones outside the range are not reported as extra.
	startDate, _ := time.Parse(time.DateOnly, start)
	endDate, _ := time.Parse(time.DateOnly, end)
	fetched, err := ledger.Postings(startDate.AddDate(0, 0, -tolerance).Format(time.DateOnly),
		endDate.AddDate(0, 0, tolerance).Format(time.DateOnly), input.Accounts)
	if err != nil {
		return nil, err
	}
	postings := make([]ledgerPosting, 0, len(fetched))
	for _, posting := range fetched {
		if input.Currency != "" && !strings.EqualFold(posting.Currency, input.Currency) {
			continue
		}
		date, err := time.Parse(time.DateOnly, posting.Date)
		if err != nil {
			continue
		}
		postings = append(postings, ledgerPosting{posting, date})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].date.Before(rows[j].date) })
	sort.SliceStable(postings, func(i, j int) bool { return postings[i].date.Before(postings[j].date) })
	matched, mismatched, missing, extra := match(rows, postings, tolerance)
	inside := func(posting ledgerPosting) bool { return posting.Date >= start && posting.Date < end }
	extra = slices.DeleteFunc(extra, func(posting ledgerPosting) bool { return !inside(posting) })

	statementTotal, ledgerTotal := 0, 0
	for _, row := range rows {
		statementTotal += row.cents
	}
	for _, posting := range postings {
		if inside(posting) {
			ledgerTotal += posting.Amount
		}
	}
	result := map[string]any{
		"amountUnit":    "major",
		"accounts":      input.Accounts,
		"range":         map[string]string{"start": start, "end": end},
		"toleranceDays": tolerance,
		"mapping":       mapping,
		"statement":     map[string]any{"rows": len(rows), "total": money(statementTotal), "skippedRows": len(skipped)},
		"ledger":        map[string]any{"postings": len(postings), "total": money(ledgerTotal)},
		"difference":    money(statementTotal - ledgerTotal),
		"matched":       len(matched),
		"counts":        map[string]int{"missingInLedger": len(missing), "extraInLedger": len(extra), "amountMismatch": len(mismatched)},
		"note":          "金额按账户余额变化计：转入为正、支出为负。difference = 账单合计 − 账本合计。",
	}
	if len(skipped) > 0 {
		result["skippedSamples"] = skipped[:min(len(skipped), 8)]
	}
	listedRow := func(row statementRow) map[string]any {
		return map[string]any{"row": row.row, "date": row.date.Format(time.DateOnly), "amount": money(row.cents), "description": clip(row.description, 60)}
	}
	listedPosting := func(posting ledgerPosting) map[string]any {
		return map[string]any{"date": posting.Date, "amount": money(posting.Amount), "currency": posting.Currency,
			"account": posting.Account, "payee": clip(posting.Payee, 40), "narration": clip(posting.Narration, 60),
			"source": fmt.Sprintf("%s:%d", posting.File, posting.Line)}
	}
	truncated := false
	var missingList, extraList, mismatchList []map[string]any
	for _, row := range missing {
		if len(missingList) == maxReconcileListed {
			truncated = true
			break
		}
		missingList = append(missingList, listedRow(row))
	}
	for _, posting := range extra {
		if len(extraList) == maxReconcileListed {
			truncated = true
			break
		}
		extraList = append(extraList, listedPosting(posting))
	}
	for _, pair := range mismatched {
		if len(mismatchList) == maxReconcileListed {
			truncated = true
			break
		}
		entry := listedRow(pair.statement)
		entry["ledger"] = listedPosting(pair.ledger)
		entry["delta"] = money(pair.statement.cents - pair.ledger.Amount)
		mismatchList = append(mismatchList, entry)
	}
	result["missingInLedger"] = orEmpty(missingList)
	result["extraInLedger"] = orEmpty(extraList)
	result["amountMismatches"] = orEmpty(mismatchList)
	if truncated {
		result["truncated"] = fmt.Sprintf("每类最多列出 %d 条；用 start/end 缩小日期范围查看其余的", maxReconcileListed)
	}
	// A statement read with the wrong sign matches almost nothing; say so
	// instead of reporting every row missing.
	if len(rows) >= 3 {
		flipped := make([]statementRow, len(rows))
		for index, row := range rows {
			flipped[index] = row
			flipped[index].cents = -row.cents
		}
		again, _, _, _ := match(flipped, postings, tolerance)
		if len(again) >= 3 && len(again) > 2*len(matched) {
			result["hint"] = fmt.Sprintf("金额方向可能反了：把账单金额取反能对上 %d 笔（现在 %d 笔）。换一个 amountSign 或检查方向列再试。", len(again), len(matched))
		}
	}
	return result, nil
}

func orEmpty(list []map[string]any) []map[string]any {
	if list == nil {
		return []map[string]any{}
	}
	return list
}

func describeSkipped(skipped []skippedRow) string {
	if len(skipped) == 0 {
		return "无"
	}
	var parts []string
	for _, row := range skipped[:min(len(skipped), 5)] {
		parts = append(parts, fmt.Sprintf("第 %d 行 %s", row.Row, row.Reason))
	}
	return strings.Join(parts, "；")
}
