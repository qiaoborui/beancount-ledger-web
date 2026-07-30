package app

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	bqlDefaultLimit = 100
	bqlMaxLimit     = 500
)

type BQLRequest struct {
	Query             string `json:"query"`
	ValuationCurrency string `json:"valuationCurrency,omitempty"`
}

type BQLColumn struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type BQLResult struct {
	Columns           []BQLColumn `json:"columns"`
	Rows              [][]any     `json:"rows"`
	Query             string      `json:"query"`
	Warnings          []string    `json:"warnings,omitempty"`
	ValuationCurrency string      `json:"valuationCurrency"`
	Limit             int         `json:"limit"`
	RowCount          int         `json:"rowCount"`
}

type bqlQuery struct {
	selects    []bqlSelect
	table      string
	conditions []bqlCondition
	groupBy    []string
	orderBy    []bqlOrder
	limit      int
}

type bqlSelect struct {
	raw       string
	alias     string
	field     string
	aggregate string
}

type bqlCondition struct {
	field string
	op    string
	value bqlLiteral
}

type bqlOrder struct {
	key  string
	desc bool
}

type bqlLiteral struct {
	raw    string
	number *float64
}

type bqlRow struct {
	values map[string]bqlValue
}

type bqlValue struct {
	value any
	typ   string
}

type bqlAggregate struct {
	count int
	sums  map[int]float64
}

var (
	bqlIdentifierRE = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)
	bqlFunctionRE   = regexp.MustCompile(`(?i)^([a-z_][a-z0-9_]*)\s*\(\s*([a-z_][a-z0-9_]*|\*)\s*\)$`)
)

func (s *LedgerReadService) BQL(ctx context.Context, rawQuery, rawValuationCurrency string) (BQLResult, error) {
	snapshot, err := s.SnapshotLite(ctx)
	if err != nil {
		return BQLResult{}, err
	}
	return ExecuteBQL(snapshot, rawQuery, rawValuationCurrency)
}

func ExecuteBQL(snapshot *LedgerSnapshot, rawQuery, rawValuationCurrency string) (BQLResult, error) {
	query, err := parseBQL(rawQuery)
	if err != nil {
		return BQLResult{}, err
	}
	valuationCurrency := ValidValuationCurrency(rawValuationCurrency, snapshot.Commodities)
	rows, err := bqlRows(snapshot, query.table, valuationCurrency)
	if err != nil {
		return BQLResult{}, err
	}
	filtered := rows[:0]
	for _, row := range rows {
		if bqlRowMatches(row, query.conditions) {
			filtered = append(filtered, row)
		}
	}
	columns := bqlColumns(query, filtered)
	resultRows := bqlResultRows(query, filtered)
	bqlSortRows(resultRows, columns, query.orderBy)
	warnings := []string{}
	if len(resultRows) > query.limit {
		warnings = append(warnings, fmt.Sprintf("结果已限制为前 %d 行", query.limit))
		resultRows = resultRows[:query.limit]
	}
	return BQLResult{
		Columns:           columns,
		Rows:              resultRows,
		Query:             strings.TrimSpace(rawQuery),
		Warnings:          warnings,
		ValuationCurrency: valuationCurrency,
		Limit:             query.limit,
		RowCount:          len(resultRows),
	}, nil
}

