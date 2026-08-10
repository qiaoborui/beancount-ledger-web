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
	bqlDialectVersion       = 2
	bqlDefaultLimit         = 100
	bqlMaxLimit             = 500
	bqlMaxQueryLength       = 12000
	bqlMaxExpressionTokens  = 512
	bqlMaxExpressionDepth   = 64
	bqlMaxInValues          = 100
	bqlMaxRequestBodyLength = 16 << 10

	bqlOpEqual       = "="
	bqlOpNotEqual    = "!="
	bqlOpGreater     = ">"
	bqlOpGreaterEq   = ">="
	bqlOpLess        = "<"
	bqlOpLessEq      = "<="
	bqlOpLike        = "LIKE"
	bqlOpNotLike     = "NOT LIKE"
	bqlOpMatch       = "~"
	bqlOpNotMatch    = "!~"
	bqlOpIn          = "IN"
	bqlOpNotIn       = "NOT IN"
	bqlOpBetween     = "BETWEEN"
	bqlOpNotBetween  = "NOT BETWEEN"
	bqlOpIsNull      = "IS NULL"
	bqlOpIsNotNull   = "IS NOT NULL"
	bqlOpContains    = "CONTAINS"
	bqlOpNotContains = "NOT CONTAINS"
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
	selects  []bqlSelect
	table    string
	where    *bqlExpression
	groupBy  []string
	having   *bqlExpression
	orderBy  []bqlOrder
	distinct bool
	limit    int
}

type bqlSelect struct {
	raw       string
	alias     string
	field     string
	aggregate string
}

type bqlCondition struct {
	field   string
	op      string
	values  []bqlLiteral
	pattern *regexp.Regexp
}

type bqlValidationIssue struct {
	Code     string   `json:"code"`
	Clause   string   `json:"clause,omitempty"`
	Position int      `json:"position,omitempty"`
	Message  string   `json:"message"`
	Expected []string `json:"expected,omitempty"`
}

type bqlValidationError struct {
	issue bqlValidationIssue
}

func (e *bqlValidationError) Error() string {
	if e.issue.Clause == "" {
		return e.issue.Message
	}
	return e.issue.Clause + ": " + e.issue.Message
}

type bqlExpression struct {
	op        string
	left      *bqlExpression
	right     *bqlExpression
	condition *bqlCondition
}

type bqlOrder struct {
	key   string
	index int
	desc  bool
}

type bqlLiteral struct {
	raw    string
	number *float64
	null   bool
}

type bqlRow struct {
	values map[string]bqlValue
}

type bqlProjectedRow struct {
	cells []any
	row   bqlRow
}

type bqlValue struct {
	value any
	typ   string
	items []string
}

type bqlFieldDefinition struct {
	name       string
	typ        string
	numeric    bool
	collection bool
}

type bqlOperatorDefinition struct {
	name        string
	direct      bool
	patternKind string
	collection  bool
	advertise   bool
}

type bqlAggregate struct {
	count int
	sums  map[int]float64
}

var (
	bqlIdentifierRE = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)
	bqlFunctionRE   = regexp.MustCompile(`(?i)^([a-z_][a-z0-9_]*)\s*\(\s*([a-z_][a-z0-9_]*|\*)\s*\)$`)
	bqlOperators    = []bqlOperatorDefinition{
		{name: bqlOpEqual, direct: true, advertise: true}, {name: bqlOpNotEqual, direct: true, advertise: true},
		{name: bqlOpGreater, direct: true, advertise: true}, {name: bqlOpGreaterEq, direct: true, advertise: true},
		{name: bqlOpLess, direct: true, advertise: true}, {name: bqlOpLessEq, direct: true, advertise: true},
		{name: bqlOpLike, patternKind: "like", advertise: true}, {name: bqlOpNotLike, patternKind: "like", advertise: true},
		{name: bqlOpMatch, direct: true, patternKind: "regex", advertise: true}, {name: bqlOpNotMatch, direct: true, patternKind: "regex", advertise: true},
		{name: bqlOpIn, advertise: true}, {name: bqlOpNotIn, advertise: true},
		{name: bqlOpBetween, advertise: true}, {name: bqlOpNotBetween, advertise: true},
		{name: bqlOpIsNull, advertise: true}, {name: bqlOpIsNotNull, advertise: true},
		{name: bqlOpContains, collection: true}, {name: bqlOpNotContains, collection: true},
	}
)

func bqlOperator(name string) (bqlOperatorDefinition, bool) {
	for _, operator := range bqlOperators {
		if operator.name == name {
			return operator, true
		}
	}
	return bqlOperatorDefinition{}, false
}

func bqlDirectOperator(name string) bool {
	operator, ok := bqlOperator(name)
	return ok && operator.direct
}

func bqlOperatorCapabilities() []string {
	operators := []string{"AND", "OR", "NOT", "parentheses"}
	for _, operator := range bqlOperators {
		if operator.advertise {
			operators = append(operators, operator.name)
		}
	}
	return operators
}

func bqlConditionOperatorNames() []string {
	return []string{
		bqlOpEqual, bqlOpNotEqual, bqlOpGreater, bqlOpGreaterEq, bqlOpLess, bqlOpLessEq,
		bqlOpLike, bqlOpMatch, bqlOpNotMatch, bqlOpIn, bqlOpBetween, "IS", "NOT",
	}
}

