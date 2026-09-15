// Package mobilecore exposes a gomobile-safe string API over the local ledger
// parser. Its exported surface intentionally uses scalar values only.
package mobilecore

import (
	"encoding/json"
	"io"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

const parseAPIVersion = 1

const (
	maxRequestBytes             = 8 << 20
	maxFilenameBytes            = 1024
	maxTextBytes                = 2 << 20
	maxLineCount                = 100_000
	maxLineBytes                = 64 << 10
	maxTokensPerLine            = 1024
	maxNumericTokensPerLine     = 64
	maxNumericTokenBytes        = 128
	maxNumericExponentMagnitude = 64
	maxResponseBytes            = 16 << 20
)

type parseRequestV1 struct {
	Version  int    `json:"version"`
	Filename string `json:"filename"`
	Text     string `json:"text"`
}

type parseResponseV1 struct {
	Version     int            `json:"version"`
	Operation   string         `json:"operation"`
	OK          bool           `json:"ok"`
	Result      *parseResultV1 `json:"result,omitempty"`
	Diagnostics []diagnosticV1 `json:"diagnostics"`
}

type parseResultV1 struct {
	Entries []entryV1 `json:"entries"`
}

type diagnosticV1 struct {
	Code     string `json:"code"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	File     string `json:"file,omitempty"`
	Line     int    `json:"line,omitempty"`
}

type amountV1 struct {
	Number   string `json:"number"`
	Currency string `json:"currency"`
}

type postingV1 struct {
	Account       string   `json:"account"`
	Amount        int      `json:"amount"`
	Currency      string   `json:"currency,omitempty"`
	Flag          string   `json:"flag,omitempty"`
	Blank         bool     `json:"blank"`
	Quantity      amountV1 `json:"quantity"`
	CostAmount    int      `json:"costAmount"`
	CostCurrency  string   `json:"costCurrency,omitempty"`
	Cost          amountV1 `json:"cost"`
	TotalCost     bool     `json:"totalCost"`
	PriceAmount   int      `json:"priceAmount"`
	PriceCurrency string   `json:"priceCurrency,omitempty"`
	Price         amountV1 `json:"price"`
	TotalPrice    bool     `json:"totalPrice"`
}

type entryV1 struct {
	Kind          string                              `json:"kind"`
	Date          string                              `json:"date,omitempty"`
	File          string                              `json:"file,omitempty"`
	Line          int                                 `json:"line,omitempty"`
	RawLines      []string                            `json:"rawLines,omitempty"`
	Name          string                              `json:"name,omitempty"`
	Value         string                              `json:"value,omitempty"`
	Filename      string                              `json:"filename,omitempty"`
	Flag          string                              `json:"flag,omitempty"`
	Payee         string                              `json:"payee,omitempty"`
	Narration     string                              `json:"narration,omitempty"`
	Account       string                              `json:"account,omitempty"`
	Account2      string                              `json:"account2,omitempty"`
	Currencies    []string                            `json:"currencies,omitempty"`
	Currency      string                              `json:"currency,omitempty"`
	Amount        int                                 `json:"amount,omitempty"`
	AmountValue   amountV1                            `json:"amountValue"`
	Tolerance     string                              `json:"tolerance,omitempty"`
	QuoteCurrency string                              `json:"quoteCurrency,omitempty"`
	Metadata      map[string]ledgercore.MetadataValue `json:"metadata,omitempty"`
	Tags          []string                            `json:"tags,omitempty"`
	Links         []string                            `json:"links,omitempty"`
	Postings      []postingV1                         `json:"postings,omitempty"`
	CustomType    string                              `json:"customType,omitempty"`
	CustomValues  []ledgercore.MetadataValue          `json:"customValues,omitempty"`
}

// ParseTextJSON parses a versioned JSON request and always returns a versioned
// JSON response. The scalar signature is suitable for gomobile bindings.
func ParseTextJSON(requestJSON string) string {
	return runTextJSON(requestJSON, false)
}

// CompileTextJSON parses and runs ledgercore's lightweight structural and
// balance validation. Its scalar signature is suitable for gomobile bindings.
func CompileTextJSON(requestJSON string) string {
	return runTextJSON(requestJSON, true)
}

func runTextJSON(requestJSON string, compile bool) string {
	operation := "parse"
	if compile {
		operation = "compile"
	}
	request, diagnostic := decodeParseRequest(requestJSON)
	if diagnostic != nil {
		return encodeResponse(parseResponseV1{
			Version:     parseAPIVersion,
			Operation:   operation,
			OK:          false,
			Diagnostics: []diagnosticV1{*diagnostic},
		})
	}
	filename := request.Filename
	if filename == "" {
		filename = "<memory>"
	}
	if diagnostic := validateScopeLimits(sourceLines(filename, request.Text)); diagnostic != nil {
		return diagnosticResponse(operation, diagnostic)
	}
	parsed := ledgercore.ParseText(filename, request.Text)
	result := parsed
	if compile {
		result = ledgercore.CompileText(filename, request.Text)
	}
	diagnostics := make([]diagnosticV1, len(result.Errors))
	for index, parseError := range result.Errors {
		code := "beancount.parse_error"
		if index >= len(parsed.Errors) {
			code = compileDiagnosticCode(parseError.Message)
		}
		diagnostics[index] = diagnosticV1{
			Code:     code,
			Severity: "error",
			Message:  parseError.Message,
			File:     parseError.File,
			Line:     parseError.Line,
		}
	}
	return encodeResponse(parseResponseV1{
		Version:   parseAPIVersion,
		Operation: operation,
		OK:        len(diagnostics) == 0,
		Result: &parseResultV1{
			Entries: entriesV1(result.Entries),
		},
		Diagnostics: diagnostics,
	})
}

func compileDiagnosticCode(message string) string {
	switch {
	case strings.HasPrefix(message, "transaction has more than one incomplete posting"),
		strings.HasPrefix(message, "cannot infer incomplete posting across multiple currencies"),
		strings.HasPrefix(message, "transaction is not balanced in "):
		return "beancount.balance_error"
	default:
		return "beancount.compile_error"
	}
}

func decodeParseRequest(requestJSON string) (parseRequestV1, *diagnosticV1) {
	var request parseRequestV1
	if diagnostic := decodeRequestJSON(requestJSON, &request); diagnostic != nil {
		return parseRequestV1{}, diagnostic
	}
	if request.Version != parseAPIVersion {
		return parseRequestV1{}, &diagnosticV1{
			Code: "request.unsupported_version", Severity: "error",
			Message: "supported parse request version is 1",
		}
	}
	if diagnostic := validateRequestLimits(request); diagnostic != nil {
		return parseRequestV1{}, diagnostic
	}
	return request, nil
}

func decodeRequestJSON(requestJSON string, request any) *diagnosticV1 {
	if len(requestJSON) > maxRequestBytes {
		return limitDiagnostic("request.too_large", "request exceeds 8 MiB", "", 0)
	}
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(request); err != nil {
		return &diagnosticV1{Code: "request.invalid_json", Severity: "error", Message: err.Error()}
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		message := "request contains trailing JSON data"
		if err != nil {
			message = err.Error()
		}
		return &diagnosticV1{Code: "request.invalid_json", Severity: "error", Message: message}
	}
	return nil
}

func validateRequestLimits(request parseRequestV1) *diagnosticV1 {
	if len(request.Filename) > maxFilenameBytes {
		return limitDiagnostic("request.filename_too_long", "filename exceeds 1024 bytes", "", 0)
	}
	if len(request.Text) > maxTextBytes {
		return limitDiagnostic("request.text_too_large", "ledger text exceeds 2 MiB", request.Filename, 0)
	}
	lineNumber := 1
	for start := 0; ; lineNumber++ {
		if lineNumber > maxLineCount {
			return limitDiagnostic("request.too_many_lines", "ledger text exceeds 100000 lines", request.Filename, lineNumber)
		}
		rest := request.Text[start:]
		offset := strings.IndexByte(rest, '\n')
		end := len(request.Text)
		if offset >= 0 {
			end = start + offset
		}
		line := request.Text[start:end]
		if len(line) > maxLineBytes {
			return limitDiagnostic("request.line_too_long", "ledger line exceeds 64 KiB", request.Filename, lineNumber)
		}
		tokens := ledgercore.ScanBeanLine(line)
		if len(tokens) > maxTokensPerLine {
			return limitDiagnostic("request.too_many_tokens", "ledger line exceeds 1024 tokens", request.Filename, lineNumber)
		}
		numericTokens := 0
		for _, token := range tokens {
			if token.Kind != ledgercore.TokenString && numericTokenCandidate(token.Value) {
				numericTokens++
				if numericTokens > maxNumericTokensPerLine {
					return limitDiagnostic("request.numeric_expression_too_complex", "ledger line exceeds 64 numeric tokens", request.Filename, lineNumber)
				}
			}
			if token.Kind == ledgercore.TokenString || !numericTokenTooComplex(token.Value) {
				continue
			}
			return limitDiagnostic("request.numeric_token_too_complex", "numeric token exceeds supported size or exponent", request.Filename, lineNumber)
		}
		if offset < 0 {
			break
		}
		start = end + 1
	}
	return nil
}

func numericTokenTooComplex(value string) bool {
	if !numericTokenCandidate(value) {
		return false
	}
	if len(value) > maxNumericTokenBytes {
		return true
	}
	// big.Rat also accepts leading-dot decimals, binary exponents and digit
	// separators, including values that overflow the scanner's float64 probe.
	value = strings.ReplaceAll(strings.ReplaceAll(value, ",", ""), "_", "")
	exponentIndex := strings.LastIndexAny(value, "eEpP")
	if exponentIndex < 0 {
		return false
	}
	exponentIndex++
	if exponentIndex < len(value) && (value[exponentIndex] == '+' || value[exponentIndex] == '-') {
		exponentIndex++
	}
	if exponentIndex == len(value) {
		return false
	}
	exponent := 0
	for ; exponentIndex < len(value); exponentIndex++ {
		char := value[exponentIndex]
		if char < '0' || char > '9' {
			return false
		}
		exponent = exponent*10 + int(char-'0')
		if exponent > maxNumericExponentMagnitude {
			return true
		}
	}
	return false
}

func limitDiagnostic(code, message, file string, line int) *diagnosticV1 {
	return &diagnosticV1{Code: code, Severity: "error", Message: message, File: file, Line: line}
}

func numericTokenCandidate(value string) bool {
	value = strings.TrimPrefix(strings.TrimPrefix(value, "+"), "-")
	if value == "" {
		return false
	}
	return value[0] >= '0' && value[0] <= '9' ||
		len(value) > 1 && value[0] == '.' && value[1] >= '0' && value[1] <= '9'
}

func diagnosticResponse(operation string, diagnostic *diagnosticV1) string {
	return encodeResponse(parseResponseV1{
		Version: parseAPIVersion, Operation: operation,
		Diagnostics: []diagnosticV1{*diagnostic},
	})
}

func encodeResponse(response parseResponseV1) string {
	payload, err := json.Marshal(response)
	if err != nil {
		return encodeFailureResponse(response.Operation, "response.encoding_failed", "failed to encode parse response")
	}
	if len(payload) > maxResponseBytes {
		fallback, fallbackError := json.Marshal(parseResponseV1{
			Version:   parseAPIVersion,
			Operation: response.Operation,
			OK:        false,
			Diagnostics: []diagnosticV1{{
				Code:     "response.too_large",
				Severity: "error",
				Message:  "parse response exceeds 16 MiB",
			}},
		})
		if fallbackError == nil {
			return string(fallback)
		}
		return encodeFailureResponse(response.Operation, "response.encoding_failed", "failed to encode parse response")
	}
	return string(payload)
}

func encodeFailureResponse(operation, code, message string) string {
	fallback, _ := json.Marshal(parseResponseV1{
		Version:   parseAPIVersion,
		Operation: operation,
		OK:        false,
		Diagnostics: []diagnosticV1{{
			Code:     code,
			Severity: "error",
			Message:  message,
		}},
	})
	return string(fallback)
}

func entriesV1(entries []ledgercore.Entry) []entryV1 {
	out := make([]entryV1, len(entries))
	for index, entry := range entries {
		postings := make([]postingV1, len(entry.Postings))
		for postingIndex, posting := range entry.Postings {
			postings[postingIndex] = postingV1{
				Account:       posting.Account,
				Amount:        posting.Amount,
				Currency:      posting.Currency,
				Flag:          posting.Flag,
				Blank:         posting.Blank,
				Quantity:      amountV1{Number: posting.Quantity.Number, Currency: posting.Quantity.Currency},
				CostAmount:    posting.CostAmount,
				CostCurrency:  posting.CostCurrency,
				Cost:          amountV1{Number: posting.Cost.Number, Currency: posting.Cost.Currency},
				TotalCost:     posting.TotalCost,
				PriceAmount:   posting.PriceAmount,
				PriceCurrency: posting.PriceCurrency,
				Price:         amountV1{Number: posting.Price.Number, Currency: posting.Price.Currency},
				TotalPrice:    posting.TotalPrice,
			}
		}
		out[index] = entryV1{
			Kind:          entry.Kind,
			Date:          entry.Date,
			File:          entry.File,
			Line:          entry.Line,
			RawLines:      entry.RawLines,
			Name:          entry.Name,
			Value:         entry.Value,
			Filename:      entry.Filename,
			Flag:          entry.Flag,
			Payee:         entry.Payee,
			Narration:     entry.Narration,
			Account:       entry.Account,
			Account2:      entry.Account2,
			Currencies:    entry.Currencies,
			Currency:      entry.Currency,
			Amount:        entry.Amount,
			AmountValue:   amountV1{Number: entry.AmountValue.Number, Currency: entry.AmountValue.Currency},
			Tolerance:     entry.Tolerance,
			QuoteCurrency: entry.QuoteCurrency,
			Metadata:      entry.Metadata,
			Tags:          entry.Tags,
			Links:         entry.Links,
			Postings:      postings,
			CustomType:    entry.CustomType,
			CustomValues:  entry.CustomValues,
		}
	}
	return out
}