func parseBQL(raw string) (bqlQuery, error) {
	sql := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(raw), ";"))
	if sql == "" {
		return bqlQuery{}, errors.New("BQL 查询不能为空")
	}
	if !strings.EqualFold(firstSQLWord(sql), "SELECT") {
		return bqlQuery{}, errors.New("BQL 第一版只支持 SELECT 查询")
	}
	fromIndex := findBQLKeyword(sql, "FROM", len("SELECT"))
	if fromIndex < 0 {
		return bqlQuery{}, errors.New("缺少 FROM 子句")
	}
	selectPart := strings.TrimSpace(sql[len("SELECT"):fromIndex])
	rest := strings.TrimSpace(sql[fromIndex+len("FROM"):])
	tablePart, restClauses := cutBQLTable(rest)
	table := strings.ToLower(strings.TrimSpace(tablePart))
	if table != "postings" && table != "transactions" {
		return bqlQuery{}, fmt.Errorf("不支持的 BQL 表 %q", table)
	}
	parts := splitBQLClauses(restClauses)
	selects, err := parseBQLSelects(selectPart)
	if err != nil {
		return bqlQuery{}, err
	}
	conditions, err := parseBQLWhere(parts["WHERE"])
	if err != nil {
		return bqlQuery{}, err
	}
	groupBy, err := parseBQLFieldList(parts["GROUP BY"])
	if err != nil {
		return bqlQuery{}, err
	}
	orderBy, err := parseBQLOrder(parts["ORDER BY"])
	if err != nil {
		return bqlQuery{}, err
	}
	limit, err := parseBQLLimit(parts["LIMIT"])
	if err != nil {
		return bqlQuery{}, err
	}
	query := bqlQuery{selects: selects, table: table, conditions: conditions, groupBy: groupBy, orderBy: orderBy, limit: limit}
	if err := validateBQLQuery(query); err != nil {
		return bqlQuery{}, err
	}
	return query, nil
}

func firstSQLWord(sql string) string {
	fields := strings.Fields(sql)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

func cutBQLTable(rest string) (string, string) {
	next := len(rest)
	for _, keyword := range []string{"WHERE", "GROUP BY", "ORDER BY", "LIMIT"} {
		if index := findBQLKeyword(rest, keyword, 0); index >= 0 && index < next {
			next = index
		}
	}
	return strings.TrimSpace(rest[:next]), strings.TrimSpace(rest[next:])
}

func splitBQLClauses(raw string) map[string]string {
	clauses := map[string]string{}
	for len(strings.TrimSpace(raw)) > 0 {
		raw = strings.TrimSpace(raw)
		name := ""
		for _, keyword := range []string{"GROUP BY", "ORDER BY", "WHERE", "LIMIT"} {
			if hasBQLKeywordPrefix(raw, keyword) {
				name = keyword
				break
			}
		}
		if name == "" {
			break
		}
		bodyStart := len(name)
		next := len(raw)
		for _, keyword := range []string{"GROUP BY", "ORDER BY", "WHERE", "LIMIT"} {
			if keyword == name {
				continue
			}
			if index := findBQLKeyword(raw, keyword, bodyStart); index >= 0 && index < next {
				next = index
			}
		}
		clauses[name] = strings.TrimSpace(raw[bodyStart:next])
		raw = raw[next:]
	}
	return clauses
}

func findBQLKeyword(sql, keyword string, start int) int {
	upperSQL := strings.ToUpper(sql)
	upperKeyword := strings.ToUpper(keyword)
	quote := byte(0)
	depth := 0
	for i := max(0, start); i <= len(sql)-len(keyword); i++ {
		ch := sql[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
			}
			continue
		}
		if ch == '\'' || ch == '"' {
			quote = ch
			continue
		}
		if ch == '(' {
			depth++
			continue
		}
		if ch == ')' && depth > 0 {
			depth--
			continue
		}
		if depth != 0 || upperSQL[i:i+len(keyword)] != upperKeyword {
			continue
		}
		beforeOK := i == 0 || !isBQLIdentByte(sql[i-1])
		after := i + len(keyword)
		afterOK := after >= len(sql) || !isBQLIdentByte(sql[after])
		if beforeOK && afterOK {
			return i
		}
	}
	return -1
}

func hasBQLKeywordPrefix(sql, keyword string) bool {
	if len(sql) < len(keyword) || !strings.EqualFold(sql[:len(keyword)], keyword) {
		return false
	}
	return len(sql) == len(keyword) || !isBQLIdentByte(sql[len(keyword)])
}

func isBQLIdentByte(ch byte) bool {
	return ch == '_' || ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'
}

func splitBQLCSV(raw string) []string {
	parts := []string{}
	start := 0
	quote := byte(0)
	depth := 0
	for i := 0; i < len(raw); i++ {
		ch := raw[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
			}
			continue
		}
		switch ch {
		case '\'', '"':
			quote = ch
		case '(':
			depth++
		case ')':
			if depth > 0 {
				depth--
			}
		case ',':
			if depth == 0 {
				parts = append(parts, strings.TrimSpace(raw[start:i]))
				start = i + 1
			}
		}
	}
	parts = append(parts, strings.TrimSpace(raw[start:]))
	return parts
}

