package app

import (
	"context"
	"encoding/json"
	"strings"
)

// Local defaults use accounts already present in the user's ledger. The import
// preview exposes every mapping for the user to inspect and edit. A ledger's
// own YAML configuration always takes precedence over these defaults.
func (s *Server) localDefaultImportConfig(path string) ([]byte, bool, error) {
	provider := map[string]string{
		"imports/alipay-config.yaml":             "alipay",
		"imports/wechat-config.yaml":             "wechat",
		"imports/cmb-checking-config.yaml":       "cmb-checking",
		"imports/cmb-credit-card-config.yaml":    "cmb",
		"imports/ccb-credit-card-config.yaml":    "ccb-credit",
		"imports/hsbchk-credit-card-config.yaml": "hsbchk-credit",
	}[path]
	if provider == "" {
		return nil, false, nil
	}
	snapshot, err := s.ledgerSnapshotLite(context.Background())
	if err != nil {
		return nil, true, err
	}
	account := func(preferred, prefix string) string {
		for _, item := range snapshot.Accounts {
			if item.Active && item.Account == preferred {
				return preferred
			}
		}
		for _, item := range snapshot.Accounts {
			if item.Active && strings.HasPrefix(item.Account, prefix) {
				return item.Account
			}
		}
		return preferred
	}
	expense := account("Expenses:Other", "Expenses:")
	income := account("Income:Salary", "Income:")
	cash := account("Assets:Bank", "Assets:")
	credit := account("Liabilities:CreditCard", "Liabilities:")
	currency := snapshot.OptionsMap["operating_currency"]
	if currency == "" {
		currency = "CNY"
	}
	minus, plus := income, expense
	if provider == "cmb-checking" {
		minus, plus = expense, income
	}
	if provider == "cmb" || provider == "ccb-credit" || provider == "hsbchk-credit" {
		minus, plus, cash = expense, expense, credit
	}
	config := map[string]any{
		"title": "本地账单导入", "defaultCurrency": currency,
		"defaultMinusAccount": minus, "defaultPlusAccount": plus, "defaultCashAccount": cash,
		"alipay":           map[string]any{"rules": []any{map[string]any{"methodAccount": cash}}},
		"wechat":           map[string]any{"rules": []any{map[string]any{"methodAccount": cash}}},
		"alipaySmallPurse": map[string]any{"cashAccount": cash, "sharedExpenseSplit": false},
	}
	encoded, err := json.Marshal(config)
	return encoded, true, err
}
