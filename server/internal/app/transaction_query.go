package app

import (
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const (
	transactionQueryMinDate = "2000-01-01"
	transactionQueryMaxDate = "2100-01-01"
)

type transactionQuery struct {
	root transactionQueryNode
}

type transactionQueryNode interface {
	Matches(Transaction) bool
}

type queryBinaryNode struct {
	op          string
	left, right transactionQueryNode
}

type queryNotNode struct {
	node transactionQueryNode
}

type queryTermNode struct {
	field string
	op    string
	value string
}

type queryAllNode struct{}

type transactionQueryDateRange struct {
	start string
	end   string
}

func ParseTransactionQuery(raw string) (*transactionQuery, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parser := transactionQueryParser{tokens: tokenizeTransactionQuery(raw)}
	root, err := parser.parseOr()
	if err != nil {
		return nil, err
	}
	if parser.peek().kind != queryTokenEOF {
		return nil, fmt.Errorf("无法解析查询片段 %q", parser.peek().value)
	}
	return &transactionQuery{root: root}, nil
}

func MustTransactionQuery(raw string) *transactionQuery {
	query, err := ParseTransactionQuery(raw)
	if err != nil {
		return nil
	}
	return query
}

func (q *transactionQuery) Matches(txn Transaction) bool {
	if q == nil || q.root == nil {
		return true
	}
	return q.root.Matches(txn)
}

func FilterTransactionsByQuery(txns []Transaction, query *transactionQuery) []Transaction {
	if query == nil {
		return txns
	}
	out := make([]Transaction, 0, len(txns))
	for _, txn := range txns {
		if query.Matches(txn) {
			out = append(out, txn)
		}
	}
	return out
}

func transactionQueryEffectiveRange(start, end string, query *transactionQuery) (string, string) {
	if query == nil || query.root == nil {
		return start, end
	}
	if dateRange, ok := transactionQueryNodeDateRange(query.root); ok {
		return dateRange.start, dateRange.end
	}
	return start, end
}

func transactionQueryNodeDateRange(node transactionQueryNode) (transactionQueryDateRange, bool) {
	switch n := node.(type) {
	case queryTermNode:
		if strings.ToLower(n.field) != "date" {
			return transactionQueryDateRange{}, false
		}
		return queryDateTermRange(n.op, n.value)
	case queryBinaryNode:
		if n.op != "AND" {
			return transactionQueryDateRange{}, false
		}
		left, leftOK := transactionQueryNodeDateRange(n.left)
		right, rightOK := transactionQueryNodeDateRange(n.right)
		switch {
		case leftOK && rightOK:
			return intersectTransactionQueryDateRanges(left, right)
		case leftOK:
			return left, true
		case rightOK:
			return right, true
		default:
			return transactionQueryDateRange{}, false
		}
	default:
		return transactionQueryDateRange{}, false
	}
}

func intersectTransactionQueryDateRanges(left, right transactionQueryDateRange) (transactionQueryDateRange, bool) {
	start := left.start
	if right.start > start {
		start = right.start
	}
	end := left.end
	if right.end < end {
		end = right.end
	}
	if start >= end {
		return transactionQueryDateRange{start: start, end: start}, true
	}
	return transactionQueryDateRange{start: start, end: end}, true
}

func (queryAllNode) Matches(Transaction) bool {
	return true
}

func (n queryBinaryNode) Matches(txn Transaction) bool {
	switch n.op {
	case "AND":
		return n.left.Matches(txn) && n.right.Matches(txn)
	case "OR":
		return n.left.Matches(txn) || n.right.Matches(txn)
	default:
		return false
	}
}

func (n queryNotNode) Matches(txn Transaction) bool {
	return !n.node.Matches(txn)
}

func (n queryTermNode) Matches(txn Transaction) bool {
	field := strings.ToLower(n.field)
	value := strings.TrimSpace(n.value)
	if value == "" {
		return true
	}
	switch field {
	case "", "text", "q":
		return queryContains(transactionText(txn), value)
	case "payee":
		return queryMatchString(txn.Payee, n.op, value)
	case "narration", "desc", "description":
		return queryMatchString(txn.Narration, n.op, value)
	case "account", "accounts", "category":
		return transactionHasAccountPrefix(txn, value) || queryContains(transactionAccountsText(txn), value)
	case "tag", "tags":
		return queryStringSliceContains(txn.Tags, value)
	case "link", "links":
		return queryStringSliceContains(txn.Links, value)
	case "meta", "metadata":
		return queryAnyMetadataMatches(txn, value)
	case "currency":
		return transactionHasCurrency(txn, value)
	case "type":
		return strings.EqualFold(dashboardTransactionType(txn), value)
	case "date":
		return queryDateMatches(txn.Date, n.op, value)
	case "amount":
		return queryCompareInt(transactionQueryAmount(txn), n.op, cents(value))
	default:
		if strings.HasPrefix(field, "meta.") || strings.HasPrefix(field, "metadata.") {
			key := strings.TrimPrefix(strings.TrimPrefix(field, "meta."), "metadata.")
			return queryMetadataMatches(txn, key, value)
		}
		return false
	}
}

func transactionText(txn Transaction) string {
	parts := []string{txn.Date, txn.Payee, txn.Narration}
	parts = append(parts, txn.Tags...)
	parts = append(parts, txn.Links...)
	for key, value := range txn.Metadata {
		parts = append(parts, key, fmt.Sprint(value))
	}
	for _, posting := range txn.Postings {
		parts = append(parts, posting.Account, posting.Currency)
	}
	return strings.Join(parts, " ")
}

func transactionAccountsText(txn Transaction) string {
	accounts := make([]string, 0, len(txn.Postings))
	for _, posting := range txn.Postings {
		accounts = append(accounts, posting.Account)
	}
	return strings.Join(accounts, " ")
}

func transactionHasCurrency(txn Transaction, value string) bool {
	for _, posting := range txn.Postings {
		if strings.EqualFold(posting.Currency, value) {
			return true
		}
	}
	return false
}

func queryMetadataMatches(txn Transaction, key, value string) bool {
	for metaKey, metaValue := range txn.Metadata {
		if strings.EqualFold(metaKey, key) && queryContains(fmt.Sprint(metaValue), value) {
			return true
		}
	}
	return false
}

func queryAnyMetadataMatches(txn Transaction, value string) bool {
	key, expected, ok := strings.Cut(value, ":")
	if ok && key != "" {
		return queryMetadataMatches(txn, key, expected)
	}
	for metaKey, metaValue := range txn.Metadata {
		if queryContains(metaKey, value) || queryContains(fmt.Sprint(metaValue), value) {
			return true
		}
	}
	return false
}

func transactionQueryAmount(txn Transaction) int {
	amount := 0
	for _, posting := range txn.Postings {
		if abs(posting.Amount) > amount {
			amount = abs(posting.Amount)
		}
	}
	return amount
}

func queryContains(text, value string) bool {
	return strings.Contains(strings.ToLower(text), strings.ToLower(value))
}

func queryMatchString(text, op, value string) bool {
	if op == "=" {
		return strings.EqualFold(text, value)
	}
	return queryContains(text, value)
}

func queryStringSliceContains(values []string, value string) bool {
	for _, item := range values {
		if queryContains(item, value) {
			return true
		}
	}
	return false
}

func queryCompareString(left, op, right string) bool {
	switch op {
	case ">", ">=", "<", "<=", "=", ":":
	default:
		op = ":"
	}
	switch op {
	case ">":
		return left > right
	case ">=":
		return left >= right
	case "<":
		return left < right
	case "<=":
		return left <= right
	case "=":
		return left == right
	default:
		return queryContains(left, right)
	}
}

func queryDateMatches(date, op, value string) bool {
	if dateRange, ok := queryDateTermRange(op, value); ok {
		return date >= dateRange.start && date < dateRange.end
	}
	return false
}

func queryDateTermRange(op, value string) (transactionQueryDateRange, bool) {
	value = strings.TrimSpace(value)
	switch op {
	case ":", "=":
		return exactTransactionQueryDateRange(value)
	case ">=", ">", "<", "<=":
		date, ok := parseTransactionQueryDate(value)
		if !ok {
			return transactionQueryDateRange{}, false
		}
		switch op {
		case ">=":
			return transactionQueryDateRange{start: date, end: transactionQueryMaxDate}, true
		case ">":
			next, ok := shiftTransactionQueryDate(date, 1)
			if !ok {
				return transactionQueryDateRange{}, false
			}
			return transactionQueryDateRange{start: next, end: transactionQueryMaxDate}, true
		case "<":
			return transactionQueryDateRange{start: transactionQueryMinDate, end: date}, true
		case "<=":
			next, ok := shiftTransactionQueryDate(date, 1)
			if !ok {
				return transactionQueryDateRange{}, false
			}
			return transactionQueryDateRange{start: transactionQueryMinDate, end: next}, true
		}
	}
	return transactionQueryDateRange{}, false
}

func exactTransactionQueryDateRange(value string) (transactionQueryDateRange, bool) {
	if len(value) == len("2006-01") {
		date, err := time.Parse("2006-01", value)
		if err != nil || date.Format("2006-01") != value {
			return transactionQueryDateRange{}, false
		}
		return transactionQueryDateRange{
			start: date.Format("2006-01-02"),
			end:   date.AddDate(0, 1, 0).Format("2006-01-02"),
		}, true
	}
	date, ok := parseTransactionQueryDate(value)
	if !ok {
		return transactionQueryDateRange{}, false
	}
	next, ok := shiftTransactionQueryDate(date, 1)
	if !ok {
		return transactionQueryDateRange{}, false
	}
	return transactionQueryDateRange{start: date, end: next}, true
}

func parseTransactionQueryDate(value string) (string, bool) {
	date, err := time.Parse("2006-01-02", value)
	if err != nil || date.Format("2006-01-02") != value {
		return "", false
	}
	return date.Format("2006-01-02"), true
}

func shiftTransactionQueryDate(value string, days int) (string, bool) {
	date, err := time.Parse("2006-01-02", value)
	if err != nil || date.Format("2006-01-02") != value {
		return "", false
	}
	return date.AddDate(0, 0, days).Format("2006-01-02"), true
}

func queryCompareInt(left int, op string, right int) bool {
	switch op {
	case ">":
		return left > right
	case ">=":
		return left >= right
	case "<":
		return left < right
	case "<=":
		return left <= right
	case "=":
		return left == right
	default:
		return left == right
	}
}

type queryTokenKind int

const (
	queryTokenWord queryTokenKind = iota
	queryTokenLParen
	queryTokenRParen
	queryTokenEOF
)

type queryToken struct {
	kind  queryTokenKind
	value string
}

func tokenizeTransactionQuery(raw string) []queryToken {
	tokens := []queryToken{}
	for index := 0; index < len(raw); {
		r := rune(raw[index])
		if unicode.IsSpace(r) {
			index++
			continue
		}
		if raw[index] == '(' {
			tokens = append(tokens, queryToken{kind: queryTokenLParen, value: "("})
			index++
			continue
		}
		if raw[index] == ')' {
			tokens = append(tokens, queryToken{kind: queryTokenRParen, value: ")"})
			index++
			continue
		}
		if raw[index] == '"' || raw[index] == '\'' {
			quote := raw[index]
			start := index + 1
			index++
			var builder strings.Builder
			for index < len(raw) && raw[index] != quote {
				if raw[index] == '\\' && index+1 < len(raw) {
					index++
				}
				builder.WriteByte(raw[index])
				index++
			}
			if index < len(raw) && raw[index] == quote {
				index++
			}
			tokens = append(tokens, queryToken{kind: queryTokenWord, value: builder.String()})
			if builder.Len() == 0 && start == index-1 {
				tokens[len(tokens)-1].value = ""
			}
			continue
		}
		var builder strings.Builder
		for index < len(raw) && !unicode.IsSpace(rune(raw[index])) && raw[index] != '(' && raw[index] != ')' {
			if raw[index] == '"' || raw[index] == '\'' {
				quote := raw[index]
				index++
				for index < len(raw) && raw[index] != quote {
					if raw[index] == '\\' && index+1 < len(raw) {
						index++
					}
					builder.WriteByte(raw[index])
					index++
				}
				if index < len(raw) && raw[index] == quote {
					index++
				}
				continue
			}
			builder.WriteByte(raw[index])
			index++
		}
		tokens = append(tokens, queryToken{kind: queryTokenWord, value: builder.String()})
	}
	return append(tokens, queryToken{kind: queryTokenEOF})
}

type transactionQueryParser struct {
	tokens []queryToken
	index  int
}

func (p *transactionQueryParser) parseOr() (transactionQueryNode, error) {
	left, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for strings.EqualFold(p.peek().value, "OR") {
		p.next()
		right, err := p.parseAnd()
		if err != nil {
			return nil, err
		}
		left = queryBinaryNode{op: "OR", left: left, right: right}
	}
	return left, nil
}

func (p *transactionQueryParser) parseAnd() (transactionQueryNode, error) {
	left, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for {
		token := p.peek()
		if strings.EqualFold(token.value, "AND") {
			p.next()
		} else if token.kind == queryTokenWord && !strings.EqualFold(token.value, "OR") && !strings.EqualFold(token.value, "NOT") {
			// Adjacent terms are implicit AND.
		} else if token.kind == queryTokenLParen {
			// Adjacent grouped expressions are implicit AND.
		} else {
			break
		}
		right, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		left = queryBinaryNode{op: "AND", left: left, right: right}
	}
	return left, nil
}

func (p *transactionQueryParser) parseUnary() (transactionQueryNode, error) {
	if strings.EqualFold(p.peek().value, "NOT") {
		p.next()
		node, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return queryNotNode{node: node}, nil
	}
	return p.parsePrimary()
}

func (p *transactionQueryParser) parsePrimary() (transactionQueryNode, error) {
	token := p.next()
	switch token.kind {
	case queryTokenLParen:
		node, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		if p.peek().kind != queryTokenRParen {
			return nil, fmt.Errorf("查询括号未闭合")
		}
		p.next()
		return node, nil
	case queryTokenWord:
		if token.value == "" {
			return queryAllNode{}, nil
		}
		return parseQueryTerm(token.value)
	default:
		return nil, fmt.Errorf("查询表达式不完整")
	}
}

func (p *transactionQueryParser) peek() queryToken {
	if p.index >= len(p.tokens) {
		return queryToken{kind: queryTokenEOF}
	}
	return p.tokens[p.index]
}

func (p *transactionQueryParser) next() queryToken {
	token := p.peek()
	if p.index < len(p.tokens) {
		p.index++
	}
	return token
}

func parseQueryTerm(raw string) (transactionQueryNode, error) {
	if strings.HasPrefix(raw, "#") && len(raw) > 1 {
		return queryTermNode{field: "tag", op: ":", value: strings.TrimPrefix(raw, "#")}, nil
	}
	field, op, value := splitQueryTerm(raw)
	if field == "" {
		return queryTermNode{op: ":", value: raw}, nil
	}
	if !isSupportedTransactionQueryField(field) {
		return nil, fmt.Errorf("不支持的查询字段 %q", field)
	}
	if field == "amount" && op == ":" {
		op = "="
	}
	if field == "amount" {
		if _, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(strings.ReplaceAll(value, ",", ""), "¥")), 64); err != nil {
			return nil, fmt.Errorf("金额条件 %q 不是有效数字", value)
		}
	}
	return queryTermNode{field: field, op: op, value: value}, nil
}

func splitQueryTerm(raw string) (field, op, value string) {
	operators := []string{">=", "<=", ">", "<", "=", ":"}
	for _, candidate := range operators {
		if index := strings.Index(raw, candidate); index > 0 {
			return strings.ToLower(strings.TrimSpace(raw[:index])), candidate, strings.TrimSpace(raw[index+len(candidate):])
		}
	}
	return "", ":", raw
}

func isSupportedTransactionQueryField(field string) bool {
	switch strings.ToLower(field) {
	case "text", "q", "payee", "narration", "desc", "description", "account", "accounts", "category", "tag", "tags", "link", "links", "meta", "metadata", "currency", "type", "date", "amount":
		return true
	default:
		return strings.HasPrefix(field, "meta.") || strings.HasPrefix(field, "metadata.")
	}
}