func parseBQLSelects(raw string) ([]bqlSelect, error) {
	items := splitBQLCSV(raw)
	selects := []bqlSelect{}
	for _, item := range items {
		if item == "" {
			continue
		}
		expr, alias := splitBQLAlias(item)
		selectExpr := bqlSelect{raw: strings.TrimSpace(expr)}
		if match := bqlFunctionRE.FindStringSubmatch(expr); match != nil {
			fn := strings.ToLower(match[1])
			field := strings.ToLower(match[2])
			if fn != "count" && fn != "sum" && fn != "avg" && fn != "min" && fn != "max" {
				return nil, fmt.Errorf("不支持的聚合函数 %q", fn)
			}
			if field == "*" && fn != "count" {
				return nil, fmt.Errorf("%s 不支持 *", fn)
			}
			selectExpr.aggregate = fn
			selectExpr.field = field
		} else {
			field := strings.ToLower(strings.TrimSpace(expr))
			if !bqlIdentifierRE.MatchString(field) {
				return nil, fmt.Errorf("不支持的 SELECT 表达式 %q", expr)
			}
			selectExpr.field = field
		}
		if alias == "" {
			alias = selectExpr.defaultName()
		}
		if !bqlIdentifierRE.MatchString(alias) {
			return nil, fmt.Errorf("不支持的列别名 %q", alias)
		}
		selectExpr.alias = alias
		selects = append(selects, selectExpr)
	}
	if len(selects) == 0 {
		return nil, errors.New("SELECT 列不能为空")
	}
	return selects, nil
}

func splitBQLAlias(raw string) (string, string) {
	if index := findBQLKeyword(raw, "AS", 0); index >= 0 {
		return strings.TrimSpace(raw[:index]), strings.ToLower(strings.TrimSpace(raw[index+len("AS"):]))
	}
	return strings.TrimSpace(raw), ""
}

func (s bqlSelect) defaultName() string {
	if s.aggregate == "" {
		return s.field
	}
	if s.field == "*" {
		return s.aggregate
	}
	return s.aggregate + "_" + s.field
}

func parseBQLFieldList(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	fields := []string{}
	for _, item := range splitBQLCSV(raw) {
		field := strings.ToLower(strings.TrimSpace(item))
		if !bqlIdentifierRE.MatchString(field) {
			return nil, fmt.Errorf("不支持的字段 %q", item)
		}
		fields = append(fields, field)
	}
	return fields, nil
}

func parseBQLWhere(raw string) ([]bqlCondition, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	if findBQLKeyword(raw, "OR", 0) >= 0 {
		return nil, errors.New("BQL 第一版 WHERE 只支持 AND，不支持 OR")
	}
	parts := splitBQLAnd(raw)
	conditions := []bqlCondition{}
	for _, part := range parts {
		condition, err := parseBQLCondition(part)
		if err != nil {
			return nil, err
		}
		conditions = append(conditions, condition)
	}
	return conditions, nil
}

func splitBQLAnd(raw string) []string {
	parts := []string{}
	start := 0
	for {
		index := findBQLKeyword(raw, "AND", start)
		if index < 0 {
			break
		}
		parts = append(parts, strings.TrimSpace(raw[start:index]))
		start = index + len("AND")
	}
	parts = append(parts, strings.TrimSpace(raw[start:]))
	return parts
}

func parseBQLCondition(raw string) (bqlCondition, error) {
	for _, op := range []string{">=", "<=", "!=", "=", ">", "<", "LIKE"} {
		index := findBQLOperator(raw, op)
		if index < 0 {
			continue
		}
		field := strings.ToLower(strings.TrimSpace(raw[:index]))
		if !bqlIdentifierRE.MatchString(field) {
			return bqlCondition{}, fmt.Errorf("不支持的 WHERE 字段 %q", field)
		}
		value, err := parseBQLLiteral(strings.TrimSpace(raw[index+len(op):]))
		if err != nil {
			return bqlCondition{}, err
		}
		return bqlCondition{field: field, op: strings.ToUpper(op), value: value}, nil
	}
	return bqlCondition{}, fmt.Errorf("无法解析 WHERE 条件 %q", raw)
}

