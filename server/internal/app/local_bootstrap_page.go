package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"time"
)

// A distinct native contract, never a silently shortened legacy BootstrapResult.
// Accounting fields are complete; transactions live ONLY in the explicit page.
// Swift must migrate selection/reconciliation before adopting this endpoint.
type localBootstrapPage struct {
	Bootstrap       BootstrapResult `json:"bootstrap"`
	TransactionPage json.RawMessage `json:"transactionPage"`
}

func localBootstrapPageResponse(cfg Config, snapshot *LedgerSnapshot, query map[string]string) (int, json.RawMessage, error) {
	for key := range query {
		switch key {
		case "start", "end", "today", "valuationCurrency", "limit":
		default:
			return 400, nil, errors.New("unsupported bootstrap page query parameter")
		}
	}
	start, end, today := query["start"], query["end"], query["today"]
	for _, value := range []string{start, end, today} {
		parsed, err := time.Parse("2006-01-02", value)
		if err != nil || parsed.Format("2006-01-02") != value {
			return 400, nil, errors.New("bootstrap page requires exact start/end/today dates")
		}
	}
	if start >= end {
		return 400, nil, ErrAccountRange
	}
	if snapshot == nil {
		return 500, nil, errors.New("missing bootstrap snapshot")
	}
	status, page, err := localTransactionPageResponse(cfg, snapshot, map[string]string{
		"dialect": localNativeCandidatesDialect, "start": start, "end": end, "limit": query["limit"],
	})
	if err != nil || status != http.StatusOK {
		return status, nil, err
	}
	summary := buildLedgerBootstrap(snapshot, start, end, true, query["valuationCurrency"], today, false)
	payload := localBootstrapPage{Bootstrap: summary, TransactionPage: page}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return 500, nil, errors.New("cannot encode native bootstrap page")
	}
	// Full accounting/catalog projections can independently exceed capacity. Do
	// not truncate prices/accounts/financial series or fall back to a giant reply.
	// This bounds the wire payload, not aggregate-building/JSON encoder peak RSS.
	if len(encoded) > localTransactionPageBytes-4096 {
		return 413, nil, errors.New("bootstrap accounting and page exceed byte budget")
	}
	// Normalize native required collections only after the raw envelope is
	// bounded. UseNumber preserves integer minor units beyond IEEE754 precision;
	// the legacy map/float64 transport round-trip must not be reintroduced here.
	var object any
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err := decoder.Decode(&object); err != nil {
		return 500, nil, errors.New("cannot normalize native bootstrap page")
	}
	object = normalizeLocalCollectionValue(object, reflect.TypeOf(localBootstrapPage{}))
	encoded, err = json.Marshal(object)
	if err != nil {
		return 500, nil, errors.New("cannot encode normalized bootstrap page")
	}
	if len(encoded) > localTransactionPageBytes-4096 {
		return 413, nil, errors.New("normalized bootstrap accounting and page exceed byte budget")
	}
	return http.StatusOK, encoded, nil
}
