package app

import (
	"math/big"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

// These aliases preserve the app package contract while parsing lives in the
// infrastructure-free ledgercore package.
type BeanLine = ledgercore.BeanLine
type Posting = ledgercore.Posting
type parsedPosting = ledgercore.ParsedPosting
type BeanParseError = ledgercore.BeanParseError
type BeanEntry = ledgercore.BeanEntry
type BeanParseResult = ledgercore.BeanParseResult
type beanToken = ledgercore.Token

const (
	beanTokenWord   = ledgercore.TokenWord
	beanTokenString = ledgercore.TokenString
	beanTokenNumber = ledgercore.TokenNumber
	beanTokenTag    = ledgercore.TokenTag
	beanTokenLink   = ledgercore.TokenLink
	beanTokenPunct  = ledgercore.TokenPunct
)

func ParseBeanLines(lines []BeanLine) BeanParseResult {
	return ledgercore.ParseLines(lines)
}

func CompileBeanLines(lines []BeanLine) BeanParseResult {
	return ledgercore.CompileLines(lines)
}

func parsePostingTokens(tokens []beanToken) (parsedPosting, bool) {
	return ledgercore.ParsePostingTokens(tokens)
}

func parseMetadataLine(tokens []beanToken) (string, MetadataValue, bool) {
	return ledgercore.ParseMetadataLine(tokens)
}

func parseBeanAmountTokens(tokens []beanToken) (BeanAmount, int, bool) {
	return ledgercore.ParseBeanAmountTokens(tokens)
}

func parseCostTokenSpan(tokens []beanToken) (bool, int, bool) {
	return ledgercore.ParseCostTokenSpan(tokens)
}

func directNumberText(tokens []beanToken) (string, bool) {
	return ledgercore.DirectNumberText(tokens)
}

func evalNumberExpressionRat(tokens []beanToken) (*big.Rat, bool) {
	return ledgercore.EvalNumberExpressionRat(tokens)
}

func scanBeanLine(input string) []beanToken {
	return ledgercore.ScanBeanLine(input)
}

func isIndentedBeanLine(text string) bool {
	return ledgercore.IsIndentedBeanLine(text)
}

func isTransactionFlag(value string) bool {
	return ledgercore.IsTransactionFlag(value)
}

func isPostingFlag(value string) bool {
	return ledgercore.IsPostingFlag(value)
}

func isBeanDateToken(value string) bool {
	return ledgercore.IsBeanDateToken(value)
}

func isBeanAccount(value string) bool {
	return ledgercore.IsBeanAccount(value)
}

func isBeanCurrency(value string) bool {
	return ledgercore.IsBeanCurrency(value)
}
