package app

import (
	"context"
	"database/sql"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5"
)

func loadBeanPayloads(ctx context.Context, db *sql.DB, revisionID int64, snapshot *LedgerSnapshot) error {
	entries, err := loadBeanEntries(ctx, db, revisionID)
	if err != nil {
		return err
	}
	errors, err := loadBeanErrors(ctx, db, revisionID)
	if err != nil {
		return err
	}
	snapshot.BeanEntries = entries
	snapshot.BeanErrors = errors
	return nil
}

func loadBeanEntries(ctx context.Context, db *sql.DB, revisionID int64) ([]BeanEntry, error) {
	rows, err := db.QueryContext(ctx, `
SELECT ordinal, entry_kind, entry_date, source_file, source_line, name, value, filename, flag, payee, narration, account, account2, currency, amount, amount_number, amount_currency, tolerance, quote_currency, custom_type
FROM ledger_index_bean_entries
WHERE revision_id = $1
ORDER BY ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type indexedEntry struct {
		ordinal int
		entry   BeanEntry
	}
	indexed := []indexedEntry{}
	byOrdinal := map[int]int{}
	for rows.Next() {
		var row indexedEntry
		if err := rows.Scan(&row.ordinal, &row.entry.Kind, &row.entry.Date, &row.entry.File, &row.entry.Line, &row.entry.Name, &row.entry.Value, &row.entry.Filename, &row.entry.Flag, &row.entry.Payee, &row.entry.Narration, &row.entry.Account, &row.entry.Account2, &row.entry.Currency, &row.entry.Amount, &row.entry.AmountValue.Number, &row.entry.AmountValue.Currency, &row.entry.Tolerance, &row.entry.QuoteCurrency, &row.entry.CustomType); err != nil {
			return nil, err
		}
		row.entry.Metadata = map[string]MetadataValue{}
		byOrdinal[row.ordinal] = len(indexed)
		indexed = append(indexed, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for _, values := range []struct {
		table  string
		column string
		apply  func(*BeanEntry, []string)
	}{
		{table: "ledger_index_bean_entry_lines", column: "text", apply: func(entry *BeanEntry, values []string) { entry.RawLines = values }},
		{table: "ledger_index_bean_entry_currencies", column: "currency", apply: func(entry *BeanEntry, values []string) { entry.Currencies = values }},
		{table: "ledger_index_bean_entry_tags", column: "tag", apply: func(entry *BeanEntry, values []string) { entry.Tags = values }},
		{table: "ledger_index_bean_entry_links", column: "link", apply: func(entry *BeanEntry, values []string) { entry.Links = values }},
	} {
		byEntry, err := loadBeanEntryStrings(ctx, db, revisionID, values.table, values.column)
		if err != nil {
			return nil, err
		}
		for ordinal, items := range byEntry {
			if index, ok := byOrdinal[ordinal]; ok {
				values.apply(&indexed[index].entry, items)
			}
		}
	}

	metadata, err := loadBeanEntryMetadata(ctx, db, revisionID)
	if err != nil {
		return nil, err
	}
	for ordinal, values := range metadata {
		if index, ok := byOrdinal[ordinal]; ok {
			indexed[index].entry.Metadata = values
		}
	}
	customValues, err := loadBeanEntryCustomValues(ctx, db, revisionID)
	if err != nil {
		return nil, err
	}
	for ordinal, values := range customValues {
		if index, ok := byOrdinal[ordinal]; ok {
			indexed[index].entry.CustomValues = values
		}
	}
	postings, err := loadBeanEntryPostings(ctx, db, revisionID)
	if err != nil {
		return nil, err
	}
	for ordinal, values := range postings {
		if index, ok := byOrdinal[ordinal]; ok {
			indexed[index].entry.Postings = values
		}
	}
	out := make([]BeanEntry, 0, len(indexed))
	for _, row := range indexed {
		out = append(out, row.entry)
	}
	return out, nil
}

func loadBeanEntryStrings(ctx context.Context, db *sql.DB, revisionID int64, table, column string) (map[int][]string, error) {
	query := fmt.Sprintf(`SELECT entry_ordinal, %s FROM %s WHERE revision_id = $1 ORDER BY entry_ordinal, ordinal`, column, table)
	rows, err := db.QueryContext(ctx, query, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int][]string{}
	for rows.Next() {
		var ordinal int
		var value string
		if err := rows.Scan(&ordinal, &value); err != nil {
			return nil, err
		}
		out[ordinal] = append(out[ordinal], value)
	}
	return out, rows.Err()
}

func loadBeanEntryMetadata(ctx context.Context, db *sql.DB, revisionID int64) (map[int]map[string]MetadataValue, error) {
	rows, err := db.QueryContext(ctx, `
SELECT entry_ordinal, metadata_key, value_kind, text_value, number_value, boolean_value
FROM ledger_index_bean_entry_metadata
WHERE revision_id = $1
ORDER BY entry_ordinal, metadata_key`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int]map[string]MetadataValue{}
	for rows.Next() {
		var ordinal int
		var key, kind string
		var textValue sql.NullString
		var numberValue sql.NullFloat64
		var booleanValue sql.NullBool
		if err := rows.Scan(&ordinal, &key, &kind, &textValue, &numberValue, &booleanValue); err != nil {
			return nil, err
		}
		value, err := decodeLedgerMetadataValue(kind, textValue, numberValue, booleanValue)
		if err != nil {
			return nil, fmt.Errorf("decode bean entry metadata %d.%s: %w", ordinal, key, err)
		}
		if out[ordinal] == nil {
			out[ordinal] = map[string]MetadataValue{}
		}
		out[ordinal][key] = value
	}
	return out, rows.Err()
}

func loadBeanEntryCustomValues(ctx context.Context, db *sql.DB, revisionID int64) (map[int][]MetadataValue, error) {
	rows, err := db.QueryContext(ctx, `
SELECT entry_ordinal, value_kind, text_value, number_value, boolean_value
FROM ledger_index_bean_entry_custom_values
WHERE revision_id = $1
ORDER BY entry_ordinal, ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int][]MetadataValue{}
	for rows.Next() {
		var ordinal int
		var kind string
		var textValue sql.NullString
		var numberValue sql.NullFloat64
		var booleanValue sql.NullBool
		if err := rows.Scan(&ordinal, &kind, &textValue, &numberValue, &booleanValue); err != nil {
			return nil, err
		}
		value, err := decodeLedgerMetadataValue(kind, textValue, numberValue, booleanValue)
		if err != nil {
			return nil, fmt.Errorf("decode bean entry custom value %d: %w", ordinal, err)
		}
		out[ordinal] = append(out[ordinal], value)
	}
	return out, rows.Err()
}

