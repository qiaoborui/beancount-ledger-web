package app

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalEmptyLedgerRequiredCollections(t *testing.T) {
	input := localTestRequest(t)
	mustWrite(t, filepath.Join(input.WorkspaceRoot, "main.bean"), "option \"operating_currency\" \"CNY\"\n1970-01-01 open Assets:Cash CNY\n")
	for _, test := range []struct {
		path   string
		arrays []string
	}{
		{"bootstrap", []string{"accountBalances", "netWorthHistory", "monthEndNetWorth", "creditCards", "transactions", "reconciliationRows", "accounts", "commodities", "prices", "accountStatuses", "incomeStatement.income", "incomeStatement.expense", "incomeStatement.expenseAnalytics", "incomeStatement.topPayees", "incomeStatement.topPaymentAccounts", "investments.holdings", "investments.positions", "investments.lots", "investments.quotes"}},
		{"summary", []string{"accountBalances", "netWorthHistory", "monthEndNetWorth", "creditCards", "commodities", "prices"}},
		{"transactions", []string{"transactions"}},
		{"income-statement", []string{"income", "expense", "expenseAnalytics", "topPayees", "topPaymentAccounts"}},
		{"dashboard", []string{"netWorthSeries", "cashflowSeries", "dailyExpenseSeries", "weekdayExpense", "categorySeries", "accountBalanceSeries", "anomalies", "topPayees", "topPaymentAccounts", "annotations"}},
		{"home-report", []string{"dailyExpenseSeries", "accountBalanceSeries", "topPaymentAccounts", "current.categorySeries", "current.cashflowSeries", "previous.categorySeries", "previous.cashflowSeries"}},
		{"investments", []string{"holdings", "positions", "lots", "quotes"}},
		{"entries", []string{"entries", "errors"}},
		{"balances", []string{"assertions"}},
		{"reconciliation", []string{"rows"}},
		{"accounts", []string{"accounts"}},
		{"account-status", []string{"statuses"}},
		{"accounts/detail", []string{"rows"}},
		{"notifications", []string{"notifications"}},
		{"insights", []string{"insights"}},
		{"bql-history", []string{"records"}},
		{"imports/documents", []string{"documents"}},
		{"imports/providers", []string{"providers"}},
		{"editor/files", []string{"files"}},
	} {
		t.Run(test.path, func(t *testing.T) {
			input.Path = "/api/ledger/" + test.path
			input.Query["account"] = "Assets:Cash"
			var payload any
			if err := json.Unmarshal(localTestDispatch(t, input), &payload); err != nil {
				t.Fatal(err)
			}
			for _, path := range test.arrays {
				value := payload
				for _, part := range strings.Split(path, ".") {
					object, ok := value.(map[string]any)
					if !ok {
						t.Fatalf("%s parent is not an object", path)
					}
					value = object[part]
				}
				if _, ok := value.([]any); !ok {
					t.Errorf("required collection %s must encode as an array, got %#v", path, value)
				}
			}
		})
	}
}

func TestLocalCollectionNormalizationPreservesOptionalNull(t *testing.T) {
	payload := map[string]any{"rows": nil, "alias": nil}
	normalizeLocalResponseCollections(payload, "/api/ledger/accounts/detail")
	if payload["alias"] != nil {
		t.Fatal("optional alias changed")
	}
	if _, ok := payload["rows"].([]any); !ok {
		t.Fatal("rows must be an array")
	}
	bql := map[string]any{"columns": nil, "rows": []any{[]any{nil}}, "warnings": nil}
	normalizeLocalResponseCollections(bql, "/api/ledger/bql")
	if bql["rows"].([]any)[0].([]any)[0] != nil {
		t.Fatal("nullable BQL cell changed")
	}
}

func TestLocalInvestmentCollectionsNestedInsideHoldings(t *testing.T) {
	// A held commodity can have a position before it has historical prices or
	// realized trades. Swift still requires those collections to be arrays.
	encoded, err := json.Marshal(InvestmentSummary{Holdings: []InvestmentHolding{{
		Positions: []InvestmentPosition{{Account: "Assets:Broker", Commodity: "TEST"}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(encoded, &payload); err != nil {
		t.Fatal(err)
	}
	normalizeLocalResponseCollections(payload, "/api/ledger/investments")
	holding := payload["holdings"].([]any)[0].(map[string]any)
	for _, name := range []string{"priceHistory", "lots", "realizedTrades"} {
		if _, ok := holding[name].([]any); !ok {
			t.Errorf("holding %s must be an array, got %#v", name, holding[name])
		}
	}
	position := holding["positions"].([]any)[0].(map[string]any)
	for _, name := range []string{"lots", "realizedTrades"} {
		if _, ok := position[name].([]any); !ok {
			t.Errorf("position %s must be an array, got %#v", name, position[name])
		}
	}
	if _, exists := position["latestPrice"]; exists {
		t.Fatal("omitted latestPrice was added")
	}
	if _, exists := position["marketValue"]; exists {
		t.Fatal("omitted marketValue was added")
	}
}

func TestLocalNormalizationKeepsUnknownMetadataAndZeroValues(t *testing.T) {
	var payload map[string]any
	if err := json.Unmarshal([]byte(`{"transactions":[{"postings":null,"expense":0,"metadata":{"custom":{"type":"string","value":"kept","unknown":null}},"futureField":null}],"futureResponseField":null}`), &payload); err != nil {
		t.Fatal(err)
	}
	normalizeLocalResponseCollections(payload, "/api/ledger/transactions")
	transaction := payload["transactions"].([]any)[0].(map[string]any)
	if transaction["expense"] != float64(0) {
		t.Fatal("zero expense changed")
	}
	if _, exists := transaction["tags"]; exists {
		t.Fatal("omitted optional tags were added")
	}
	custom := transaction["metadata"].(map[string]any)["custom"].(map[string]any)
	if custom["value"] != "kept" || custom["unknown"] != nil {
		t.Fatal("custom metadata changed")
	}
	if _, exists := payload["futureResponseField"]; !exists || payload["futureResponseField"] != nil {
		t.Fatal("unknown response key changed")
	}
}