func findBQLOperator(raw, op string) int {
	if op == "LIKE" {
		return findBQLKeyword(raw, "LIKE", 0)
	}
	quote := byte(0)
	for i := 0; i <= len(raw)-len(op); i++ {
		ch := raw[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
			}
			continue
		}
		if ch == '\'' || ch == '"' {
			quote = ch
			continue
		}
		if raw[i:i+len(op)] == op {
			return i
		}
	}
	return -1
}

func parseBQLLiteral(raw string) (bqlLiteral, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return bqlLiteral{}, errors.New("WHERE 条件值不能为空")
	}
	if len(raw) >= 2 && ((raw[0] == '\'' && raw[len(raw)-1] == '\'') || (raw[0] == '"' && raw[len(raw)-1] == '"')) {
		return bqlLiteral{raw: raw[1 : len(raw)-1]}, nil
	}
	number, err := strconv.ParseFloat(strings.TrimPrefix(strings.ReplaceAll(raw, ",", ""), "¥"), 64)
	if err == nil {
		return bqlLiteral{raw: raw, number: &number}, nil
	}
	return bqlLiteral{raw: raw}, nil
}

func parseBQLOrder(raw string) ([]bqlOrder, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	orders := []bqlOrder{}
	for _, item := range splitBQLCSV(raw) {
		fields := strings.Fields(item)
		if len(fields) == 0 {
			continue
		}
		key := strings.ToLower(fields[0])
		if !bqlIdentifierRE.MatchString(key) {
			return nil, fmt.Errorf("不支持的 ORDER BY 字段 %q", fields[0])
		}
		desc := false
		if len(fields) > 1 {
			if strings.EqualFold(fields[1], "DESC") {
				desc = true
			} else if !strings.EqualFold(fields[1], "ASC") {
				return nil, fmt.Errorf("不支持的排序方向 %q", fields[1])
			}
		}
		orders = append(orders, bqlOrder{key: key, desc: desc})
	}
	return orders, nil
}

func parseBQLLimit(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return bqlDefaultLimit, nil
	}
	limit, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || limit <= 0 {
		return 0, errors.New("LIMIT 必须是正整数")
	}
	if limit > bqlMaxLimit {
		return bqlMaxLimit, nil
	}
	return limit, nil
}

func validateBQLQuery(query bqlQuery) error {
	fields := bqlSupportedFields(query.table)
	aggregate := bqlQueryAggregates(query)
	groupSet := map[string]bool{}
	for _, field := range query.groupBy {
		if !fields[field] {
			return fmt.Errorf("%s 不支持 GROUP BY 字段 %q", query.table, field)
		}
		groupSet[field] = true
	}
	selectAliases := map[string]bool{}
	for _, item := range query.selects {
		selectAliases[item.alias] = true
		if item.field != "*" && !fields[item.field] {
			return fmt.Errorf("%s 不支持 SELECT 字段 %q", query.table, item.field)
		}
		if item.aggregate != "" {
			if item.aggregate != "count" && item.field != "*" && !bqlNumericFields()[item.field] {
				return fmt.Errorf("%s 不支持对字段 %q 做 %s 聚合", query.table, item.field, item.aggregate)
			}
			continue
		}
		if (len(query.groupBy) > 0 || aggregate) && !groupSet[item.field] {
			return fmt.Errorf("非聚合列 %q 必须出现在 GROUP BY 中", item.field)
		}
	}
	if len(query.groupBy) > 0 && !aggregate {
		return errors.New("GROUP BY 需要至少一个聚合列")
	}
	for _, condition := range query.conditions {
		if !fields[condition.field] {
			return fmt.Errorf("%s 不支持 WHERE 字段 %q", query.table, condition.field)
		}
	}
	for _, order := range query.orderBy {
		if !selectAliases[order.key] {
			return fmt.Errorf("ORDER BY 字段 %q 必须是 SELECT 结果列", order.key)
		}
	}
	return nil
}

