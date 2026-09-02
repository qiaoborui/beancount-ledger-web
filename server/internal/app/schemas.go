package app

import (
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

type validator interface {
	Validate() error
}

type LoginRequest struct {
	Password string `json:"password"`
}

type QuickUnlockRegisterRequest struct {
	DeviceID string `json:"deviceId"`
	Name     string `json:"name"`
	Mode     string `json:"mode"`
}

type QuickUnlockVerifyRequest struct {
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

type QuickUnlockRevokeRequest struct {
	DeviceID string `json:"deviceId"`
}

type PasskeyRenameRequest struct {
	Name string `json:"name"`
}

type PasskeyDeleteRequest struct {
	Password string `json:"password"`
}

type ReverseTransactionRequest struct {
	Source TransactionSource `json:"source"`
	Date   string            `json:"date"`
}

type UpdateTransactionRequest struct {
	Source TransactionSource `json:"source"`
	Entry  LedgerEntry       `json:"entry"`
}

type AddTransactionTagsRequest struct {
	Sources []TransactionSource `json:"sources"`
	Tags    []string            `json:"tags"`
}

type DeleteTransactionRequest struct {
	Source TransactionSource `json:"source"`
	Reason string            `json:"reason"`
}

type ReconcileRequest struct {
	Account        string `json:"account"`
	ActualAmount   string `json:"actualAmount"`
	BalanceDate    string `json:"balanceDate"`
	AdjustmentDate string `json:"adjustmentDate"`
}

type AppendBatchRequest struct {
	Entries []LedgerEntry `json:"entries"`
}

type AccountOperationsRequest struct {
	Operations []AccountOperation `json:"operations"`
}

type GitCommitRequest struct {
	Message string `json:"message"`
}

type AIParseRequest struct {
	Input string `json:"input"`
}

type ImportCommitRequest struct {
	ImportID string        `json:"importId"`
	Provider string        `json:"provider"`
	Entries  []ImportEntry `json:"entries"`
}

var (
	datePattern        = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	deviceIDPattern    = regexp.MustCompile(`^[A-Za-z0-9_-]{8,96}$`)
	accountNamePattern = regexp.MustCompile(`^(Assets|Liabilities|Equity|Income|Expenses)(:[A-Za-z0-9][A-Za-z0-9_-]*)+$`)
	currencyPattern    = regexp.MustCompile(`^` + commodityPattern + `$`)
	tagPattern         = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	metadataKeyPattern = regexp.MustCompile(`^[a-z][a-zA-Z0-9_-]*$`)
	decimal2Re         = regexp.MustCompile(`^-?\d+(\.\d{1,2})?$`)
	decimal6Re         = regexp.MustCompile(`^-?\d+(\.\d{1,6})?$`)
	beanDecimalRe      = regexp.MustCompile(`^[+-]?\d+(\.\d*)?$`)
)

const (
	maxTransactionTags = 50
	maxTagLength       = 64
)

func (r LoginRequest) Validate() error {
	if strings.TrimSpace(r.Password) == "" {
		return fmt.Errorf("password is required")
	}
	return nil
}

func (r QuickUnlockRegisterRequest) Validate() error {
	if r.DeviceID != "" && !deviceIDPattern.MatchString(r.DeviceID) {
		return fmt.Errorf("deviceId is invalid")
	}
	switch r.Mode {
	case "numeric", "text":
	default:
		return fmt.Errorf("mode is invalid")
	}
	if len(strings.TrimSpace(r.Name)) > 80 {
		return fmt.Errorf("name is too long")
	}
	return nil
}

func (r QuickUnlockVerifyRequest) Validate() error {
	if !deviceIDPattern.MatchString(r.DeviceID) {
		return fmt.Errorf("deviceId is invalid")
	}
	if strings.TrimSpace(r.Token) == "" {
		return fmt.Errorf("token is required")
	}
	return nil
}

func (r QuickUnlockRevokeRequest) Validate() error {
	if !deviceIDPattern.MatchString(r.DeviceID) {
		return fmt.Errorf("deviceId is invalid")
	}
	return nil
}

func (r PasskeyRenameRequest) Validate() error {
	name := strings.TrimSpace(r.Name)
	if name == "" {
		return fmt.Errorf("name is required")
	}
	if utf8.RuneCountInString(name) > 64 {
		return fmt.Errorf("name is too long")
	}
	return nil
}

func (r PasskeyDeleteRequest) Validate() error {
	if strings.TrimSpace(r.Password) == "" {
		return fmt.Errorf("password is required")
	}
	if len(r.Password) > 1024 {
		return fmt.Errorf("password is too long")
	}
	return nil
}

func (r ReverseTransactionRequest) Validate() error {
	if err := r.Source.Validate(); err != nil {
		return err
	}
	if r.Date != "" {
		return validateDate("date", r.Date)
	}
	return nil
}

func (r UpdateTransactionRequest) Validate() error {
	if err := r.Source.Validate(); err != nil {
		return err
	}
	return r.Entry.Validate()
}

func (r AddTransactionTagsRequest) Validate() error {
	if len(r.Sources) == 0 {
		return fmt.Errorf("sources is required")
	}
	if len(r.Sources) > 200 {
		return fmt.Errorf("sources must contain at most 200 transactions")
	}
	for i, source := range r.Sources {
		if err := source.Validate(); err != nil {
			return fmt.Errorf("sources[%d]: %w", i, err)
		}
		if strings.TrimSpace(source.Hash) == "" {
			return fmt.Errorf("sources[%d].hash is required", i)
		}
	}
	if len(r.Tags) == 0 {
		return fmt.Errorf("tags is required")
	}
	if len(r.Tags) > maxTransactionTags {
		return fmt.Errorf("tags must contain at most %d values", maxTransactionTags)
	}
	for i, tag := range r.Tags {
		tag = strings.TrimPrefix(strings.TrimSpace(tag), "#")
		if len(tag) > maxTagLength || !tagPattern.MatchString(tag) {
			return fmt.Errorf("tags[%d] is invalid", i)
		}
	}
	return nil
}

func (r DeleteTransactionRequest) Validate() error {
	return r.Source.Validate()
}

func (r ReconcileRequest) Validate() error {
	if err := validateAccount("account", r.Account); err != nil {
		return err
	}
	if err := validateAmount("actualAmount", r.ActualAmount); err != nil {
		return err
	}
	if err := validateDate("balanceDate", r.BalanceDate); err != nil {
		return err
	}
	if r.AdjustmentDate != "" {
		return validateDate("adjustmentDate", r.AdjustmentDate)
	}
	return nil
}

func (r AppendBatchRequest) Validate() error {
	if len(r.Entries) == 0 {
		return fmt.Errorf("entries is required")
	}
	for i, entry := range r.Entries {
		if err := entry.Validate(); err != nil {
			return fmt.Errorf("entries[%d]: %w", i, err)
		}
	}
	return nil
}

func (r AccountOperationsRequest) Validate() error {
	if len(r.Operations) == 0 {
		return fmt.Errorf("operations is required")
	}
	for i, operation := range r.Operations {
		if err := operation.Validate(); err != nil {
			return fmt.Errorf("operations[%d]: %w", i, err)
		}
	}
	return nil
}

func (r AIParseRequest) Validate() error {
	if strings.TrimSpace(r.Input) == "" {
		return fmt.Errorf("input is required")
	}
	return nil
}

func (r ImportCommitRequest) Validate() error {
	if strings.TrimSpace(r.ImportID) == "" {
		return fmt.Errorf("importId is required")
	}
	if strings.TrimSpace(r.Provider) == "" {
		return fmt.Errorf("provider is required")
	}
	for i, entry := range r.Entries {
		if err := entry.Validate(); err != nil {
			return fmt.Errorf("entries[%d]: %w", i, err)
		}
	}
	return nil
}

func (i AccountInput) Validate() error {
	if err := validateDate("date", i.Date); err != nil {
		return err
	}
	if err := validateAccount("account", i.Account); err != nil {
		return err
	}
	if i.Currency != "" {
		if err := validateCurrency("currency", i.Currency); err != nil {
			return err
		}
	}
	return nil
}

func (o AccountOperation) Validate() error {
	switch o.Kind {
	case "create", "update", "disable":
	default:
		return fmt.Errorf("kind must be create, update, or disable")
	}
	if err := validateDate("date", o.Date); err != nil {
		return err
	}
	if err := validateAccount("account", o.Account); err != nil {
		return err
	}
	if o.Currency != "" {
		if err := validateCurrency("currency", o.Currency); err != nil {
			return err
		}
	}
	if o.Group != "" && normalizeGroup(o.Group) == "" {
		return fmt.Errorf("group is not supported")
	}
	if o.Kind == "update" && strings.TrimSpace(o.Alias) == "" && strings.TrimSpace(o.Group) == "" {
		return fmt.Errorf("update requires alias or group")
	}
	return nil
}

func (e LedgerEntry) Validate() error {
	switch e.Kind {
	case "transaction":
		if err := validateDate("date", e.Date); err != nil {
			return err
		}
		if strings.TrimSpace(e.Payee) == "" {
			return fmt.Errorf("payee is required")
		}
		if e.Flag != "" && !isTransactionFlag(e.Flag) {
			return fmt.Errorf("flag is invalid")
		}
		for key := range e.Metadata {
			if !metadataKeyPattern.MatchString(key) {
				return fmt.Errorf("metadata key %q is invalid", key)
			}
		}
		if len(e.Tags) > maxTransactionTags {
			return fmt.Errorf("tags must contain at most %d values", maxTransactionTags)
		}
		for _, tag := range e.Tags {
			if !tagPattern.MatchString(tag) {
				return fmt.Errorf("tag %q is invalid", tag)
			}
		}
		for _, link := range e.Links {
			if !tagPattern.MatchString(link) {
				return fmt.Errorf("link %q is invalid", link)
			}
		}
		if len(e.Postings) < 2 {
			return fmt.Errorf("postings must contain at least two rows")
		}
		for i, posting := range e.Postings {
			if err := posting.Validate(); err != nil {
				return fmt.Errorf("postings[%d]: %w", i, err)
			}
		}
		if e.Confidence < 0 || e.Confidence > 1 {
			return fmt.Errorf("confidence must be between 0 and 1")
		}
	case "balance":
		if err := validateDate("date", e.Date); err != nil {
			return err
		}
		if err := validateAccount("account", e.Account); err != nil {
			return err
		}
		if err := validateAmount("amount", e.Amount); err != nil {
			return err
		}
		if err := validateCurrency("currency", e.Currency); err != nil {
			return err
		}
	default:
		return fmt.Errorf("kind must be transaction or balance")
	}
	return nil
}

func (p EntryPosting) Validate() error {
	if err := validateAccount("account", p.Account); err != nil {
		return err
	}
	if p.Flag != "" && !isPostingFlag(p.Flag) {
		return fmt.Errorf("flag is invalid")
	}
	if p.Amount == "" || p.Currency == "" {
		if p.Amount != "" || p.Currency != "" {
			return fmt.Errorf("amount and currency must be provided together")
		}
	} else {
		if err := validateBeanDecimal("amount", p.Amount); err != nil {
			return err
		}
		if err := validateCurrency("currency", p.Currency); err != nil {
			return err
		}
	}
	if p.CostSpec != "" {
		if err := validateCostSpec(p.CostSpec); err != nil {
			return err
		}
	} else if p.CostAmount != "" || p.CostCurrency != "" {
		if p.CostAmount == "" || p.CostCurrency == "" {
			return fmt.Errorf("costAmount and costCurrency must be provided together")
		}
		if p.CostKind != "" && p.CostKind != "unit" && p.CostKind != "total" {
			return fmt.Errorf("costKind must be unit or total")
		}
		if err := validateBeanDecimal("costAmount", p.CostAmount); err != nil {
			return err
		}
		if err := validateCurrency("costCurrency", p.CostCurrency); err != nil {
			return err
		}
	}
	if p.PriceAmount != "" || p.PriceCurrency != "" {
		if p.PriceAmount == "" || p.PriceCurrency == "" {
			return fmt.Errorf("priceAmount and priceCurrency must be provided together")
		}
		if p.PriceKind != "" && p.PriceKind != "unit" && p.PriceKind != "total" {
			return fmt.Errorf("priceKind must be unit or total")
		}
		if err := validateBeanDecimal("priceAmount", p.PriceAmount); err != nil {
			return err
		}
		if err := validateCurrency("priceCurrency", p.PriceCurrency); err != nil {
			return err
		}
	}
	return nil
}

func validateCostSpec(value string) error {
	value = strings.TrimSpace(value)
	if len(value) > 512 || strings.ContainsAny(value, "\r\n") || hasBeanComment(value) {
		return fmt.Errorf("costSpec is invalid")
	}
	tokens := scanBeanLine(value)
	total, next, ok := parseCostTokenSpan(tokens)
	if !ok || next != len(tokens) {
		return fmt.Errorf("costSpec is invalid")
	}
	if !validCostSpecComponents(tokens[1:len(tokens)-1], total) {
		return fmt.Errorf("costSpec is invalid")
	}
	return nil
}

func validCostSpecComponents(tokens []beanToken, total bool) bool {
	if len(tokens) == 0 {
		return true
	}
	components := [][]beanToken{{}}
	for _, token := range tokens {
		if token.Value == "," {
			if len(components[len(components)-1]) == 0 {
				return false
			}
			components = append(components, []beanToken{})
			continue
		}
		components[len(components)-1] = append(components[len(components)-1], token)
	}
	if len(components[len(components)-1]) == 0 {
		return false
	}
	seenAmount, seenCurrency, seenDate, seenLabel := false, false, false, false
	for _, component := range components {
		switch {
		case len(component) == 1 && component[0].Kind == beanTokenString:
			if seenLabel {
				return false
			}
			seenLabel = true
		case len(component) == 1 && isBeanDateToken(component[0].Value):
			if seenDate {
				return false
			}
			seenDate = true
		case len(component) == 1 && isCostCurrency(component[0].Value):
			if seenCurrency || seenAmount {
				return false
			}
			seenCurrency = true
		case isCompleteBeanAmount(component) || isCompleteNumberExpression(component) || (!total && isCompoundCostAmount(component)):
			if seenAmount || seenCurrency {
				return false
			}
			seenAmount = true
		default:
			return false
		}
	}
	return true
}

func isCompleteBeanAmount(tokens []beanToken) bool {
	amount, next, ok := parseBeanAmountTokens(tokens)
	return ok && next == len(tokens) && isCostCurrency(amount.Currency)
}

func isCostCurrency(value string) bool {
	if !isBeanCurrency(value) {
		return false
	}
	switch value {
	case "NULL", "TRUE", "FALSE":
		return false
	default:
		return true
	}
}

func isCompleteNumberExpression(tokens []beanToken) bool {
	_, ok := evalNumberExpressionRat(tokens)
	return ok
}

func isCompoundCostAmount(tokens []beanToken) bool {
	separator := -1
	for index, token := range tokens {
		if token.Value != "#" {
			continue
		}
		if separator >= 0 {
			return false
		}
		separator = index
	}
	if separator < 0 || separator >= len(tokens)-1 {
		return false
	}
	if separator > 0 {
		if _, ok := evalNumberExpressionRat(tokens[:separator]); !ok {
			return false
		}
	}
	return isCompleteBeanAmount(tokens[separator+1:])
}

func validateBeanDecimal(field, value string) error {
	value = strings.TrimSpace(value)
	if len(value) > 128 || !beanDecimalRe.MatchString(value) {
		return fmt.Errorf("%s must be a decimal number", field)
	}
	return nil
}

func (s TransactionSource) Validate() error {
	if strings.TrimSpace(s.File) == "" {
		return fmt.Errorf("source.file is required")
	}
	if s.Line <= 0 && strings.TrimSpace(s.Hash) == "" {
		return fmt.Errorf("source.line or source.hash is required")
	}
	return nil
}

func (e ImportEntry) Validate() error {
	if err := validateDate("date", e.Date); err != nil {
		return err
	}
	if err := validateAccount("categoryAccount", e.CategoryAccount); err != nil {
		return err
	}
	if err := validateAccount("fundingAccount", e.FundingAccount); err != nil {
		return err
	}
	if err := validateCurrency("currency", e.Currency); err != nil {
		return err
	}
	if len(e.Tags) > maxTransactionTags {
		return fmt.Errorf("tags must contain at most %d values", maxTransactionTags)
	}
	for i, tag := range e.Tags {
		tag = strings.TrimPrefix(strings.TrimSpace(tag), "#")
		if len(tag) > maxTagLength || !tagPattern.MatchString(tag) {
			return fmt.Errorf("tags[%d] is invalid", i)
		}
	}
	return nil
}

func validateDate(field, value string) error {
	if !datePattern.MatchString(value) {
		return fmt.Errorf("%s must use YYYY-MM-DD", field)
	}
	if _, err := time.Parse("2006-01-02", value); err != nil {
		return fmt.Errorf("%s is not a valid date", field)
	}
	return nil
}

func validateAmount(field, value string) error {
	return validateDecimalAmount(field, value, 2)
}

func validateDecimalAmount(field, value string, places int) error {
	var pattern *regexp.Regexp
	switch places {
	case 2:
		pattern = decimal2Re
	case 6:
		pattern = decimal6Re
	default:
		pattern = regexp.MustCompile(fmt.Sprintf(`^-?\d+(\.\d{1,%d})?$`, places))
	}
	if !pattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("%s must be a decimal amount with at most %d places", field, places)
	}
	return nil
}

func validateAccount(field, value string) error {
	if !accountNamePattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("%s is not a valid account", field)
	}
	return nil
}

func validateCurrency(field, value string) error {
	if !currencyPattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("%s is not a valid commodity", field)
	}
	return nil
}

func validateKnownCurrency(field, value string, commodities []string) error {
	if err := validateCurrency(field, value); err != nil {
		return err
	}
	for _, commodity := range commodities {
		if commodity == value {
			return nil
		}
	}
	return fmt.Errorf("%s commodity %s is not defined in ledger", field, value)
}
