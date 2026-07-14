package app

import (
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type BeanParseError struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Message string `json:"message"`
}

type BeanEntry struct {
	Kind          string
	Date          string
	File          string
	Line          int
	RawLines      []string
	Name          string
	Value         string
	Filename      string
	Flag          string
	Payee         string
	Narration     string
	Account       string
	Account2      string
	Currencies    []string
	Currency      string
	Amount        int
	AmountValue   BeanAmount
	Tolerance     string
	QuoteCurrency string
	Metadata      map[string]MetadataValue
	Tags          []string
	Links         []string
	Postings      []parsedPosting
	CustomType    string
	CustomValues  []MetadataValue
}

type BeanParseResult struct {
	Entries []BeanEntry
	Errors  []BeanParseError
}

type beanTokenKind int

const (
	beanTokenWord beanTokenKind = iota
	beanTokenString
	beanTokenNumber
	beanTokenTag
	beanTokenLink
	beanTokenPunct
)

type beanToken struct {
	Kind  beanTokenKind
	Value string
}

func ParseBeanLines(lines []BeanLine) BeanParseResult {
	parser := beanLineParser{lines: lines}
	return parser.parse()
}

func CompileBeanLines(lines []BeanLine) BeanParseResult {
	result := ParseBeanLines(lines)
	result.Errors = append(result.Errors, validateBeanEntries(result.Entries)...)
	return result
}

type beanLineParser struct {
	lines      []BeanLine
	errors     []BeanParseError
	activeTags []string
	activeMeta map[string]MetadataValue
}

func (p *beanLineParser) parse() BeanParseResult {
	if p.activeMeta == nil {
		p.activeMeta = map[string]MetadataValue{}
	}
	entries := []BeanEntry{}
	for i := 0; i < len(p.lines); {
		line := p.lines[i]
		trimmed := strings.TrimSpace(line.Text)
		if trimmed == "" || strings.HasPrefix(trimmed, ";") || isIndentedBeanLine(line.Text) {
			i++
			continue
		}
		tokens := scanBeanLine(trimmed)
		if len(tokens) == 0 {
			i++
			continue
		}
		if !isBeanDateToken(tokens[0].Value) {
			if entry, ok := p.parseGlobalDirective(line, tokens); ok {
				entries = append(entries, entry)
			} else if isKnownGlobalDirective(tokens[0].Value) {
				p.errors = append(p.errors, BeanParseError{File: line.File, Line: line.Line, Message: "malformed " + tokens[0].Value + " directive"})
			}
			i++
			continue
		}
		if len(tokens) < 2 {
			i++
			continue
		}
		blockEnd := i + 1
		for blockEnd < len(p.lines) {
			next := p.lines[blockEnd]
			nextTrimmed := strings.TrimSpace(next.Text)
			if nextTrimmed == "" || strings.HasPrefix(nextTrimmed, ";") || isIndentedBeanLine(next.Text) {
				blockEnd++
				continue
			}
			break
		}
		if entry, ok := p.parseEntry(linesBlock(p.lines[i:blockEnd])); ok {
			p.applyActiveScopes(&entry)
			entries = append(entries, entry)
		} else {
			p.errors = append(p.errors, BeanParseError{File: line.File, Line: line.Line, Message: "unrecognized dated directive"})
		}
		i = blockEnd
	}
	return BeanParseResult{Entries: entries, Errors: p.errors}
}

func (p *beanLineParser) parseGlobalDirective(line BeanLine, tokens []beanToken) (BeanEntry, bool) {
	entry := BeanEntry{File: line.File, Line: line.Line, RawLines: []string{line.Text}, Metadata: map[string]MetadataValue{}}
	switch tokens[0].Value {
	case "option":
		if len(tokens) >= 3 && tokens[1].Kind == beanTokenString && tokens[2].Kind == beanTokenString {
			entry.Kind = "option"
			entry.Name = tokens[1].Value
			entry.Value = tokens[2].Value
			return entry, true
		}
	case "include":
		if len(tokens) >= 2 && tokens[1].Kind == beanTokenString {
			entry.Kind = "include"
			entry.Filename = tokens[1].Value
			return entry, true
		}
	case "plugin":
		if len(tokens) >= 2 && tokens[1].Kind == beanTokenString {
			entry.Kind = "plugin"
			entry.Name = tokens[1].Value
			if len(tokens) >= 3 && tokens[2].Kind == beanTokenString {
				entry.Value = tokens[2].Value
			}
			return entry, true
		}
	case "pushtag":
		if len(tokens) >= 2 && tokens[1].Kind == beanTokenTag {
			entry.Kind = "pushtag"
			entry.Tags = []string{tokens[1].Value}
			p.activeTags = appendUniqueString(p.activeTags, tokens[1].Value)
			return entry, true
		}
	case "poptag":
		if len(tokens) >= 2 && tokens[1].Kind == beanTokenTag {
			entry.Kind = "poptag"
			entry.Tags = []string{tokens[1].Value}
			p.activeTags = removeString(p.activeTags, tokens[1].Value)
			return entry, true
		}
	case "pushmeta":
		if key, value, ok := parseMetadataLine(tokens[1:]); ok {
			entry.Kind = "pushmeta"
			entry.Metadata[key] = value
			p.activeMeta[key] = value
			return entry, true
		}
	case "popmeta":
		if len(tokens) >= 2 && strings.HasSuffix(tokens[1].Value, ":") {
			key := strings.TrimSuffix(tokens[1].Value, ":")
			if key != "" && isLowerFirst(key) {
				entry.Kind = "popmeta"
				entry.Name = key
				delete(p.activeMeta, key)
				return entry, true
			}
		}
	}
	return BeanEntry{}, false
}