func bqlNumericFields() map[string]bool {
	return map[string]bool{
		"amount":        true,
		"value":         true,
		"line":          true,
		"txn_index":     true,
		"posting_index": true,
	}
}

func bqlSupportedFields(table string) map[string]bool {
	common := map[string]bool{
		"date":      true,
		"month":     true,
		"year":      true,
		"payee":     true,
		"narration": true,
		"amount":    true,
		"value":     true,
		"type":      true,
		"tags":      true,
		"links":     true,
		"source":    true,
		"line":      true,
		"txn_index": true,
	}
	if table == "transactions" {
		common["accounts"] = true
		return common
	}
	common["account"] = true
	common["account_root"] = true
	common["currency"] = true
	common["posting_index"] = true
	return common
}

func bqlRows(snapshot *LedgerSnapshot, table, valuationCurrency string) ([]bqlRow, error) {
	priceIndex := snapshotPriceIndex(snapshot)
	rows := []bqlRow{}
	for txnIndex, txn := range snapshot.Transactions {
		if table == "transactions" {
			rows = append(rows, bqlTransactionRow(txn, txnIndex, priceIndex, valuationCurrency))
			continue
		}
		for postingIndex, posting := range txn.Postings {
			rows = append(rows, bqlPostingRow(txn, posting, txnIndex, postingIndex, priceIndex, valuationCurrency))
		}
	}
	return rows, nil
}

func bqlPostingRow(txn Transaction, posting Posting, txnIndex, postingIndex int, priceIndex PriceIndex, valuationCurrency string) bqlRow {
	value := postingValuationWithPriceIndex(posting, priceIndex, txn.Date, valuationCurrency)
	return bqlRow{values: map[string]bqlValue{
		"date":          {value: txn.Date, typ: "date"},
		"month":         {value: txn.Date[:7], typ: "month"},
		"year":          {value: txn.Date[:4], typ: "string"},
		"payee":         {value: txn.Payee, typ: "string"},
		"narration":     {value: txn.Narration, typ: "string"},
		"account":       {value: posting.Account, typ: "string"},
		"account_root":  {value: accountRoot(posting.Account), typ: "string"},
		"amount":        {value: posting.Amount, typ: "money"},
		"value":         {value: value, typ: "money"},
		"currency":      {value: posting.Currency, typ: "string"},
		"type":          {value: dashboardTransactionType(txn), typ: "string"},
		"tags":          {value: strings.Join(txn.Tags, " "), typ: "string"},
		"links":         {value: strings.Join(txn.Links, " "), typ: "string"},
		"source":        {value: txn.Source.File, typ: "string"},
		"line":          {value: txn.Source.Line, typ: "number"},
		"txn_index":     {value: txnIndex, typ: "number"},
		"posting_index": {value: postingIndex, typ: "number"},
	}}
}

func bqlTransactionRow(txn Transaction, txnIndex int, priceIndex PriceIndex, valuationCurrency string) bqlRow {
	accounts := make([]string, 0, len(txn.Postings))
	value := 0
	for _, posting := range txn.Postings {
		accounts = append(accounts, posting.Account)
		if strings.HasPrefix(posting.Account, "Income:") || strings.HasPrefix(posting.Account, "Expenses:") {
			value += abs(postingValuationWithPriceIndex(posting, priceIndex, txn.Date, valuationCurrency))
		}
	}
	return bqlRow{values: map[string]bqlValue{
		"date":      {value: txn.Date, typ: "date"},
		"month":     {value: txn.Date[:7], typ: "month"},
		"year":      {value: txn.Date[:4], typ: "string"},
		"payee":     {value: txn.Payee, typ: "string"},
		"narration": {value: txn.Narration, typ: "string"},
		"accounts":  {value: strings.Join(accounts, " "), typ: "string"},
		"amount":    {value: transactionQueryAmount(txn), typ: "money"},
		"value":     {value: value, typ: "money"},
		"type":      {value: dashboardTransactionType(txn), typ: "string"},
		"tags":      {value: strings.Join(txn.Tags, " "), typ: "string"},
		"links":     {value: strings.Join(txn.Links, " "), typ: "string"},
		"source":    {value: txn.Source.File, typ: "string"},
		"line":      {value: txn.Source.Line, typ: "number"},
		"txn_index": {value: txnIndex, typ: "number"},
	}}
}