func newBQLValidationError(code, clause string, position int, message string, expected ...string) error {
	return &bqlValidationError{issue: bqlValidationIssue{
		Code: code, Clause: clause, Position: position, Message: message, Expected: expected,
	}}
}

func bqlValidationIssueFromError(err error) bqlValidationIssue {
	var validationErr *bqlValidationError
	if errors.As(err, &validationErr) {
		return validationErr.issue
	}

	message := err.Error()
	issue := bqlValidationIssue{Code: "invalid_query", Message: message}
	for _, clause := range []string{"WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "SELECT", "FROM"} {
		if strings.HasPrefix(message, clause+": ") {
			issue.Clause = clause
			issue.Message = strings.TrimPrefix(message, clause+": ")
			break
		}
		if strings.Contains(message, clause) {
			issue.Clause = clause
			break
		}
	}

	switch {
	case strings.Contains(message, "长度不能超过"):
		issue.Code = "query_too_long"
	case strings.Contains(message, "查询不能为空"):
		issue.Code = "empty_query"
	case strings.Contains(message, "只支持只读 SELECT"):
		issue.Code = "unsupported_statement"
		issue.Clause = "SELECT"
		issue.Expected = []string{"SELECT"}
	case strings.Contains(message, "缺少 FROM"):
		issue.Code = "missing_from"
		issue.Clause = "FROM"
		issue.Expected = []string{"FROM postings", "FROM transactions"}
	case strings.Contains(message, "不支持的 BQL 表"):
		issue.Code = "unsupported_table"
		issue.Clause = "FROM"
		issue.Expected = []string{"postings", "transactions"}
	case strings.Contains(message, "正则表达式无效"):
		issue.Code = "invalid_regex"
	case strings.Contains(message, "不支持") && strings.Contains(message, "字段"):
		issue.Code = "unsupported_field"
	case strings.Contains(message, "LIMIT 必须"):
		issue.Code = "invalid_limit"
		issue.Clause = "LIMIT"
	}
	return issue
}

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
		if bqlRowMatches(row, query.where) {
			filtered = append(filtered, row)
		}
	}
	columns := bqlColumns(query, filtered)
	resultRows := bqlResultRows(query, filtered)
	resultRows = bqlFilterResultRows(resultRows, query.having)
	if query.distinct {
		resultRows = bqlDistinctRows(resultRows)
	}
	bqlSortRows(resultRows, query.selects, query.orderBy)
	warnings := []string{}
	if len(resultRows) > query.limit {
		warnings = append(warnings, fmt.Sprintf("结果已限制为前 %d 行", query.limit))
		resultRows = resultRows[:query.limit]
	}
	return BQLResult{
		Columns:           columns,
		Rows:              bqlResultCells(resultRows),
		Query:             strings.TrimSpace(rawQuery),
		Warnings:          warnings,
		ValuationCurrency: valuationCurrency,
		Limit:             query.limit,
		RowCount:          len(resultRows),
	}, nil
}

func parseBQL(raw string) (bqlQuery, error) {
	if len(raw) > bqlMaxQueryLength {
		return bqlQuery{}, fmt.Errorf("BQL 查询长度不能超过 %d 字节", bqlMaxQueryLength)
	}
	sql := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(raw), ";"))
	if sql == "" {
		return bqlQuery{}, errors.New("BQL 查询不能为空")
	}
	if !strings.EqualFold(firstSQLWord(sql), "SELECT") {
		return bqlQuery{}, errors.New("BQL 只支持只读 SELECT 查询")
	}
	fromIndex := findBQLKeyword(sql, "FROM", len("SELECT"))
	if fromIndex < 0 {
		return bqlQuery{}, errors.New("缺少 FROM 子句")
	}
	selectPart := strings.TrimSpace(sql[len("SELECT"):fromIndex])
	distinct := false
	if hasBQLKeywordPrefix(selectPart, "DISTINCT") {
		distinct = true
		selectPart = strings.TrimSpace(selectPart[len("DISTINCT"):])
	}
	rest := strings.TrimSpace(sql[fromIndex+len("FROM"):])
	tablePart, restClauses := cutBQLTable(rest)
	table := strings.ToLower(strings.TrimSpace(tablePart))
	if table != "postings" && table != "transactions" {
		return bqlQuery{}, fmt.Errorf("不支持的 BQL 表 %q", table)
	}
	parts, err := splitBQLClauses(restClauses)
	if err != nil {
		return bqlQuery{}, err
	}
	selects, err := parseBQLSelects(selectPart)
	if err != nil {
		return bqlQuery{}, err
	}
	selects, err = expandBQLWildcards(table, selects)
	if err != nil {
		return bqlQuery{}, err
	}
	where, err := parseBQLExpression(parts["WHERE"], "WHERE")
	if err != nil {
		return bqlQuery{}, err
	}
	groupBy, err := parseBQLFieldList(parts["GROUP BY"])
	if err != nil {
		return bqlQuery{}, err
	}
	groupBy, err = normalizeBQLGroupBy(groupBy, selects)
	if err != nil {
		return bqlQuery{}, err
	}
	orderBy, err := parseBQLOrder(parts["ORDER BY"])
	if err != nil {
		return bqlQuery{}, err
	}
	having, err := parseBQLExpression(parts["HAVING"], "HAVING")
	if err != nil {
		return bqlQuery{}, err
	}
	limit, err := parseBQLLimit(parts["LIMIT"])
	if err != nil {
		return bqlQuery{}, err
	}
	query := bqlQuery{selects: selects, table: table, where: where, groupBy: groupBy, having: having, orderBy: orderBy, distinct: distinct, limit: limit}
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
	for _, keyword := range bqlClauseKeywords() {
		if index := findBQLKeyword(rest, keyword, 0); index >= 0 && index < next {
			next = index
		}
	}
	return strings.TrimSpace(rest[:next]), strings.TrimSpace(rest[next:])
}

