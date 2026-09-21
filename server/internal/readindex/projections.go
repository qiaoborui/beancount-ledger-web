package readindex

import (
	"encoding/json"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/ledger"
	"github.com/borui/beancount-ledger-web/server/internal/readindex/sqlite"
)

// These are projections of verified canonical records, not a second parser or
// valuation engine. Amounts retain their exact source spelling, including scale
// and exponent. NULL distinguishes absent lot/price/flag fields from empty text.
var projectionTables = []struct{ name, columns string }{
	{"postings", "seq, entry_id, ordinal, account, date, quantity, currency, cost_number, cost_currency, cost_date, cost_label, price_number, price_currency, flag"},
	{"account_events", "seq, entry_id, kind, account, date"},
	{"prices", "seq, entry_id, date, currency, quantity, quote_currency"},
}

type projectionState struct{ date string }
type projection struct {
	table  int
	values []any
}

func optionalText(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}
func optionalAmount(a *ledger.BeanAmount) (any, any) {
	if a == nil {
		return nil, nil
	}
	return a.Number, a.Currency
}

// Only one directive date and one decoded record are retained across ingestion.
// Build calls this after record verification; reopen also runs the same raw
// verifier over the replay before accepting any projection or manifest.
func (s *projectionState) project(raw []byte, key envelope, seq int64) (projection, error) {
	p := projection{table: -1}
	if key.Type != "posting" && key.Type != "directive" {
		return p, nil
	}
	var r struct {
		Ordinal int64 `json:"ordinal"`
		Value   struct {
			Account     string
			Currency    string
			AmountValue ledger.BeanAmount
			Quantity    ledger.BeanAmount
			Cost        *ledger.BeanAmount
			CostDate    *string
			CostLabel   *string
			Price       *ledger.BeanAmount
			Flag        *string
		} `json:"value"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return p, ErrCorrupt
	}
	v := r.Value
	if key.Type == "posting" {
		cn, cc := optionalAmount(v.Cost)
		pn, pc := optionalAmount(v.Price)
		return projection{0, []any{seq, key.EntryID, r.Ordinal, v.Account, s.date, v.Quantity.Number, v.Quantity.Currency, cn, cc, optionalText(v.CostDate), optionalText(v.CostLabel), pn, pc, optionalText(v.Flag)}}, nil
	}
	s.date = key.Value.Date
	switch key.Value.Kind {
	case "open", "close":
		return projection{1, []any{seq, key.ID, key.Value.Kind, v.Account, s.date}}, nil
	case "price":
		return projection{2, []any{seq, key.ID, s.date, v.Currency, v.AmountValue.Number, v.AmountValue.Currency}}, nil
	}
	return p, nil
}

func insertProjection(db *sqlite.DB, p projection) error {
	if p.table < 0 {
		return nil
	}
	t := projectionTables[p.table]
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(p.values)), ",")
	return db.Exec("INSERT INTO "+t.name+" ("+t.columns+") VALUES ("+placeholders+")", p.values...)
}

// One join row per raw record: seq primary keys prohibit multiplication. Never
// query while Rows is live (the native adapter has one serial statement owner).
func projectionReplayQuery() string {
	q := "SELECT r.seq, r.entry_id, r.raw, t.id, t.date, t.seq"
	for _, t := range projectionTables {
		for _, c := range strings.Split(t.columns, ", ") {
			q += ", " + t.name + "." + c
		}
	}
	q += " FROM records AS r LEFT JOIN transactions AS t INDEXED BY transactions_seq ON t.seq=r.seq"
	for _, t := range projectionTables {
		q += " LEFT JOIN " + t.name + " ON " + t.name + ".seq=r.seq"
	}
	return q + " ORDER BY r.seq"
}

func verifyProjectionRow(rows *sqlite.Rows, p projection) bool {
	offset := 6
	for table, t := range projectionTables {
		width := len(strings.Split(t.columns, ", "))
		if p.table != table {
			if !rows.IsNull(offset) {
				return false
			}
		} else {
			for j, want := range p.values {
				col := offset + j
				if want == nil {
					if !rows.IsNull(col) {
						return false
					}
					continue
				}
				if rows.IsNull(col) {
					return false
				}
				switch v := want.(type) {
				case int64:
					if rows.Int64(col) != v {
						return false
					}
				case string:
					if rows.Text(col) != v {
						return false
					}
				default:
					return false
				}
			}
		}
		offset += width
	}
	return true
}