func accountRoot(account string) string {
	root, _, ok := strings.Cut(account, ":")
	if !ok {
		return account
	}
	return root
}

func bqlRowMatches(row bqlRow, conditions []bqlCondition) bool {
	for _, condition := range conditions {
		value, ok := row.values[condition.field]
		if !ok || !bqlCompare(value, condition.op, condition.value) {
			return false
		}
	}
	return true
}

func bqlCompare(left bqlValue, op string, right bqlLiteral) bool {
	if left.typ == "money" || left.typ == "number" {
		leftNumber, ok := anyToFloat(left.value)
		if !ok {
			return false
		}
		rightNumber := 0.0
		if right.number != nil {
			rightNumber = *right.number
			if left.typ == "money" {
				rightNumber *= 100
			}
		} else {
			parsed, err := strconv.ParseFloat(right.raw, 64)
			if err != nil {
				return false
			}
			rightNumber = parsed
		}
		return compareFloat(leftNumber, op, rightNumber)
	}
	leftText := fmt.Sprint(left.value)
	rightText := right.raw
	switch op {
	case "=":
		return strings.EqualFold(leftText, rightText)
	case "!=":
		return !strings.EqualFold(leftText, rightText)
	case ">":
		return leftText > rightText
	case ">=":
		return leftText >= rightText
	case "<":
		return leftText < rightText
	case "<=":
		return leftText <= rightText
	case "LIKE":
		return bqlLike(leftText, rightText)
	default:
		return false
	}
}

func anyToFloat(value any) (float64, bool) {
	switch v := value.(type) {
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case float64:
		return v, true
	default:
		return 0, false
	}
}

func compareFloat(left float64, op string, right float64) bool {
	switch op {
	case "=":
		return left == right
	case "!=":
		return left != right
	case ">":
		return left > right
	case ">=":
		return left >= right
	case "<":
		return left < right
	case "<=":
		return left <= right
	default:
		return false
	}
}

func bqlLike(text, pattern string) bool {
	if pattern == "%" {
		return true
	}
	parts := strings.Split(strings.ToLower(pattern), "%")
	cursor := 0
	lowerText := strings.ToLower(text)
	for index, part := range parts {
		if part == "" {
			continue
		}
		found := strings.Index(lowerText[cursor:], part)
		if found < 0 {
			return false
		}
		if index == 0 && !strings.HasPrefix(pattern, "%") && found != 0 {
			return false
		}
		cursor += found + len(part)
	}
	if !strings.HasSuffix(pattern, "%") && len(parts) > 0 {
		return strings.HasSuffix(lowerText, parts[len(parts)-1])
	}
	return true
}

func bqlColumns(query bqlQuery, rows []bqlRow) []BQLColumn {
	columns := make([]BQLColumn, 0, len(query.selects))
	for _, item := range query.selects {
		typ := "string"
		if item.aggregate != "" {
			switch item.aggregate {
			case "count":
				typ = "number"
			default:
				typ = bqlFieldType(rows, item.field)
			}
		} else {
			typ = bqlFieldType(rows, item.field)
		}
		columns = append(columns, BQLColumn{Name: item.alias, Type: typ})
	}
	return columns
}

func bqlFieldType(rows []bqlRow, field string) string {
	for _, row := range rows {
		if value, ok := row.values[field]; ok {
			return value.typ
		}
	}
	if field == "amount" || field == "value" {
		return "money"
	}
	if field == "line" || field == "txn_index" || field == "posting_index" {
		return "number"
	}
	return "string"
}

func bqlResultRows(query bqlQuery, rows []bqlRow) [][]any {
	if bqlQueryAggregates(query) || len(query.groupBy) > 0 {
		return bqlGroupedRows(query, rows)
	}
	out := make([][]any, 0, len(rows))
	for _, sourceRow := range rows {
		row := make([]any, 0, len(query.selects))
		for _, item := range query.selects {
			row = append(row, sourceRow.values[item.field].value)
		}
		out = append(out, row)
	}
	return out
}