func (p *beanLineParser) applyActiveScopes(entry *BeanEntry) {
	if len(p.activeMeta) > 0 {
		if entry.Metadata == nil {
			entry.Metadata = map[string]MetadataValue{}
		}
		for key, value := range p.activeMeta {
			if _, exists := entry.Metadata[key]; !exists {
				entry.Metadata[key] = value
			}
		}
	}
	if supportsBeanTags(entry.Kind) && len(p.activeTags) > 0 {
		for _, tag := range p.activeTags {
			entry.Tags = appendUniqueString(entry.Tags, tag)
		}
	}
}

func (p *beanLineParser) parseEntry(block []BeanLine) (BeanEntry, bool) {
	head := block[0]
	tokens := scanBeanLine(strings.TrimSpace(head.Text))
	if len(tokens) < 2 {
		return BeanEntry{}, false
	}
	entry := BeanEntry{
		Date:     normalizeBeanDate(tokens[0].Value),
		File:     head.File,
		Line:     head.Line,
		RawLines: beanLineTexts(block),
		Metadata: map[string]MetadataValue{},
	}
	keyword := tokens[1].Value
	switch {
	case isTransactionFlag(keyword):
		entry.Kind = "transaction"
		entry.Flag = keyword
		if entry.Flag == "txn" {
			entry.Flag = "*"
		}
		p.parseTransactionHead(&entry, tokens[2:])
		p.parseTransactionBody(&entry, block[1:])
		return entry, true
	case keyword == "open":
		entry.Kind = "open"
		if len(tokens) >= 3 {
			entry.Account = tokens[2].Value
			entry.Currencies = parseCurrencyList(tokens[3:])
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Account != ""
	case keyword == "close":
		entry.Kind = "close"
		if len(tokens) >= 3 {
			entry.Account = tokens[2].Value
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Account != ""
	case keyword == "commodity":
		entry.Kind = "commodity"
		if len(tokens) >= 3 {
			entry.Currency = tokens[2].Value
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Currency != ""
	case keyword == "price":
		entry.Kind = "price"
		if len(tokens) >= 5 {
			entry.Currency = tokens[2].Value
			if amount, _, ok := parseBeanAmountTokens(tokens[3:]); ok {
				entry.AmountValue = amount
				entry.Amount = amount.Cents()
				entry.QuoteCurrency = amount.Currency
			}
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Currency != "" && entry.QuoteCurrency != ""
	case keyword == "balance":
		entry.Kind = "balance"
		if len(tokens) >= 5 {
			entry.Account = tokens[2].Value
			if amount, tolerance, _, ok := parseBalanceBeanAmountTokens(tokens[3:]); ok {
				entry.AmountValue = amount
				entry.Amount = amount.Cents()
				entry.Currency = amount.Currency
				entry.Tolerance = tolerance
			}
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Account != "" && entry.Currency != ""
	case keyword == "custom":
		entry.Kind = "custom"
		if len(tokens) >= 3 && tokens[2].Kind == beanTokenString {
			entry.CustomType = tokens[2].Value
			entry.CustomValues = parseCustomValues(tokens[3:])
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.CustomType != ""
	case keyword == "pad":
		entry.Kind = "pad"
		if len(tokens) >= 4 {
			entry.Account = tokens[2].Value
			entry.Account2 = tokens[3].Value
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, entry.Account != "" && entry.Account2 != ""
	case keyword == "note":
		entry.Kind = keyword
		if len(tokens) >= 4 {
			entry.Account = tokens[2].Value
			entry.Narration = tokenStringValue(tokens[3])
		}
		entry.Tags, entry.Links = parseTagsLinks(tokens[3:])
		p.parseMetadataBody(&entry, block[1:])
		return entry, true
	case keyword == "document":
		entry.Kind = keyword
		if len(tokens) >= 4 {
			entry.Account = tokens[2].Value
			entry.Filename = tokenStringValue(tokens[3])
		}
		entry.Tags, entry.Links = parseTagsLinks(tokens[4:])
		p.parseMetadataBody(&entry, block[1:])
		return entry, true
	case keyword == "event", keyword == "query":
		entry.Kind = keyword
		if len(tokens) >= 4 {
			entry.Name = tokenStringValue(tokens[2])
			entry.Value = tokenStringValue(tokens[3])
		}
		p.parseMetadataBody(&entry, block[1:])
		return entry, true
	default:
		return BeanEntry{}, false
	}
}

func (p *beanLineParser) parseTransactionHead(entry *BeanEntry, tokens []beanToken) {
	stringsSeen := []string{}
	rest := []beanToken{}
	for _, token := range tokens {
		if token.Kind == beanTokenString {
			stringsSeen = append(stringsSeen, token.Value)
			continue
		}
		rest = append(rest, token)
	}
	switch len(stringsSeen) {
	case 0:
	case 1:
		entry.Narration = stringsSeen[0]
	default:
		entry.Payee = stringsSeen[0]
		entry.Narration = stringsSeen[1]
	}
	entry.Tags, entry.Links = parseTagsLinks(rest)
}

func (p *beanLineParser) parseTransactionBody(entry *BeanEntry, lines []BeanLine) {
	for _, line := range lines {
		trimmed := strings.TrimSpace(line.Text)
		if trimmed == "" || strings.HasPrefix(trimmed, ";") {
			continue
		}
		tokens := scanBeanLine(trimmed)
		if len(tokens) == 0 {
			continue
		}
		if key, value, ok := parseMetadataLine(tokens); ok {
			entry.Metadata[key] = value
			continue
		}
		tags, links := parseTagsLinks(tokens)
		if len(tags) > 0 || len(links) > 0 {
			entry.Tags = append(entry.Tags, tags...)
			entry.Links = append(entry.Links, links...)
			continue
		}
		if posting, ok := parsePostingTokens(tokens); ok {
			entry.Postings = append(entry.Postings, posting)
			continue
		}
		p.errors = append(p.errors, BeanParseError{File: line.File, Line: line.Line, Message: "unrecognized transaction body line"})
	}
}

func (p *beanLineParser) parseMetadataBody(entry *BeanEntry, lines []BeanLine) {
	for _, line := range lines {
		tokens := scanBeanLine(strings.TrimSpace(line.Text))
		if key, value, ok := parseMetadataLine(tokens); ok {
			entry.Metadata[key] = value
		}
	}
}

func parsePostingTokens(tokens []beanToken) (parsedPosting, bool) {
	if len(tokens) == 0 {
		return parsedPosting{}, false
	}
	i := 0
	flag := ""
	if isPostingFlag(tokens[i].Value) {
		flag = tokens[i].Value
		i++
	}
	if i >= len(tokens) || !isBeanAccount(tokens[i].Value) {
		return parsedPosting{}, false
	}
	posting := parsedPosting{Posting: Posting{Account: tokens[i].Value, Flag: flag}}
	i++
	if i >= len(tokens) {
		posting.Blank = true
		return posting, true
	}
	if amount, next, ok := parseBeanAmountTokens(tokens[i:]); ok {
		posting.Quantity = amount
		posting.Amount = amount.Cents()
		posting.Currency = amount.Currency
		i += next
	} else {
		posting.Blank = true
	}
	for i < len(tokens) {
		switch tokens[i].Value {
		case "{", "{{":
			amount, total, next, ok := parseCostTokens(tokens[i:])
			if ok {
				posting.Cost = amount
				posting.CostAmount = amount.Cents()
				posting.CostCurrency = amount.Currency
				posting.TotalCost = total
				i += next
				continue
			}
		case "@", "@@":
			total := tokens[i].Value == "@@"
			if amount, next, ok := parseBeanAmountTokens(tokens[i+1:]); ok {
				posting.Price = amount
				posting.PriceAmount = amount.Cents()
				posting.PriceCurrency = amount.Currency
				posting.TotalPrice = total
				i += 1 + next
				continue
			}
		}
		i++
	}
	return posting, true
}

func parseMetadataLine(tokens []beanToken) (string, MetadataValue, bool) {
	if len(tokens) == 0 || !strings.HasSuffix(tokens[0].Value, ":") {
		return "", nil, false
	}
	key := strings.TrimSuffix(tokens[0].Value, ":")
	if key == "" || !isLowerFirst(key) {
		return "", nil, false
	}
	if len(tokens) == 1 {
		return key, nil, true
	}
	return key, parseMetadataTokens(tokens[1:]), true
}

func parseMetadataTokens(tokens []beanToken) MetadataValue {
	if len(tokens) == 0 {
		return nil
	}
	if len(tokens) == 1 {
		token := tokens[0]
		switch token.Kind {
		case beanTokenString:
			return token.Value
		case beanTokenTag, beanTokenLink:
			return token.Value
		}
		switch token.Value {
		case "TRUE":
			return true
		case "FALSE":
			return false
		case "NULL":
			return nil
		}
		if isBeanDateToken(token.Value) {
			return normalizeBeanDate(token.Value)
		}
		if n, err := strconv.ParseFloat(strings.ReplaceAll(token.Value, ",", ""), 64); err == nil {
			return n
		}
		return token.Value
	}
	if amount, next, ok := parseBeanAmountTokens(tokens); ok && next == len(tokens) {
		return amount.String()
	}
	return strings.Join(beanTokenValues(tokens), " ")
}

func parseCustomValues(tokens []beanToken) []MetadataValue {
	values := make([]MetadataValue, 0, len(tokens))
	for i := 0; i < len(tokens); {
		if amount, next, ok := parseBeanAmountTokens(tokens[i:]); ok {
			values = append(values, amount.String())
			i += next
			continue
		}
		values = append(values, parseMetadataTokens(tokens[i:i+1]))
		i++
	}
	return values
}

func parseCurrencyList(tokens []beanToken) []string {
	out := []string{}
	for _, token := range tokens {
		if token.Value == "," || token.Kind == beanTokenString {
			continue
		}
		if isBeanCurrency(token.Value) {
			out = append(out, token.Value)
		}
	}
	return out
}

func parseTagsLinks(tokens []beanToken) ([]string, []string) {
	tags := []string{}
	links := []string{}
	for _, token := range tokens {
		switch token.Kind {
		case beanTokenTag:
			tags = append(tags, token.Value)
		case beanTokenLink:
			links = append(links, token.Value)
		}
	}
	return tags, links
}

func supportsBeanTags(kind string) bool {
	switch kind {
	case "transaction", "note", "document":
		return true
	default:
		return false
	}
}

func appendUniqueString(values []string, value string) []string {
	if value == "" {
		return values
	}
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func removeString(values []string, value string) []string {
	out := values[:0]
	for _, existing := range values {
		if existing != value {
			out = append(out, existing)
		}
	}
	return out
}

func tokenStringValue(token beanToken) string {
	return token.Value
}

func isKnownGlobalDirective(value string) bool {
	switch value {
	case "option", "include", "plugin", "pushtag", "poptag", "pushmeta", "popmeta":
		return true
	default:
		return false
	}
}

func validateBeanEntries(entries []BeanEntry) []BeanParseError {
	errors := []BeanParseError{}
	activeTags := map[string]bool{}
	activeMeta := map[string]bool{}
	for _, entry := range entries {
		switch entry.Kind {
		case "pushtag":
			for _, tag := range entry.Tags {
				activeTags[tag] = true
			}
		case "poptag":
			for _, tag := range entry.Tags {
				if !activeTags[tag] {
					errors = append(errors, BeanParseError{File: entry.File, Line: entry.Line, Message: "poptag without matching pushtag: " + tag})
					continue
				}
				delete(activeTags, tag)
			}
		case "pushmeta":
			for key := range entry.Metadata {
				activeMeta[key] = true
			}
		case "popmeta":
			if !activeMeta[entry.Name] {
				errors = append(errors, BeanParseError{File: entry.File, Line: entry.Line, Message: "popmeta without matching pushmeta: " + entry.Name})
				continue
			}
			delete(activeMeta, entry.Name)
		case "transaction":
			errors = append(errors, validateBeanTransaction(entry)...)
		}
	}
	return errors
}

func validateBeanTransaction(entry BeanEntry) []BeanParseError {
	blankCount := 0
	totals := map[string]int{}
	for _, posting := range entry.Postings {
		if posting.Blank {
			blankCount++
			continue
		}
		amount, currency := beanPostingBalanceAmount(posting)
		if currency == "" {
			continue
		}
		totals[currency] += amount
	}
	if blankCount > 1 {
		return []BeanParseError{{File: entry.File, Line: entry.Line, Message: "transaction has more than one incomplete posting"}}
	}
	if blankCount == 1 {
		nonzero := 0
		for _, total := range totals {
			if total != 0 {
				nonzero++
			}
		}
		if nonzero > 1 {
			return []BeanParseError{{File: entry.File, Line: entry.Line, Message: "cannot infer incomplete posting across multiple currencies"}}
		}
		return nil
	}
	for currency, total := range totals {
		if total != 0 {
			return []BeanParseError{{File: entry.File, Line: entry.Line, Message: "transaction is not balanced in " + currency}}
		}
	}
	return nil
}

func beanPostingBalanceAmount(posting parsedPosting) (int, string) {
	switch {
	case posting.TotalCost && posting.CostCurrency != "":
		return posting.CostAmount, posting.CostCurrency
	case posting.CostAmount != 0 && posting.CostCurrency != "":
		return int(math.Round(float64(posting.Amount) * float64(posting.CostAmount) / 100)), posting.CostCurrency
	case posting.TotalPrice && posting.PriceCurrency != "":
		return posting.PriceAmount, posting.PriceCurrency
	case posting.PriceAmount != 0 && posting.PriceCurrency != "":
		return int(math.Round(float64(posting.Amount) * float64(posting.PriceAmount) / 100)), posting.PriceCurrency
	default:
		return posting.Amount, posting.Currency
	}
}

func parseAmountTokens(tokens []beanToken) (int, string, int, bool) {
	amount, next, ok := parseBeanAmountTokens(tokens)
	if !ok {
		return 0, "", 0, false
	}
	return amount.Cents(), amount.Currency, next, true
}

func parseBeanAmountTokens(tokens []beanToken) (BeanAmount, int, bool) {
	for i := 1; i <= len(tokens); i++ {
		currency := tokens[i-1].Value
		if !isBeanCurrency(currency) {
			continue
		}
		value, ok := evalNumberExpressionRat(tokens[:i-1])
		if !ok {
			continue
		}
		number := ratDecimalString(value)
		if direct, ok := directNumberText(tokens[:i-1]); ok {
			number = direct
		}
		return BeanAmount{Number: number, Currency: currency}, i, true
	}
	return BeanAmount{}, 0, false
}

func parseBalanceAmountTokens(tokens []beanToken) (int, string, int, bool) {
	amount, _, next, ok := parseBalanceBeanAmountTokens(tokens)
	if !ok {
		return 0, "", 0, false
	}
	return amount.Cents(), amount.Currency, next, true
}

func parseBalanceBeanAmountTokens(tokens []beanToken) (BeanAmount, string, int, bool) {
	for i, token := range tokens {
		if token.Value != "~" {
			continue
		}
		if i == 0 || len(tokens) < i+3 {
			return BeanAmount{}, "", 0, false
		}
		value, ok := evalNumberExpressionRat(tokens[:i])
		if !ok {
			return BeanAmount{}, "", 0, false
		}
		for j := i + 1; j < len(tokens); j++ {
			if isBeanCurrency(tokens[j].Value) {
				tolerance := ""
				if toleranceValue, ok := evalNumberExpressionRat(tokens[i+1 : j]); ok {
					tolerance = ratDecimalString(toleranceValue)
					if direct, ok := directNumberText(tokens[i+1 : j]); ok {
						tolerance = direct
					}
				}
				number := ratDecimalString(value)
				if direct, ok := directNumberText(tokens[:i]); ok {
					number = direct
				}
				return BeanAmount{Number: number, Currency: tokens[j].Value}, tolerance, j + 1, true
			}
		}
		return BeanAmount{}, "", 0, false
	}
	amount, next, ok := parseBeanAmountTokens(tokens)
	return amount, "", next, ok
}

func parseCostTokens(tokens []beanToken) (BeanAmount, bool, int, bool) {
	if len(tokens) < 3 || (tokens[0].Value != "{" && tokens[0].Value != "{{") {
		return BeanAmount{}, false, 0, false
	}
	closeToken := "}"
	total := false
	if tokens[0].Value == "{{" {
		closeToken = "}}"
		total = true
	}
	end := -1
	for i := 1; i < len(tokens); i++ {
		if tokens[i].Value == closeToken {
			end = i
			break
		}
	}
	if end < 0 {
		return BeanAmount{}, false, 0, false
	}
	for start := 1; start < end; start++ {
		if amount, next, ok := parseBeanAmountTokens(tokens[start:end]); ok {
			return amount, total, start + next + 1, true
		}
	}
	return BeanAmount{}, total, end + 1, false
}

func directNumberText(tokens []beanToken) (string, bool) {
	if len(tokens) != 1 || tokens[0].Kind != beanTokenNumber {
		return "", false
	}
	return strings.ReplaceAll(tokens[0].Value, ",", ""), true
}

type numberExprParser struct {
	tokens []beanToken
	pos    int
}

func evalNumberExpression(tokens []beanToken) (float64, bool) {
	if len(tokens) == 0 {
		return 0, false
	}
	parser := numberExprParser{tokens: tokens}
	value, ok := parser.parseExpr()
	if !ok || parser.pos != len(tokens) {
		return 0, false
	}
	return value, true
}

type numberRatExprParser struct {
	tokens []beanToken
	pos    int
}

func evalNumberExpressionRat(tokens []beanToken) (*big.Rat, bool) {
	if len(tokens) == 0 {
		return nil, false
	}
	parser := numberRatExprParser{tokens: tokens}
	value, ok := parser.parseExpr()
	if !ok || parser.pos != len(tokens) {
		return nil, false
	}
	return value, true
}

func (p *numberRatExprParser) parseExpr() (*big.Rat, bool) {
	left, ok := p.parseTerm()
	if !ok {
		return nil, false
	}
	for p.pos < len(p.tokens) && (p.tokens[p.pos].Value == "+" || p.tokens[p.pos].Value == "-") {
		op := p.tokens[p.pos].Value
		p.pos++
		right, ok := p.parseTerm()
		if !ok {
			return nil, false
		}
		if op == "+" {
			left = new(big.Rat).Add(left, right)
		} else {
			left = new(big.Rat).Sub(left, right)
		}
	}
	return left, true
}

func (p *numberRatExprParser) parseTerm() (*big.Rat, bool) {
	left, ok := p.parseFactor()
	if !ok {
		return nil, false
	}
	for p.pos < len(p.tokens) && (p.tokens[p.pos].Value == "*" || p.tokens[p.pos].Value == "/") {
		op := p.tokens[p.pos].Value
		p.pos++
		right, ok := p.parseFactor()
		if !ok {
			return nil, false
		}
		if op == "*" {
			left = new(big.Rat).Mul(left, right)
		} else {
			if right.Sign() == 0 {
				return nil, false
			}
			left = new(big.Rat).Quo(left, right)
		}
	}
	return left, true
}

func (p *numberRatExprParser) parseFactor() (*big.Rat, bool) {
	if p.pos >= len(p.tokens) {
		return nil, false
	}
	token := p.tokens[p.pos]
	if token.Value == "+" || token.Value == "-" {
		p.pos++
		value, ok := p.parseFactor()
		if !ok {
			return nil, false
		}
		if token.Value == "-" {
			return new(big.Rat).Neg(value), true
		}
		return value, true
	}
	if token.Value == "(" {
		p.pos++
		value, ok := p.parseExpr()
		if !ok || p.pos >= len(p.tokens) || p.tokens[p.pos].Value != ")" {
			return nil, false
		}
		p.pos++
		return value, true
	}
	if token.Kind != beanTokenNumber && token.Kind != beanTokenWord {
		return nil, false
	}
	value, ok := decimalRat(token.Value)
	if !ok {
		return nil, false
	}
	p.pos++
	return value, true
}

func decimalRat(value string) (*big.Rat, bool) {
	value = strings.ReplaceAll(strings.TrimSpace(value), ",", "")
	if value == "" {
		return nil, false
	}
	rat := new(big.Rat)
	if _, ok := rat.SetString(value); !ok {
		return nil, false
	}
	return rat, true
}

func ratDecimalString(value *big.Rat) string {
	if value == nil {
		return ""
	}
	denominator := new(big.Int).Set(value.Denom())
	two := big.NewInt(2)
	five := big.NewInt(5)
	for new(big.Int).Mod(denominator, two).Sign() == 0 {
		denominator.Div(denominator, two)
	}
	for new(big.Int).Mod(denominator, five).Sign() == 0 {
		denominator.Div(denominator, five)
	}
	if denominator.Cmp(big.NewInt(1)) == 0 {
		for scale := 0; scale <= 18; scale++ {
			scaled := new(big.Rat).Mul(value, new(big.Rat).SetInt(pow10(scale)))
			if scaled.IsInt() {
				text := scaled.Num().String()
				negative := strings.HasPrefix(text, "-")
				if negative {
					text = strings.TrimPrefix(text, "-")
				}
				for len(text) <= scale {
					text = "0" + text
				}
				if scale > 0 {
					text = text[:len(text)-scale] + "." + text[len(text)-scale:]
					text = strings.TrimRight(strings.TrimRight(text, "0"), ".")
				}
				if text == "" {
					text = "0"
				}
				if negative && text != "0" {
					text = "-" + text
				}
				return text
			}
		}
	}
	return strings.TrimRight(strings.TrimRight(value.FloatString(18), "0"), ".")
}

func pow10(scale int) *big.Int {
	out := big.NewInt(1)
	ten := big.NewInt(10)
	for i := 0; i < scale; i++ {
		out.Mul(out, ten)
	}
	return out
}

func (p *numberExprParser) parseExpr() (float64, bool) {
	left, ok := p.parseTerm()
	if !ok {
		return 0, false
	}
	for p.pos < len(p.tokens) && (p.tokens[p.pos].Value == "+" || p.tokens[p.pos].Value == "-") {
		op := p.tokens[p.pos].Value
		p.pos++
		right, ok := p.parseTerm()
		if !ok {
			return 0, false
		}
		if op == "+" {
			left += right
		} else {
			left -= right
		}
	}
	return left, true
}

func (p *numberExprParser) parseTerm() (float64, bool) {
	left, ok := p.parseFactor()
	if !ok {
		return 0, false
	}
	for p.pos < len(p.tokens) && (p.tokens[p.pos].Value == "*" || p.tokens[p.pos].Value == "/") {
		op := p.tokens[p.pos].Value
		p.pos++
		right, ok := p.parseFactor()
		if !ok {
			return 0, false
		}
		if op == "*" {
			left *= right
		} else {
			left /= right
		}
	}
	return left, true
}

func (p *numberExprParser) parseFactor() (float64, bool) {
	if p.pos >= len(p.tokens) {
		return 0, false
	}
	token := p.tokens[p.pos]
	if token.Value == "+" || token.Value == "-" {
		p.pos++
		value, ok := p.parseFactor()
		if !ok {
			return 0, false
		}
		if token.Value == "-" {
			return -value, true
		}
		return value, true
	}
	if token.Value == "(" {
		p.pos++
		value, ok := p.parseExpr()
		if !ok || p.pos >= len(p.tokens) || p.tokens[p.pos].Value != ")" {
			return 0, false
		}
		p.pos++
		return value, true
	}
	if token.Kind != beanTokenNumber && token.Kind != beanTokenWord {
		return 0, false
	}
	n, err := strconv.ParseFloat(strings.ReplaceAll(token.Value, ",", ""), 64)
	if err != nil {
		return 0, false
	}
	p.pos++
	return n, true
}

func scanBeanLine(input string) []beanToken {
	tokens := []beanToken{}
	for i := 0; i < len(input); {
		r, size := utf8.DecodeRuneInString(input[i:])
		if unicode.IsSpace(r) {
			i += size
			continue
		}
		if r == ';' {
			break
		}
		if r == '"' {
			value, next := scanBeanString(input, i)
			tokens = append(tokens, beanToken{Kind: beanTokenString, Value: value})
			i = next
			continue
		}
		if r == '/' && i+size < len(input) {
			nextRune, _ := utf8.DecodeRuneInString(input[i+size:])
			if unicode.IsUpper(nextRune) || unicode.IsDigit(nextRune) {
				value, next := scanBeanSlashCurrency(input, i)
				tokens = append(tokens, beanToken{Kind: beanTokenWord, Value: value})
				i = next
				continue
			}
		}
		if strings.HasPrefix(input[i:], "@@") || strings.HasPrefix(input[i:], "{{") || strings.HasPrefix(input[i:], "}}") {
			tokens = append(tokens, beanToken{Kind: beanTokenPunct, Value: input[i : i+2]})
			i += 2
			continue
		}
		if strings.ContainsRune("{}(),~@*/", r) {
			tokens = append(tokens, beanToken{Kind: beanTokenPunct, Value: string(r)})
			i += size
			continue
		}
		if r == '#' {
			value, next := scanBeanSymbol(input, i+size)
			if value == "" {
				tokens = append(tokens, beanToken{Kind: beanTokenPunct, Value: "#"})
				i += size
			} else {
				tokens = append(tokens, beanToken{Kind: beanTokenTag, Value: value})
				i = next
			}
			continue
		}
		if r == '^' {
			value, next := scanBeanSymbol(input, i+size)
			if value == "" {
				tokens = append(tokens, beanToken{Kind: beanTokenPunct, Value: "^"})
				i += size
			} else {
				tokens = append(tokens, beanToken{Kind: beanTokenLink, Value: value})
				i = next
			}
			continue
		}
		if (r == '+' || r == '-') && i+size < len(input) {
			nextRune, _ := utf8.DecodeRuneInString(input[i+size:])
			if unicode.IsDigit(nextRune) {
				value, next := scanBeanWord(input, i)
				tokens = append(tokens, beanToken{Kind: beanNumberTokenKind(value), Value: value})
				i = next
				continue
			}
			tokens = append(tokens, beanToken{Kind: beanTokenPunct, Value: string(r)})
			i += size
			continue
		}
		value, next := scanBeanWord(input, i)
		tokens = append(tokens, beanToken{Kind: beanNumberTokenKind(value), Value: value})
		i = next
	}
	return tokens
}

func scanBeanString(input string, start int) (string, int) {
	var out strings.Builder
	for i := start + 1; i < len(input); {
		r, size := utf8.DecodeRuneInString(input[i:])
		if r == '"' {
			return out.String(), i + size
		}
		if r == '\\' && i+size < len(input) {
			next, nextSize := utf8.DecodeRuneInString(input[i+size:])
			switch next {
			case '"', '\\':
				out.WriteRune(next)
			case 'n':
				out.WriteRune('\n')
			case 't':
				out.WriteRune('\t')
			default:
				out.WriteRune(next)
			}
			i += size + nextSize
			continue
		}
		out.WriteRune(r)
		i += size
	}
	return out.String(), len(input)
}

func scanBeanSymbol(input string, start int) (string, int) {
	end := start
	for end < len(input) {
		r, size := utf8.DecodeRuneInString(input[end:])
		if unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("-_./", r) {
			end += size
			continue
		}
		break
	}
	return input[start:end], end
}

func scanBeanWord(input string, start int) (string, int) {
	end := start
	for end < len(input) {
		r, size := utf8.DecodeRuneInString(input[end:])
		if unicode.IsSpace(r) || strings.ContainsRune("{}(),~@*;\"^", r) {
			break
		}
		if r == '#' && end == start {
			break
		}
		end += size
	}
	return input[start:end], end
}

func scanBeanSlashCurrency(input string, start int) (string, int) {
	end := start
	for end < len(input) {
		r, size := utf8.DecodeRuneInString(input[end:])
		if unicode.IsUpper(r) || unicode.IsDigit(r) || strings.ContainsRune("/'._-", r) {
			end += size
			continue
		}
		break
	}
	return input[start:end], end
}

func beanNumberTokenKind(value string) beanTokenKind {
	if value == "+" || value == "-" {
		return beanTokenPunct
	}
	if _, err := strconv.ParseFloat(strings.ReplaceAll(value, ",", ""), 64); err == nil {
		return beanTokenNumber
	}
	return beanTokenWord
}

func isIndentedBeanLine(text string) bool {
	return strings.HasPrefix(text, " ") || strings.HasPrefix(text, "\t")
}

func isTransactionFlag(value string) bool {
	if value == "txn" || value == "*" || value == "#" {
		return true
	}
	return len(value) == 1 && strings.ContainsAny(value, "!&?%ABCDEFGHIJKLMNOPQRSTUVWXYZ")
}

func isPostingFlag(value string) bool {
	if value == "*" || value == "#" {
		return true
	}
	return len(value) == 1 && strings.ContainsAny(value, "!&?%ABCDEFGHIJKLMNOPQRSTUVWXYZ")
}

func isBeanDateToken(value string) bool {
	_, ok := parseBeanDate(value)
	return ok
}

func normalizeBeanDate(value string) string {
	if t, ok := parseBeanDate(value); ok {
		return t.Format("2006-01-02")
	}
	return strings.ReplaceAll(value, "/", "-")
}

func parseBeanDate(value string) (time.Time, bool) {
	value = strings.ReplaceAll(strings.TrimSpace(value), "/", "-")
	parts := strings.Split(value, "-")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	year, err1 := strconv.Atoi(parts[0])
	month, err2 := strconv.Atoi(parts[1])
	day, err3 := strconv.Atoi(parts[2])
	if err1 != nil || err2 != nil || err3 != nil || year < 1700 || year > 2099 {
		return time.Time{}, false
	}
	t := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	if t.Year() != year || int(t.Month()) != month || t.Day() != day {
		return time.Time{}, false
	}
	return t, true
}

func isBeanAccount(value string) bool {
	if !strings.Contains(value, ":") {
		return false
	}
	first, _, _ := strings.Cut(value, ":")
	r, _ := utf8.DecodeRuneInString(first)
	return unicode.IsUpper(r) || r >= utf8.RuneSelf
}

func isBeanCurrency(value string) bool {
	if value == "" || strings.Contains(value, ":") || strings.HasSuffix(value, ":") {
		return false
	}
	if strings.HasPrefix(value, "/") {
		hasLetter := false
		for _, r := range value[1:] {
			if unicode.IsLetter(r) {
				hasLetter = true
			}
			if !(unicode.IsUpper(r) || unicode.IsDigit(r) || strings.ContainsRune("'._-", r)) {
				return false
			}
		}
		return hasLetter
	}
	hasLetter := false
	for _, r := range value {
		if unicode.IsLetter(r) {
			hasLetter = true
		}
		if !(unicode.IsUpper(r) || unicode.IsDigit(r) || strings.ContainsRune("'._-", r)) {
			return false
		}
	}
	return hasLetter
}

func isLowerFirst(value string) bool {
	r, _ := utf8.DecodeRuneInString(value)
	return unicode.IsLower(r)
}

func beanTokenValues(tokens []beanToken) []string {
	values := make([]string, len(tokens))
	for i, token := range tokens {
		values[i] = token.Value
	}
	return values
}

func beanLineTexts(lines []BeanLine) []string {
	out := make([]string, len(lines))
	for i, line := range lines {
		out[i] = line.Text
	}
	return out
}

func linesBlock(lines []BeanLine) []BeanLine {
	out := make([]BeanLine, len(lines))
	copy(out, lines)
	return out
}

func (err BeanParseError) Error() string {
	if err.File == "" {
		return err.Message
	}
	return fmt.Sprintf("%s:%d: %s", err.File, err.Line, err.Message)
}