func loadBeanEntryPostings(ctx context.Context, db *sql.DB, revisionID int64) (map[int][]parsedPosting, error) {
	rows, err := db.QueryContext(ctx, `
SELECT entry_ordinal, account, amount, currency, flag, blank, quantity_number, quantity_currency, cost_amount, cost_currency, cost_number, cost_value_currency, total_cost, price_amount, price_currency, price_number, price_value_currency, total_price
FROM ledger_index_bean_entry_postings
WHERE revision_id = $1
ORDER BY entry_ordinal, ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int][]parsedPosting{}
	for rows.Next() {
		var ordinal int
		var posting parsedPosting
		if err := rows.Scan(&ordinal, &posting.Account, &posting.Amount, &posting.Currency, &posting.Flag, &posting.Blank, &posting.Quantity.Number, &posting.Quantity.Currency, &posting.CostAmount, &posting.CostCurrency, &posting.Cost.Number, &posting.Cost.Currency, &posting.TotalCost, &posting.PriceAmount, &posting.PriceCurrency, &posting.Price.Number, &posting.Price.Currency, &posting.TotalPrice); err != nil {
			return nil, err
		}
		out[ordinal] = append(out[ordinal], posting)
	}
	return out, rows.Err()
}

func loadBeanErrors(ctx context.Context, db *sql.DB, revisionID int64) ([]BeanParseError, error) {
	rows, err := db.QueryContext(ctx, `
SELECT source_file, source_line, message
FROM ledger_index_bean_errors
WHERE revision_id = $1
ORDER BY ordinal`, revisionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []BeanParseError{}
	for rows.Next() {
		var item BeanParseError
		if err := rows.Scan(&item.File, &item.Line, &item.Message); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func copyBeanPayloads(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry, parseErrors []BeanParseError) error {
	if err := copyBeanEntries(ctx, tx, revisionID, entries); err != nil {
		return err
	}
	return copyBeanErrors(ctx, tx, revisionID, parseErrors)
}

func copyBeanEntries(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry) error {
	if len(entries) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_bean_entries"}, []string{"revision_id", "ordinal", "entry_kind", "entry_date", "source_file", "source_line", "name", "value", "filename", "flag", "payee", "narration", "account", "account2", "currency", "amount", "amount_number", "amount_currency", "tolerance", "quote_currency", "custom_type"}, pgx.CopyFromSlice(len(entries), func(i int) ([]any, error) {
		entry := entries[i]
		return []any{revisionID, i, entry.Kind, entry.Date, entry.File, entry.Line, entry.Name, entry.Value, entry.Filename, entry.Flag, entry.Payee, entry.Narration, entry.Account, entry.Account2, entry.Currency, entry.Amount, entry.AmountValue.Number, entry.AmountValue.Currency, entry.Tolerance, entry.QuoteCurrency, entry.CustomType}, nil
	}))
	if err != nil {
		return err
	}
	for _, values := range []struct {
		table  string
		column string
		items  func(BeanEntry) []string
	}{
		{table: "ledger_index_bean_entry_lines", column: "text", items: func(entry BeanEntry) []string { return entry.RawLines }},
		{table: "ledger_index_bean_entry_currencies", column: "currency", items: func(entry BeanEntry) []string { return entry.Currencies }},
		{table: "ledger_index_bean_entry_tags", column: "tag", items: func(entry BeanEntry) []string { return entry.Tags }},
		{table: "ledger_index_bean_entry_links", column: "link", items: func(entry BeanEntry) []string { return entry.Links }},
	} {
		if err := copyBeanEntryStrings(ctx, tx, revisionID, entries, values.table, values.column, values.items); err != nil {
			return err
		}
	}
	if err := copyBeanEntryMetadata(ctx, tx, revisionID, entries); err != nil {
		return err
	}
	if err := copyBeanEntryCustomValues(ctx, tx, revisionID, entries); err != nil {
		return err
	}
	return copyBeanEntryPostings(ctx, tx, revisionID, entries)
}

func copyBeanEntryStrings(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry, table, column string, values func(BeanEntry) []string) error {
	type row struct {
		entryOrdinal int
		ordinal      int
		value        string
	}
	rows := []row{}
	for entryOrdinal, entry := range entries {
		for ordinal, value := range values(entry) {
			rows = append(rows, row{entryOrdinal: entryOrdinal, ordinal: ordinal, value: value})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{table}, []string{"revision_id", "entry_ordinal", "ordinal", column}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		return []any{revisionID, row.entryOrdinal, row.ordinal, row.value}, nil
	}))
	return err
}

func copyBeanEntryMetadata(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry) error {
	type row struct {
		entryOrdinal int
		key          string
		kind         string
		text         any
		number       any
		boolean      any
	}
	rows := []row{}
	for entryOrdinal, entry := range entries {
		keys := make([]string, 0, len(entry.Metadata))
		for key := range entry.Metadata {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			kind, textValue, numberValue, booleanValue, err := encodeLedgerMetadataValue(entry.Metadata[key])
			if err != nil {
				return fmt.Errorf("encode bean entry metadata %d.%s: %w", entryOrdinal, key, err)
			}
			rows = append(rows, row{entryOrdinal: entryOrdinal, key: key, kind: kind, text: textValue, number: numberValue, boolean: booleanValue})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_bean_entry_metadata"}, []string{"revision_id", "entry_ordinal", "metadata_key", "value_kind", "text_value", "number_value", "boolean_value"}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		return []any{revisionID, row.entryOrdinal, row.key, row.kind, row.text, row.number, row.boolean}, nil
	}))
	return err
}

func copyBeanEntryCustomValues(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry) error {
	type row struct {
		entryOrdinal int
		ordinal      int
		kind         string
		text         any
		number       any
		boolean      any
	}
	rows := []row{}
	for entryOrdinal, entry := range entries {
		for ordinal, value := range entry.CustomValues {
			kind, textValue, numberValue, booleanValue, err := encodeLedgerMetadataValue(value)
			if err != nil {
				return fmt.Errorf("encode bean entry custom value %d.%d: %w", entryOrdinal, ordinal, err)
			}
			rows = append(rows, row{entryOrdinal: entryOrdinal, ordinal: ordinal, kind: kind, text: textValue, number: numberValue, boolean: booleanValue})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_bean_entry_custom_values"}, []string{"revision_id", "entry_ordinal", "ordinal", "value_kind", "text_value", "number_value", "boolean_value"}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		return []any{revisionID, row.entryOrdinal, row.ordinal, row.kind, row.text, row.number, row.boolean}, nil
	}))
	return err
}

func copyBeanEntryPostings(ctx context.Context, tx pgx.Tx, revisionID int64, entries []BeanEntry) error {
	type row struct {
		entryOrdinal int
		ordinal      int
		posting      parsedPosting
	}
	rows := []row{}
	for entryOrdinal, entry := range entries {
		for ordinal, posting := range entry.Postings {
			rows = append(rows, row{entryOrdinal: entryOrdinal, ordinal: ordinal, posting: posting})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_bean_entry_postings"}, []string{"revision_id", "entry_ordinal", "ordinal", "account", "amount", "currency", "flag", "blank", "quantity_number", "quantity_currency", "cost_amount", "cost_currency", "cost_number", "cost_value_currency", "total_cost", "price_amount", "price_currency", "price_number", "price_value_currency", "total_price"}, pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
		row := rows[i]
		posting := row.posting
		return []any{revisionID, row.entryOrdinal, row.ordinal, posting.Account, posting.Amount, posting.Currency, posting.Flag, posting.Blank, posting.Quantity.Number, posting.Quantity.Currency, posting.CostAmount, posting.CostCurrency, posting.Cost.Number, posting.Cost.Currency, posting.TotalCost, posting.PriceAmount, posting.PriceCurrency, posting.Price.Number, posting.Price.Currency, posting.TotalPrice}, nil
	}))
	return err
}

func copyBeanErrors(ctx context.Context, tx pgx.Tx, revisionID int64, parseErrors []BeanParseError) error {
	if len(parseErrors) == 0 {
		return nil
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_index_bean_errors"}, []string{"revision_id", "ordinal", "source_file", "source_line", "message"}, pgx.CopyFromSlice(len(parseErrors), func(i int) ([]any, error) {
		item := parseErrors[i]
		return []any{revisionID, i, item.File, item.Line, item.Message}, nil
	}))
	return err
}