func bqlClauseKeywords() []string {
	return []string{"WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT"}
}

func splitBQLClauses(raw string) (map[string]string, error) {
	clauses := map[string]string{}
	lastOrder := -1
	for len(strings.TrimSpace(raw)) > 0 {
		raw = strings.TrimSpace(raw)
		name := ""
		order := -1
		for index, keyword := range bqlClauseKeywords() {
			if hasBQLKeywordPrefix(raw, keyword) {
				name = keyword
				order = index
				break
			}
		}
		if name == "" {
			return nil, fmt.Errorf("无法解析 BQL 子句 %q", bqlErrorExcerpt(raw))
		}
		if _, exists := clauses[name]; exists {
			return nil, fmt.Errorf("%s 子句不能重复", name)
		}
		if order < lastOrder {
			return nil, fmt.Errorf("%s 子句顺序不正确", name)
		}
		lastOrder = order
		bodyStart := len(name)
		next := len(raw)
		for _, keyword := range bqlClauseKeywords() {
			if index := findBQLKeyword(raw, keyword, bodyStart); index >= 0 && index < next {
				next = index
			}
		}
		body := strings.TrimSpace(raw[bodyStart:next])
		if body == "" {
			return nil, fmt.Errorf("%s 子句不能为空", name)
		}
		clauses[name] = body
		raw = raw[next:]
	}
	return clauses, nil
}

