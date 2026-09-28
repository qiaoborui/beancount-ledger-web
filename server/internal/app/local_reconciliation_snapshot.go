package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const localReconciliationMaxRows = 10000

type localReconciliationSnapshot struct {
	Revision          string              `json:"revision"`
	SensitiveUnlocked bool                `json:"sensitiveUnlocked"`
	Start             string              `json:"start"`
	End               string              `json:"end"`
	MonthPrefix       string              `json:"monthPrefix"`
	Rows              []ReconciliationRow `json:"rows"`
}

// Complete account rows, not a partial list and not transaction history. Limit
// both rows and encoded bytes, failing before publication instead of truncating.
// The existing HTTP/native reconciliation endpoints and staged POST are untouched.
func localReconciliationSnapshotResponse(snapshot *LedgerSnapshot, query map[string]string) (int, json.RawMessage, error) {
	for key := range query {
		if key != "start" && key != "end" {
			return 400, nil, errors.New("unsupported reconciliation snapshot query")
		}
	}
	start, end := query["start"], query["end"]
	for _, value := range []string{start, end} {
		parsed, err := time.Parse("2006-01-02", value)
		if err != nil || parsed.Format("2006-01-02") != value {
			return 400, nil, errors.New("invalid reconciliation date")
		}
	}
	if start >= end {
		return 400, nil, errors.New("invalid reconciliation range")
	}
	if snapshot == nil {
		return 500, nil, errors.New("missing reconciliation snapshot")
	}
	if len(snapshot.Version) > 1024 {
		return 413, nil, errors.New("reconciliation revision exceeds capacity")
	}
	result := localReconciliationSnapshot{Revision: fmt.Sprintf("%s:%d", snapshot.Version, snapshot.localReadModelID), SensitiveUnlocked: true,
		Start: start, End: end, MonthPrefix: start[:7], Rows: []ReconciliationRow{}}
	// Bound eligible account references before computing statuses, and use the
	// existing status calculator on THIS snapshot, never infer red/green from
	// the range's independent pending/asserted marker.
	eligible := make([]Account, 0)
	for _, account := range snapshot.Accounts {
		if account.Active && (strings.HasPrefix(account.Account, "Assets:") || strings.HasPrefix(account.Account, "Liabilities:")) {
			if len(eligible) >= localReconciliationMaxRows {
				return 413, nil, errors.New("reconciliation account count exceeds capacity")
			}
			eligible = append(eligible, account)
		}
	}
	statuses := AccountStatusIndicators(snapshot.Transactions, snapshot.BalanceAssertions, eligible)
	used := 4096
	for index, account := range eligible {
		if !account.Active || !(strings.HasPrefix(account.Account, "Assets:") || strings.HasPrefix(account.Account, "Liabilities:")) {
			continue
		}
		if len(result.Rows) >= localReconciliationMaxRows {
			return 413, nil, errors.New("reconciliation account count exceeds capacity")
		}
		row := reconciliationRowForAccount(snapshot, account, start, end)
		status := statuses[index]
		row.SnapshotStatus = &status
		issue := status.Status == "red"
		row.StatusError = &issue
		// Bound per-row serializer input before allocating escaped JSON. Final wire
		// size is checked below; at most one bounded row is considered at a time.
		budget := localTransactionPageBytes - 4096
		values := []string{row.Account, row.Label, row.Currency, row.Status, status.Account, status.Status}
		if status.LastEntryDate != nil {
			values = append(values, *status.LastEntryDate)
		}
		if status.LastEntryType != nil {
			values = append(values, *status.LastEntryType)
		}
		if row.Alias != nil {
			values = append(values, *row.Alias)
		}
		if row.LastAssertion != nil {
			values = append(values, row.LastAssertion.Date, row.LastAssertion.Account, row.LastAssertion.Currency)
		}
		for _, value := range values {
			if !localAccountChargeString(&budget, value) {
				return 413, nil, errors.New("reconciliation row exceeds capacity")
			}
		}
		encoded, err := json.Marshal(row)
		if err != nil {
			return 500, nil, errors.New("cannot encode reconciliation row")
		}
		if used+len(encoded)+1 > localTransactionPageBytes-4096 {
			return 413, nil, errors.New("reconciliation response exceeds byte budget")
		}
		used += len(encoded) + 1
		result.Rows = append(result.Rows, row)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return 500, nil, errors.New("cannot encode reconciliation snapshot")
	}
	if len(raw) > localTransactionPageBytes-4096 {
		return 413, nil, errors.New("reconciliation response exceeds byte budget")
	}
	return 200, raw, nil
}
