package app

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

type validator interface {
	Validate() error
}

type LoginRequest struct {
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

type AIChatRequest struct {
	Message      string        `json:"message"`
	Messages     []ChatMessage `json:"messages"`
	DraftEntries []LedgerEntry `json:"draftEntries"`
	Stream       bool          `json:"stream"`
}

type AIAccountChatRequest struct {
	Message         string             `json:"message"`
	Messages        []ChatMessage      `json:"messages"`
	DraftOperations []AccountOperation `json:"draftOperations"`
	Stream          bool               `json:"stream"`
}

type ImportCommitRequest struct {
	ImportID string        `json:"importId"`
	Provider string        `json:"provider"`
	Entries  []ImportEntry `json:"entries"`
}

var (
	datePattern        = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	amountPattern      = regexp.MustCompile(`^-?\d+(\.\d{1,2})?$`)
	accountNamePattern = regexp.MustCompile(`^(Assets|Liabilities|Equity|Income|Expenses)(:[A-Za-z0-9][A-Za-z0-9_-]*)+$`)
	currencyPattern    = regexp.MustCompile(`^` + commodityPattern + `$`)
	tagPattern         = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	metadataKeyPattern = regexp.MustCompile(`^[a-z][a-zA-Z0-9_-]*$`)
)

func (r LoginRequest) Validate() error {
	if strings.TrimSpace(r.Password) == "" {
		return fmt.Errorf("password is required")
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

func (r AIChatRequest) Validate() error {
	if strings.TrimSpace(r.Message) == "" {
		return fmt.Errorf("message is required")
	}
	for i, entry := range r.DraftEntries {
		if err := entry.Validate(); err != nil {
			return fmt.Errorf("draftEntries[%d]: %w", i, err)
		}
	}
	return nil
}

func (r AIAccountChatRequest) Validate() error {
	if strings.TrimSpace(r.Message) == "" {
		return fmt.Errorf("message is required")
	}
	for i, operation := range r.DraftOperations {
		if err := operation.Validate(); err != nil {
			return fmt.Errorf("draftOperations[%d]: %w", i, err)
		}
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
		for key := range e.Metadata {
			if !metadataKeyPattern.MatchString(key) {
				return fmt.Errorf("metadata key %q is invalid", key)
			}
		}
		for _, tag := range e.Tags {
			if !tagPattern.MatchString(tag) {
				return fmt.Errorf("tag %q is invalid", tag)
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
	if err := validateAmount("amount", p.Amount); err != nil {
		return err
	}
	if err := validateCurrency("currency", p.Currency); err != nil {
		return err
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
	if !amountPattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("%s must be a decimal amount with at most two places", field)
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