func bqlQueryAggregates(query bqlQuery) bool {
	for _, item := range query.selects {
		if item.aggregate != "" {
			return true
		}
	}
	return false
}

func bqlGroupedRows(query bqlQuery, rows []bqlRow) [][]any {
	type group struct {
		values map[string]any
		agg    bqlAggregate
	}
	groups := map[string]*group{}
	for _, row := range rows {
		keyParts := make([]string, 0, len(query.groupBy))
		values := map[string]any{}
		for _, field := range query.groupBy {
			value := row.values[field].value
			values[field] = value
			keyParts = append(keyParts, fmt.Sprint(value))
		}
		key := strings.Join(keyParts, "\x00")
		if key == "" && len(query.groupBy) == 0 {
			key = "__all__"
		}
		current := groups[key]
		if current == nil {
			current = &group{values: values, agg: bqlAggregate{sums: map[int]float64{}}}
			groups[key] = current
		}
		current.agg.count++
		for index, item := range query.selects {
			if item.aggregate == "" || item.aggregate == "count" {
				continue
			}
			if number, ok := anyToFloat(row.values[item.field].value); ok {
				current.agg.sums[index] += number
			}
		}
	}
	out := [][]any{}
	for _, group := range groups {
		row := make([]any, 0, len(query.selects))
		for index, item := range query.selects {
			if item.aggregate == "" {
				row = append(row, group.values[item.field])
				continue
			}
			switch item.aggregate {
			case "count":
				row = append(row, group.agg.count)
			case "sum":
				row = append(row, int(math.Round(group.agg.sums[index])))
			case "avg":
				if group.agg.count == 0 {
					row = append(row, 0)
				} else {
					row = append(row, int(math.Round(group.agg.sums[index]/float64(group.agg.count))))
				}
			case "min", "max":
				row = append(row, bqlMinMax(rows, query.groupBy, group.values, item.field, item.aggregate))
			}
		}
		out = append(out, row)
	}
	return out
}

func bqlMinMax(rows []bqlRow, groupBy []string, groupValues map[string]any, field, op string) any {
	var selected any
	var selectedNumber float64
	hasSelected := false
	for _, row := range rows {
		matches := true
		for _, groupField := range groupBy {
			if fmt.Sprint(row.values[groupField].value) != fmt.Sprint(groupValues[groupField]) {
				matches = false
				break
			}
		}
		if !matches {
			continue
		}
		number, ok := anyToFloat(row.values[field].value)
		if !ok {
			continue
		}
		if !hasSelected || op == "min" && number < selectedNumber || op == "max" && number > selectedNumber {
			selected = row.values[field].value
			selectedNumber = number
			hasSelected = true
		}
	}
	if !hasSelected {
		return 0
	}
	return selected
}

func bqlSortRows(rows [][]any, columns []BQLColumn, orders []bqlOrder) {
	if len(orders) == 0 {
		return
	}
	indexByName := map[string]int{}
	for index, column := range columns {
		indexByName[strings.ToLower(column.Name)] = index
	}
	sort.SliceStable(rows, func(i, j int) bool {
		for _, order := range orders {
			index, ok := indexByName[order.key]
			if !ok {
				continue
			}
			cmp := compareBQLAny(rows[i][index], rows[j][index])
			if cmp == 0 {
				continue
			}
			if order.desc {
				return cmp > 0
			}
			return cmp < 0
		}
		return false
	})
}

func compareBQLAny(left, right any) int {
	leftNumber, leftOK := anyToFloat(left)
	rightNumber, rightOK := anyToFloat(right)
	if leftOK && rightOK {
		if leftNumber < rightNumber {
			return -1
		}
		if leftNumber > rightNumber {
			return 1
		}
		return 0
	}
	leftText := fmt.Sprint(left)
	rightText := fmt.Sprint(right)
	if leftText < rightText {
		return -1
	}
	if leftText > rightText {
		return 1
	}
	return 0
}