func bqlErrorExcerpt(raw string) string {
	const maxLength = 40
	raw = strings.TrimSpace(raw)
	if len(raw) <= maxLength {
		return raw
	}
	return raw[:maxLength] + "…"
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
				if i+1 < len(sql) && sql[i+1] == quote {
					i++
					continue
				}
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
		if strings.TrimSpace(expr) == "*" {
			if alias != "" {
				return nil, errors.New("SELECT * 不支持列别名")
			}
			selectExpr.field = "*"
		} else if match := bqlFunctionRE.FindStringSubmatch(expr); match != nil {
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
		if alias == "" && selectExpr.field != "*" {
			alias = selectExpr.defaultName()
		}
		if selectExpr.field != "*" && !bqlIdentifierRE.MatchString(alias) {
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

func expandBQLWildcards(table string, selects []bqlSelect) ([]bqlSelect, error) {
	expanded := make([]bqlSelect, 0, len(selects))
	for _, item := range selects {
		if item.field != "*" || item.aggregate != "" {
			expanded = append(expanded, item)
			continue
		}
		for _, field := range bqlFieldOrder(table) {
			expanded = append(expanded, bqlSelect{raw: field, alias: field, field: field})
		}
	}
	aliases := map[string]bool{}
	for _, item := range expanded {
		if aliases[item.alias] {
			return nil, fmt.Errorf("SELECT 结果列 %q 重复", item.alias)
		}
		aliases[item.alias] = true
	}
	return expanded, nil
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
		if ordinal, err := strconv.Atoi(field); err == nil {
			if ordinal <= 0 {
				return nil, errors.New("GROUP BY 列序号必须是正整数")
			}
		} else if !bqlIdentifierRE.MatchString(field) {
			return nil, fmt.Errorf("不支持的字段 %q", item)
		}
		fields = append(fields, field)
	}
	return fields, nil
}

func normalizeBQLGroupBy(groupBy []string, selects []bqlSelect) ([]string, error) {
	normalized := make([]string, 0, len(groupBy))
	for _, key := range groupBy {
		selectedIndex := -1
		if ordinal, err := strconv.Atoi(key); err == nil {
			selectedIndex = ordinal - 1
			if selectedIndex < 0 || selectedIndex >= len(selects) {
				return nil, fmt.Errorf("GROUP BY 列序号 %d 超出 SELECT 列范围", ordinal)
			}
		} else {
			for index, item := range selects {
				if item.alias == key {
					selectedIndex = index
					break
				}
			}
			if selectedIndex < 0 {
				normalized = append(normalized, key)
				continue
			}
		}
		item := selects[selectedIndex]
		if item.aggregate != "" {
			return nil, fmt.Errorf("GROUP BY 不能引用聚合列 %q", key)
		}
		normalized = append(normalized, item.field)
	}
	return normalized, nil
}

type bqlToken struct {
	kind     string
	text     string
	quoted   bool
	position int
}

type bqlExpressionParser struct {
	clause string
	tokens []bqlToken
	index  int
}

func parseBQLExpression(raw, clause string) (*bqlExpression, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	tokens, err := tokenizeBQLExpression(raw, clause)
	if err != nil {
		return nil, err
	}
	parser := bqlExpressionParser{clause: clause, tokens: tokens}
	expression, err := parser.parseOr()
	if err != nil {
		return nil, err
	}
	if parser.peek().kind != "eof" {
		return nil, parser.errorf("无法解析 %q", parser.peek().text)
	}
	return expression, nil
}

func tokenizeBQLExpression(raw, clause string) ([]bqlToken, error) {
	tokens := []bqlToken{}
	depth := 0
	for index := 0; index < len(raw); {
		ch := raw[index]
		if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
			index++
			continue
		}
		switch ch {
		case '(':
			depth++
			if depth > bqlMaxExpressionDepth {
				return nil, newBQLValidationError("expression_too_complex", clause, index+1, fmt.Sprintf("表达式括号嵌套不能超过 %d 层", bqlMaxExpressionDepth))
			}
			tokens = append(tokens, bqlToken{kind: string(ch), text: string(ch), position: index + 1})
			index++
			continue
		case ')':
			if depth > 0 {
				depth--
			}
			tokens = append(tokens, bqlToken{kind: string(ch), text: string(ch), position: index + 1})
			index++
			continue
		case ',':
			tokens = append(tokens, bqlToken{kind: string(ch), text: string(ch), position: index + 1})
			index++
			continue
		case '\'', '"':
			start := index
			quote := ch
			index++
			var value strings.Builder
			closed := false
			for index < len(raw) {
				if raw[index] == quote {
					if index+1 < len(raw) && raw[index+1] == quote {
						value.WriteByte(quote)
						index += 2
						continue
					}
					index++
					closed = true
					break
				}
				value.WriteByte(raw[index])
				index++
			}
			if !closed {
				return nil, newBQLValidationError("unterminated_string", clause, start+1, "字符串缺少结束引号", string(quote))
			}
			tokens = append(tokens, bqlToken{kind: "value", text: value.String(), quoted: true, position: start + 1})
			continue
		}
		if strings.ContainsRune("=<>!~", rune(ch)) {
			length := 1
			if index+1 < len(raw) {
				candidate := raw[index : index+2]
				if candidate == ">=" || candidate == "<=" || candidate == "!=" || candidate == "!~" {
					length = 2
				}
			}
			tokens = append(tokens, bqlToken{kind: "operator", text: raw[index : index+length], position: index + 1})
			index += length
			continue
		}
		start := index
		for index < len(raw) {
			current := raw[index]
			if current == ',' && isBQLNumericComma(raw, index, start) {
				index++
				continue
			}
			if current == ' ' || current == '\t' || current == '\r' || current == '\n' || strings.ContainsRune("(),=<>!~", rune(current)) {
				break
			}
			index++
		}
		if start == index {
			return nil, newBQLValidationError("invalid_character", clause, index+1, fmt.Sprintf("无法识别字符 %q", ch))
		}
		tokens = append(tokens, bqlToken{kind: "value", text: raw[start:index], position: start + 1})
		if len(tokens) > bqlMaxExpressionTokens {
			return nil, newBQLValidationError("expression_too_complex", clause, start+1, fmt.Sprintf("表达式不能超过 %d 个词法单元", bqlMaxExpressionTokens))
		}
	}
	tokens = append(tokens, bqlToken{kind: "eof", position: len(raw) + 1})
	return tokens, nil
}

func isBQLNumericComma(raw string, index, tokenStart int) bool {
	if index <= tokenStart || index+3 >= len(raw) || raw[index] != ',' || raw[index-1] < '0' || raw[index-1] > '9' {
		return false
	}
	for offset := 1; offset <= 3; offset++ {
		if raw[index+offset] < '0' || raw[index+offset] > '9' {
			return false
		}
	}
	after := index + 4
	return after >= len(raw) || raw[after] == ',' || raw[after] == '.' || raw[after] == ' ' || raw[after] == '\t' || raw[after] == '\r' || raw[after] == '\n' || strings.ContainsRune(")=<>!~", rune(raw[after]))
}

func (p *bqlExpressionParser) parseOr() (*bqlExpression, error) {
	left, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for p.matchKeyword("OR") {
		right, err := p.parseAnd()
		if err != nil {
			return nil, err
		}
		left = &bqlExpression{op: "OR", left: left, right: right}
	}
	return left, nil
}

func (p *bqlExpressionParser) parseAnd() (*bqlExpression, error) {
	left, err := p.parseNot()
	if err != nil {
		return nil, err
	}
	for p.matchKeyword("AND") {
		right, err := p.parseNot()
		if err != nil {
			return nil, err
		}
		left = &bqlExpression{op: "AND", left: left, right: right}
	}
	return left, nil
}

func (p *bqlExpressionParser) parseNot() (*bqlExpression, error) {
	if p.matchKeyword("NOT") {
		operand, err := p.parseNot()
		if err != nil {
			return nil, err
		}
		return &bqlExpression{op: "NOT", left: operand}, nil
	}
	return p.parsePrimary()
}

func (p *bqlExpressionParser) parsePrimary() (*bqlExpression, error) {
	if p.matchKind("(") {
		expression, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		if !p.matchKind(")") {
			return nil, p.issue("expected_right_parenthesis", []string{")"}, "缺少右括号")
		}
		return expression, nil
	}
	condition, err := p.parseCondition()
	if err != nil {
		return nil, err
	}
	return &bqlExpression{op: "CONDITION", condition: &condition}, nil
}

func (p *bqlExpressionParser) parseCondition() (bqlCondition, error) {
	first := p.peek()
	if first.kind != "value" {
		return bqlCondition{}, p.errorf("条件需要字段名")
	}
	p.index++
	field := strings.ToLower(first.text)
	if first.quoted || !bqlIdentifierRE.MatchString(field) {
		literal, err := parseBQLTokenLiteral(first)
		if err != nil {
			return bqlCondition{}, p.errorf("%v", err)
		}
		negated := p.matchKeyword("NOT")
		if !p.matchKeyword(bqlOpIn) {
			return bqlCondition{}, p.errorf("字面量左侧只支持 IN 集合字段")
		}
		collection := p.peek()
		if collection.kind != "value" || collection.quoted || !bqlIdentifierRE.MatchString(strings.ToLower(collection.text)) {
			return bqlCondition{}, p.errorf("IN 右侧需要集合字段")
		}
		p.index++
		op := bqlOpContains
		if negated {
			op = bqlOpNotContains
		}
		return bqlCondition{field: strings.ToLower(collection.text), op: op, values: []bqlLiteral{literal}}, nil
	}

	if p.matchKeyword("IS") {
		negated := p.matchKeyword("NOT")
		if !p.matchKeyword("NULL") {
			return bqlCondition{}, p.errorf("IS 后只支持 NULL 或 NOT NULL")
		}
		op := bqlOpIsNull
		if negated {
			op = bqlOpIsNotNull
		}
		return bqlCondition{field: field, op: op}, nil
	}

	negated := p.matchKeyword("NOT")
	if p.matchKeyword(bqlOpIn) {
		values, err := p.parseLiteralList()
		if err != nil {
			return bqlCondition{}, err
		}
		op := bqlOpIn
		if negated {
			op = bqlOpNotIn
		}
		return bqlCondition{field: field, op: op, values: values}, nil
	}
	if p.matchKeyword(bqlOpBetween) {
		lower, err := p.parseLiteral()
		if err != nil {
			return bqlCondition{}, err
		}
		if !p.matchKeyword("AND") {
			return bqlCondition{}, p.errorf("BETWEEN 需要 AND 上界")
		}
		upper, err := p.parseLiteral()
		if err != nil {
			return bqlCondition{}, err
		}
		op := bqlOpBetween
		if negated {
			op = bqlOpNotBetween
		}
		return bqlCondition{field: field, op: op, values: []bqlLiteral{lower, upper}}, nil
	}
	if p.matchKeyword(bqlOpLike) {
		value, err := p.parseLiteral()
		if err != nil {
			return bqlCondition{}, err
		}
		op := bqlOpLike
		if negated {
			op = bqlOpNotLike
		}
		return bqlCondition{field: field, op: op, values: []bqlLiteral{value}}, nil
	}
	if negated {
		return bqlCondition{}, p.errorf("NOT 后支持 IN、BETWEEN 或 LIKE")
	}

	operator := p.peek()
	if operator.kind != "operator" || !bqlDirectOperator(operator.text) {
		return bqlCondition{}, p.issue("expected_operator", bqlConditionOperatorNames(), "字段 %q 后缺少支持的比较运算符", field)
	}
	p.index++
	value, err := p.parseLiteral()
	if err != nil {
		return bqlCondition{}, err
	}
	return bqlCondition{field: field, op: operator.text, values: []bqlLiteral{value}}, nil
}

func (p *bqlExpressionParser) parseLiteralList() ([]bqlLiteral, error) {
	if !p.matchKind("(") {
		return nil, p.errorf("IN 需要括号包围的值列表")
	}
	values := []bqlLiteral{}
	if p.matchKind(")") {
		return nil, p.errorf("IN 值列表不能为空")
	}
	for {
		if len(values) >= bqlMaxInValues {
			return nil, p.errorf("IN 值列表不能超过 %d 项", bqlMaxInValues)
		}
		value, err := p.parseLiteral()
		if err != nil {
			return nil, err
		}
		values = append(values, value)
		if p.matchKind(")") {
			return values, nil
		}
		if !p.matchKind(",") {
			return nil, p.errorf("IN 值之间需要逗号")
		}
	}
}

func (p *bqlExpressionParser) parseLiteral() (bqlLiteral, error) {
	token := p.peek()
	if token.kind != "value" {
		return bqlLiteral{}, p.errorf("条件值不能为空")
	}
	p.index++
	literal, err := parseBQLTokenLiteral(token)
	if err != nil {
		return bqlLiteral{}, p.errorf("%v", err)
	}
	return literal, nil
}

func (p *bqlExpressionParser) peek() bqlToken {
	if p.index >= len(p.tokens) {
		return bqlToken{kind: "eof", position: 1}
	}
	return p.tokens[p.index]
}

func (p *bqlExpressionParser) matchKind(kind string) bool {
	if p.peek().kind != kind {
		return false
	}
	p.index++
	return true
}

func (p *bqlExpressionParser) matchKeyword(keyword string) bool {
	token := p.peek()
	if token.kind != "value" || token.quoted || !strings.EqualFold(token.text, keyword) {
		return false
	}
	p.index++
	return true
}

func (p *bqlExpressionParser) errorf(format string, args ...any) error {
	return p.issue("invalid_expression", nil, format, args...)
}

func (p *bqlExpressionParser) issue(code string, expected []string, format string, args ...any) error {
	return newBQLValidationError(code, p.clause, p.peek().position, fmt.Sprintf(format, args...), expected...)
}

func parseBQLTokenLiteral(token bqlToken) (bqlLiteral, error) {
	if token.kind != "value" || token.text == "" && !token.quoted {
		return bqlLiteral{}, errors.New("条件值不能为空")
	}
	if token.quoted {
		return bqlLiteral{raw: token.text}, nil
	}
	if !token.quoted && strings.EqualFold(token.text, "NULL") {
		return bqlLiteral{raw: token.text, null: true}, nil
	}
	return parseBQLLiteral(token.text)
}

func parseBQLLiteral(raw string) (bqlLiteral, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return bqlLiteral{}, errors.New("WHERE 条件值不能为空")
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
		index := -1
		if ordinal, err := strconv.Atoi(key); err == nil {
			if ordinal <= 0 {
				return nil, errors.New("ORDER BY 列序号必须是正整数")
			}
			index = ordinal - 1
		} else if !bqlIdentifierRE.MatchString(key) {
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
		if len(fields) > 2 {
			return nil, fmt.Errorf("无法解析 ORDER BY 项 %q", item)
		}
		orders = append(orders, bqlOrder{key: key, index: index, desc: desc})
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
			if (item.aggregate == "sum" || item.aggregate == "avg") && item.field != "*" && !bqlFieldIsNumeric(query.table, item.field) {
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
	if err := validateBQLExpression(query.where, fields, bqlCollectionFields(query.table), "WHERE"); err != nil {
		return fmt.Errorf("%s %w", query.table, err)
	}
	if query.having != nil && !aggregate && len(query.groupBy) == 0 {
		return errors.New("HAVING 需要 GROUP BY 或聚合列")
	}
	if err := validateBQLExpression(query.having, selectAliases, nil, "HAVING"); err != nil {
		return err
	}
	for _, order := range query.orderBy {
		if order.index >= len(query.selects) {
			return fmt.Errorf("ORDER BY 列序号 %d 超出 SELECT 列范围", order.index+1)
		}
		if order.index < 0 && !selectAliases[order.key] {
			return fmt.Errorf("ORDER BY 字段 %q 必须是 SELECT 结果列", order.key)
		}
	}
	return nil
}

func validateBQLExpression(expression *bqlExpression, fields, collectionFields map[string]bool, clause string) error {
	if expression == nil {
		return nil
	}
	if expression.condition != nil {
		condition := expression.condition
		if !fields[condition.field] {
			return fmt.Errorf("不支持 %s 字段 %q", clause, condition.field)
		}
		operator, ok := bqlOperator(condition.op)
		if !ok {
			return fmt.Errorf("%s 使用了未知运算符 %q", clause, condition.op)
		}
		if operator.collection {
			if !collectionFields[condition.field] {
				return fmt.Errorf("%s 字段 %q 不是集合字段", clause, condition.field)
			}
		}
		if operator.patternKind == "regex" {
			pattern, err := regexp.Compile("(?i:" + condition.values[0].raw + ")")
			if err != nil {
				return fmt.Errorf("%s 正则表达式无效: %w", clause, err)
			}
			condition.pattern = pattern
		}
		if operator.patternKind == "like" {
			pattern, err := compileBQLLikePattern(condition.values[0].raw)
			if err != nil {
				return fmt.Errorf("%s LIKE 表达式无效: %w", clause, err)
			}
			condition.pattern = pattern
		}
		return nil
	}
	if err := validateBQLExpression(expression.left, fields, collectionFields, clause); err != nil {
		return err
	}
	return validateBQLExpression(expression.right, fields, collectionFields, clause)
}

func bqlSupportedFields(table string) map[string]bool {
	fields := map[string]bool{}
	for _, field := range bqlFieldDefinitions(table) {
		fields[field.name] = true
	}
	return fields
}

func bqlFieldOrder(table string) []string {
	fields := bqlFieldDefinitions(table)
	order := make([]string, 0, len(fields))
	for _, field := range fields {
		order = append(order, field.name)
	}
	return order
}

func bqlCollectionFields(table string) map[string]bool {
	fields := map[string]bool{}
	for _, field := range bqlFieldDefinitions(table) {
		if field.collection {
			fields[field.name] = true
		}
	}
	return fields
}

func bqlFieldIsNumeric(table, name string) bool {
	for _, field := range bqlFieldDefinitions(table) {
		if field.name == name {
			return field.numeric
		}
	}
	return false
}

func bqlDeclaredFieldType(name string) string {
	for _, table := range []string{"postings", "transactions"} {
		for _, field := range bqlFieldDefinitions(table) {
			if field.name == name {
				return field.typ
			}
		}
	}
	return "string"
}

func bqlFieldDefinitions(table string) []bqlFieldDefinition {
	if table == "transactions" {
		return []bqlFieldDefinition{
			{name: "date", typ: "date"}, {name: "month", typ: "month"}, {name: "year", typ: "string"},
			{name: "payee", typ: "string"}, {name: "narration", typ: "string"}, {name: "accounts", typ: "string", collection: true},
			{name: "amount", typ: "money", numeric: true}, {name: "value", typ: "money", numeric: true}, {name: "type", typ: "string"},
			{name: "tags", typ: "string", collection: true}, {name: "links", typ: "string", collection: true}, {name: "source", typ: "string"},
			{name: "line", typ: "number", numeric: true}, {name: "txn_index", typ: "number", numeric: true},
		}
	}
	return []bqlFieldDefinition{
		{name: "date", typ: "date"}, {name: "month", typ: "month"}, {name: "year", typ: "string"},
		{name: "payee", typ: "string"}, {name: "narration", typ: "string"}, {name: "account", typ: "string"}, {name: "account_root", typ: "string"},
		{name: "amount", typ: "money", numeric: true}, {name: "value", typ: "money", numeric: true}, {name: "currency", typ: "string"}, {name: "type", typ: "string"},
		{name: "tags", typ: "string", collection: true}, {name: "links", typ: "string", collection: true}, {name: "source", typ: "string"},
		{name: "line", typ: "number", numeric: true}, {name: "txn_index", typ: "number", numeric: true}, {name: "posting_index", typ: "number", numeric: true},
	}
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
		"tags":          {value: strings.Join(txn.Tags, " "), typ: "string", items: txn.Tags},
		"links":         {value: strings.Join(txn.Links, " "), typ: "string", items: txn.Links},
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
		"accounts":  {value: strings.Join(accounts, " "), typ: "string", items: accounts},
		"amount":    {value: transactionQueryAmount(txn), typ: "money"},
		"value":     {value: value, typ: "money"},
		"type":      {value: dashboardTransactionType(txn), typ: "string"},
		"tags":      {value: strings.Join(txn.Tags, " "), typ: "string", items: txn.Tags},
		"links":     {value: strings.Join(txn.Links, " "), typ: "string", items: txn.Links},
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

func bqlRowMatches(row bqlRow, expression *bqlExpression) bool {
	if expression == nil {
		return true
	}
	switch expression.op {
	case "AND":
		return bqlRowMatches(row, expression.left) && bqlRowMatches(row, expression.right)
	case "OR":
		return bqlRowMatches(row, expression.left) || bqlRowMatches(row, expression.right)
	case "NOT":
		return !bqlRowMatches(row, expression.left)
	case "CONDITION":
		return bqlConditionMatches(row, *expression.condition)
	default:
		return false
	}
}

func bqlConditionMatches(row bqlRow, condition bqlCondition) bool {
	value, ok := row.values[condition.field]
	if condition.op == bqlOpIsNull {
		return !ok || value.value == nil
	}
	if condition.op == bqlOpIsNotNull {
		return ok && value.value != nil
	}
	if !ok || value.value == nil {
		return false
	}
	switch condition.op {
	case bqlOpIn, bqlOpNotIn:
		matches := false
		for _, candidate := range condition.values {
			if bqlCompare(value, bqlOpEqual, candidate) {
				matches = true
				break
			}
		}
		if condition.op == bqlOpNotIn {
			return !matches
		}
		return matches
	case bqlOpBetween, bqlOpNotBetween:
		matches := bqlCompare(value, bqlOpGreaterEq, condition.values[0]) && bqlCompare(value, bqlOpLessEq, condition.values[1])
		if condition.op == bqlOpNotBetween {
			return !matches
		}
		return matches
	case bqlOpContains, bqlOpNotContains:
		matches := false
		for _, item := range value.items {
			if strings.EqualFold(item, condition.values[0].raw) {
				matches = true
				break
			}
		}
		if condition.op == bqlOpNotContains {
			return !matches
		}
		return matches
	case bqlOpLike, bqlOpNotLike, bqlOpMatch, bqlOpNotMatch:
		if value.typ == "money" || value.typ == "number" || condition.pattern == nil {
			return false
		}
		matches := condition.pattern.MatchString(fmt.Sprint(value.value))
		if condition.op == bqlOpNotLike || condition.op == bqlOpNotMatch {
			return !matches
		}
		return matches
	default:
		return bqlCompare(value, condition.op, condition.values[0])
	}
}

func bqlCompare(left bqlValue, op string, right bqlLiteral) bool {
	if right.null {
		return false
	}
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
	case bqlOpEqual:
		return strings.EqualFold(leftText, rightText)
	case bqlOpNotEqual:
		return !strings.EqualFold(leftText, rightText)
	case bqlOpGreater:
		return leftText > rightText
	case bqlOpGreaterEq:
		return leftText >= rightText
	case bqlOpLess:
		return leftText < rightText
	case bqlOpLessEq:
		return leftText <= rightText
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
	case bqlOpEqual:
		return left == right
	case bqlOpNotEqual:
		return left != right
	case bqlOpGreater:
		return left > right
	case bqlOpGreaterEq:
		return left >= right
	case bqlOpLess:
		return left < right
	case bqlOpLessEq:
		return left <= right
	default:
		return false
	}
}

func compileBQLLikePattern(pattern string) (*regexp.Regexp, error) {
	var expression strings.Builder
	expression.WriteString("(?i)^")
	for _, ch := range pattern {
		switch ch {
		case '%':
			expression.WriteString(".*")
		case '_':
			expression.WriteByte('.')
		default:
			expression.WriteString(regexp.QuoteMeta(string(ch)))
		}
	}
	expression.WriteByte('$')
	return regexp.Compile(expression.String())
}

func bqlColumns(query bqlQuery, rows []bqlRow) []BQLColumn {
	columns := make([]BQLColumn, 0, len(query.selects))
	for _, item := range query.selects {
		columns = append(columns, BQLColumn{Name: item.alias, Type: bqlSelectType(rows, item)})
	}
	return columns
}

func bqlSelectType(rows []bqlRow, item bqlSelect) string {
	if item.aggregate == "count" {
		return "number"
	}
	return bqlFieldType(rows, item.field)
}

func bqlFieldType(rows []bqlRow, field string) string {
	for _, row := range rows {
		if value, ok := row.values[field]; ok {
			return value.typ
		}
	}
	return bqlDeclaredFieldType(field)
}

func bqlResultRows(query bqlQuery, rows []bqlRow) []bqlProjectedRow {
	if bqlQueryAggregates(query) || len(query.groupBy) > 0 {
		grouped := bqlGroupedRows(query, rows)
		out := make([]bqlProjectedRow, 0, len(grouped))
		for _, cells := range grouped {
			values := make(map[string]bqlValue, len(query.selects))
			for index, item := range query.selects {
				values[item.alias] = bqlValue{value: cells[index], typ: bqlSelectType(rows, item)}
			}
			out = append(out, bqlProjectedRow{cells: cells, row: bqlRow{values: values}})
		}
		return out
	}
	out := make([]bqlProjectedRow, 0, len(rows))
	for _, sourceRow := range rows {
		cells := make([]any, 0, len(query.selects))
		values := make(map[string]bqlValue, len(query.selects))
		for _, item := range query.selects {
			value := sourceRow.values[item.field]
			cells = append(cells, value.value)
			values[item.alias] = value
		}
		out = append(out, bqlProjectedRow{cells: cells, row: bqlRow{values: values}})
	}
	return out
}

func bqlFilterResultRows(rows []bqlProjectedRow, expression *bqlExpression) []bqlProjectedRow {
	if expression == nil {
		return rows
	}
	filtered := make([]bqlProjectedRow, 0, len(rows))
	for _, resultRow := range rows {
		if bqlRowMatches(resultRow.row, expression) {
			filtered = append(filtered, resultRow)
		}
	}
	return filtered
}

func bqlDistinctRows(rows []bqlProjectedRow) []bqlProjectedRow {
	seen := map[string]bool{}
	distinct := make([]bqlProjectedRow, 0, len(rows))
	for _, row := range rows {
		key := bqlValuesKey(row.cells)
		if seen[key] {
			continue
		}
		seen[key] = true
		distinct = append(distinct, row)
	}
	return distinct
}

func bqlResultCells(rows []bqlProjectedRow) [][]any {
	cells := make([][]any, 0, len(rows))
	for _, row := range rows {
		cells = append(cells, row.cells)
	}
	return cells
}

func bqlValuesKey(values []any) string {
	var key strings.Builder
	for _, value := range values {
		rendered := fmt.Sprint(value)
		fmt.Fprintf(&key, "%T:%d:", value, len(rendered))
		key.WriteString(rendered)
	}
	return key.String()
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
	if len(query.groupBy) == 0 {
		groups["__all__"] = &group{values: map[string]any{}, agg: bqlAggregate{sums: map[int]float64{}}}
	}
	for _, row := range rows {
		keyValues := make([]any, 0, len(query.groupBy))
		values := map[string]any{}
		for _, field := range query.groupBy {
			value := row.values[field].value
			values[field] = value
			keyValues = append(keyValues, value)
		}
		key := bqlValuesKey(keyValues)
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
		candidate := row.values[field].value
		if !hasSelected || op == "min" && compareBQLAny(candidate, selected) < 0 || op == "max" && compareBQLAny(candidate, selected) > 0 {
			selected = candidate
			hasSelected = true
		}
	}
	if !hasSelected {
		return 0
	}
	return selected
}

func bqlSortRows(rows []bqlProjectedRow, selects []bqlSelect, orders []bqlOrder) {
	if len(orders) == 0 {
		return
	}
	indexByName := map[string]int{}
	for index, item := range selects {
		indexByName[item.alias] = index
	}
	sort.SliceStable(rows, func(i, j int) bool {
		for _, order := range orders {
			index := order.index
			if index < 0 {
				var ok bool
				index, ok = indexByName[order.key]
				if !ok {
					continue
				}
			}
			cmp := compareBQLAny(rows[i].cells[index], rows[j].cells[index])
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
