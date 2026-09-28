package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
)

// Native queries must not turn every posting into a retained map before LIMIT.
// Full scans are allowed, but intermediate rows/groups and their payload bytes
// are bounded. A capacity error is never a partial financial total.
const localBQLWorkingRows = 4096
const localBQLWorkingBytes = 8 << 20

var errLocalBQLCapacity = errors.New("本地 BQL 查询超过中间结果或响应容量，请缩小查询范围或减少分组")

type localBQLGroup struct {
	values  map[string]any
	count   int
	sums    map[int]float64
	extrema map[int]any
}

func executeLocalBQL(snapshot *LedgerSnapshot, rawQuery, rawCurrency string) (BQLResult, error) {
	query, err := parseBQL(rawQuery)
	if err != nil {
		return BQLResult{}, err
	}
	if len(query.selects) > 128 || len(query.groupBy) > 128 {
		return BQLResult{}, errLocalBQLCapacity
	}
	currency := ValidValuationCurrency(rawCurrency, snapshot.Commodities)
	priceIndex := snapshotPriceIndex(snapshot)
	grouped := bqlQueryAggregates(query) || len(query.groupBy) > 0
	groups := map[string]*localBQLGroup{}
	rows := make([]bqlProjectedRow, 0)
	used := 0
	if grouped && len(query.groupBy) == 0 {
		groups["__all__"] = &localBQLGroup{values: map[string]any{}, sums: map[int]float64{}, extrema: map[int]any{}}
	}
	accept := func(row bqlRow) error {
		if !bqlRowMatches(row, query.where) {
			return nil
		}
		if !grouped {
			// A query may select the same large collection/string many times. Bound
			// its cells/items BEFORE constructing a projected row or copying slices.
			estimate := 128 + len(query.selects)*128
			for _, item := range query.selects {
				value := row.values[item.field]
				estimate += localBQLValueBytes(value.value) + len(item.alias) + 64
				for _, member := range value.items {
					estimate += len(member) + 16
				}
				if estimate > localBQLWorkingBytes {
					return errLocalBQLCapacity
				}
			}
			projected := bqlResultRows(query, []bqlRow{row})[0]
			if !bqlRowMatches(projected.row, query.having) {
				return nil
			}
			// Account for retained cells and collection members; scalar strings are
			// immutable model references but still count against the working budget.
			size := localBQLProjectedBytes(projected)
			if len(rows) == localBQLWorkingRows || used+size > localBQLWorkingBytes {
				return errLocalBQLCapacity
			}
			used += size
			rows = append(rows, projected)
			return nil
		}
		keyBytes := 0
		for _, field := range query.groupBy {
			keyBytes += localBQLValueBytes(row.values[field].value) + 32
			if keyBytes > localBQLWorkingBytes {
				return errLocalBQLCapacity
			}
		}
		keys := make([]any, 0, len(query.groupBy))
		values := make(map[string]any, len(query.groupBy))
		for _, field := range query.groupBy {
			v := row.values[field].value
			keys = append(keys, v)
			values[field] = v
		}
		key := bqlValuesKey(keys)
		if len(query.groupBy) == 0 {
			key = "__all__"
		}
		group := groups[key]
		if group == nil {
			size := len(key) + 256 + len(query.selects)*96
			for field, value := range values {
				size += len(field) + localBQLValueBytes(value)
			}
			if len(groups) == localBQLWorkingRows || used+size > localBQLWorkingBytes {
				return errLocalBQLCapacity
			}
			used += size
			group = &localBQLGroup{values: values, sums: map[int]float64{}, extrema: map[int]any{}}
			groups[key] = group
		}
		group.count++
		for index, item := range query.selects {
			value := row.values[item.field].value
			switch item.aggregate {
			case "sum", "avg":
				if number, ok := anyToFloat(value); ok {
					group.sums[index] += number
				}
			case "min", "max":
				old, exists := group.extrema[index]
				if !exists || item.aggregate == "min" && compareBQLAny(value, old) < 0 || item.aggregate == "max" && compareBQLAny(value, old) > 0 {
					delta := localBQLValueBytes(value) - localBQLValueBytes(old)
					if used+delta > localBQLWorkingBytes {
						return errLocalBQLCapacity
					}
					used += delta
					group.extrema[index] = value
				}
			}
		}
		return nil
	}
	for txnIndex, txn := range snapshot.Transactions {
		// Bound even the transient map/collection row before strings.Join creates
		// transaction accounts/tags/links. No model-sized materialization first.
		if !localBQLTransactionFits(txn) {
			return BQLResult{}, errLocalBQLCapacity
		}
		if query.table == "transactions" {
			if err := accept(bqlTransactionRow(txn, txnIndex, priceIndex, currency)); err != nil {
				return BQLResult{}, err
			}
			continue
		}
		for postingIndex, posting := range txn.Postings {
			if err := accept(bqlPostingRow(txn, posting, txnIndex, postingIndex, priceIndex, currency)); err != nil {
				return BQLResult{}, err
			}
		}
	}
	if grouped {
		projectedBytes := 0
		for _, group := range groups {
			rowBytes := 128 + len(query.selects)*128
			cells := make([]any, 0, len(query.selects))
			values := make(map[string]bqlValue, len(query.selects))
			for index, item := range query.selects {
				var value any
				switch item.aggregate {
				case "":
					value = group.values[item.field]
				case "count":
					value = group.count
				case "sum":
					value = int(math.Round(group.sums[index]))
				case "avg":
					value = 0
					if group.count != 0 {
						value = int(math.Round(group.sums[index] / float64(group.count)))
					}
				case "min", "max":
					value = group.extrema[index]
					if value == nil {
						value = 0
					}
				}
				rowBytes += localBQLValueBytes(value) + len(item.alias) + 64
				if rowBytes > localBQLWorkingBytes {
					return BQLResult{}, errLocalBQLCapacity
				}
				cells = append(cells, value)
				values[item.alias] = bqlValue{value: value, typ: bqlSelectType(nil, item)}
			}
			projected := bqlProjectedRow{cells: cells, row: bqlRow{values: values}}
			if bqlRowMatches(projected.row, query.having) {
				projectedBytes += localBQLProjectedBytes(projected)
				if projectedBytes > localBQLWorkingBytes {
					return BQLResult{}, errLocalBQLCapacity
				}
				rows = append(rows, projected)
			}
		}
	}
	if query.distinct {
		rows = bqlDistinctRows(rows)
	}
	bqlSortRows(rows, query.selects, query.orderBy)
	warnings := []string{}
	if len(rows) > query.limit {
		warnings = append(warnings, fmt.Sprintf("结果已限制为前 %d 行", query.limit))
		rows = rows[:query.limit]
	}
	result := BQLResult{Columns: bqlColumns(query, nil), Rows: bqlResultCells(rows), Query: strings.TrimSpace(rawQuery), Warnings: warnings, ValuationCurrency: currency, Limit: query.limit, RowCount: len(rows)}
	// Bound response projection before encoding. JSON may expand strings; check
	// actual encoding too, still bounded by a small multiple of this budget.
	size := len(result.Query) + len(result.Columns)*128
	for _, row := range result.Rows {
		for _, v := range row {
			size += localBQLValueBytes(v)
		}
	}
	if size > localTransactionPageBytes {
		return BQLResult{}, errLocalBQLCapacity
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return BQLResult{}, err
	}
	if len(encoded) > localTransactionPageBytes {
		return BQLResult{}, errLocalBQLCapacity
	}
	return result, nil
}

func localBQLValueBytes(value any) int {
	if text, ok := value.(string); ok {
		return len(text) + 32
	}
	return 32
}
func localBQLProjectedBytes(row bqlProjectedRow) int {
	size := 128 + len(row.cells)*64
	for _, v := range row.cells {
		size += localBQLValueBytes(v)
	}
	for key, value := range row.row.values {
		size += len(key) + 64
		for _, item := range value.items {
			size += len(item) + 16
		}
	}
	return size
}
func localBQLTransactionFits(txn Transaction) bool {
	size := len(txn.Date) + len(txn.Payee) + len(txn.Narration) + len(txn.Source.File) + 256
	for _, tag := range txn.Tags {
		size += len(tag) + 16
		if size > localTransactionPageBytes {
			return false
		}
	}
	for _, link := range txn.Links {
		size += len(link) + 16
		if size > localTransactionPageBytes {
			return false
		}
	}
	for _, posting := range txn.Postings {
		size += len(posting.Account) + len(posting.Currency) + 32
		if size > localTransactionPageBytes {
			return false
		}
	}
	return size <= localTransactionPageBytes
}
