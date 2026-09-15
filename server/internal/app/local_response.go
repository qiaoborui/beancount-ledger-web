package app

import (
	"reflect"
	"strings"
)

// Swift's required collection fields decode [] and {}. Go's nil collections
// encode as null, so use the endpoint's existing model to normalize collections
// only at the local boundary. Optional pointers and BQL null cells remain null.
func normalizeLocalResponseCollections(payload any, path string) any {
	var model any
	switch path {
	case "/api/ledger/bootstrap":
		model = BootstrapResult{}
	case "/api/ledger/summary":
		model = SummaryQueryResult{}
	case "/api/ledger/transactions":
		model = TransactionQueryResult{}
	case "/api/ledger/income-statement":
		model = IncomeStatementQueryResult{}
	case "/api/ledger/dashboard":
		model = DashboardSummary{}
	case "/api/ledger/home-report":
		model = HomeReport{}
	case "/api/ledger/investments":
		model = InvestmentSummary{}
	case "/api/ledger/accounts/detail":
		model = AccountDetailResult{}
	case "/api/ledger/entries":
		model = BeanLoadResult{}
	case "/api/ledger/bql":
		model = BQLResult{}
	default:
		model = localCollectionEnvelope{}
	}
	return normalizeLocalCollectionValue(payload, reflect.TypeOf(model))
}

// The remaining handlers return JSON envelopes rather than named models.
// Normalize only keys present in their response; this type does not add fields.
type localCollectionEnvelope struct {
	Accounts       []Account              `json:"accounts"`
	Statuses       []AccountStatus        `json:"statuses"`
	Rows           []ReconciliationRow    `json:"rows"`
	Assertions     []BalanceAssertion     `json:"assertions"`
	Balances       map[string]int         `json:"balances"`
	Notifications  []StoredNotification   `json:"notifications"`
	Insights       []Insight              `json:"insights"`
	Records        []BQLHistoryRecord     `json:"records"`
	Providers      []importProviderOption `json:"providers"`
	Documents      []ImportDocument       `json:"documents"`
	Files          []LedgerEditorFile     `json:"files"`
	Entries        []ImportEntry          `json:"entries"`
	AccountOptions []ginH                 `json:"accountOptions"`
	Warnings       []string               `json:"warnings"`
	BeanTexts      []string               `json:"beanTexts"`
	Entry          *LedgerEntry           `json:"entry"`
}

func normalizeLocalCollectionValue(value any, model reflect.Type) any {
	for model.Kind() == reflect.Pointer {
		if value == nil {
			return nil
		}
		model = model.Elem()
	}
	switch model.Kind() {
	case reflect.Slice, reflect.Array:
		if model.Elem().Kind() == reflect.Uint8 {
			return value
		}
		if value == nil {
			return []any{}
		}
		if values, ok := value.([]any); ok {
			for index, child := range values {
				values[index] = normalizeLocalCollectionValue(child, model.Elem())
			}
		}
	case reflect.Map:
		if value == nil {
			return map[string]any{}
		}
		if values, ok := value.(map[string]any); ok {
			for key, child := range values {
				values[key] = normalizeLocalCollectionValue(child, model.Elem())
			}
		}
	case reflect.Struct:
		values, ok := value.(map[string]any)
		if !ok {
			return value
		}
		for index := 0; index < model.NumField(); index++ {
			field := model.Field(index)
			if !field.IsExported() {
				continue
			}
			name := strings.Split(field.Tag.Get("json"), ",")[0]
			if name == "-" {
				continue
			}
			if field.Anonymous && name == "" {
				normalizeLocalCollectionValue(values, field.Type)
				continue
			}
			if name == "" {
				name = field.Name
			}
			if child, exists := values[name]; exists {
				values[name] = normalizeLocalCollectionValue(child, field.Type)
			}
		}
	}
	return value
}
