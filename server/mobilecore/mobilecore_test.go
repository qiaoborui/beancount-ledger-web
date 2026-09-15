package mobilecore

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

func TestParseTextJSONMatchesLedgerCore(t *testing.T) {
	text := "pushmeta source: \"ios\"\n" +
		`2026-09-15 * "Cafe" "Lunch" #food` + "\n" +
		"  Expenses:Food 12.34 CNY\n" +
		"  Assets:Cash\n"
	request, err := json.Marshal(parseRequestV1{Version: 1, Filename: "mobile.bean", Text: text})
	if err != nil {
		t.Fatal(err)
	}
	payload := ParseTextJSON(string(request))
	var response parseResponseV1
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatal(err)
	}
	want := entriesV1(ledgercore.ParseText("mobile.bean", text).Entries)
	if !response.OK || len(response.Diagnostics) != 0 || response.Result == nil {
		t.Fatalf("unexpected response: %#v", response)
	}
	wantPayload, err := json.Marshal(parseResponseV1{
		Version:     1,
		Operation:   "parse",
		OK:          true,
		Result:      &parseResultV1{Entries: want},
		Diagnostics: []diagnosticV1{},
	})
	if err != nil {
		t.Fatal(err)
	}
	var gotJSON, wantJSON any
	if err := json.Unmarshal([]byte(payload), &gotJSON); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(wantPayload, &wantJSON); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotJSON, wantJSON) {
		t.Fatalf("mobile response drifted from ledgercore:\n got: %s\nwant: %s", payload, wantPayload)
	}
}

func TestParseTextJSONReturnsStructuredDiagnostics(t *testing.T) {
	tests := []struct {
		name    string
		request string
		code    string
		line    int
	}{
		{name: "invalid JSON", request: `{`, code: "request.invalid_json"},
		{name: "unsupported version", request: `{"version":2,"text":""}`, code: "request.unsupported_version"},
		{name: "unknown field", request: `{"version":1,"text":"","extra":true}`, code: "request.invalid_json"},
		{name: "parse error", request: `{"version":1,"filename":"bad.bean","text":"option \"title\""}`, code: "beancount.parse_error", line: 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var response parseResponseV1
			if err := json.Unmarshal([]byte(ParseTextJSON(test.request)), &response); err != nil {
				t.Fatal(err)
			}
			if response.Version != 1 || response.OK || len(response.Diagnostics) != 1 {
				t.Fatalf("unexpected response: %#v", response)
			}
			if response.Diagnostics[0].Code != test.code || response.Diagnostics[0].Line != test.line {
				t.Fatalf("diagnostic = %#v", response.Diagnostics[0])
			}
		})
	}
}

func TestParseTextJSONUsesMemoryFilenameByDefault(t *testing.T) {
	var response parseResponseV1
	payload := ParseTextJSON(`{"version":1,"text":"2026-09-15 open Assets:Cash CNY"}`)
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatal(err)
	}
	if response.Result == nil || len(response.Result.Entries) != 1 || response.Result.Entries[0].File != "<memory>" {
		t.Fatalf("response = %s", payload)
	}
}

func TestCompileTextJSONAddsBalanceDiagnostics(t *testing.T) {
	request := `{"version":1,"filename":"bad.bean","text":"2026-09-15 * \"Cafe\" \"Lunch\"\n  Expenses:Food 10.00 CNY\n  Assets:Cash -9.00 CNY"}`

	var parsed parseResponseV1
	if err := json.Unmarshal([]byte(ParseTextJSON(request)), &parsed); err != nil {
		t.Fatal(err)
	}
	if !parsed.OK || parsed.Operation != "parse" {
		t.Fatalf("parse response = %#v", parsed)
	}

	var compiled parseResponseV1
	if err := json.Unmarshal([]byte(CompileTextJSON(request)), &compiled); err != nil {
		t.Fatal(err)
	}
	if compiled.OK || compiled.Operation != "compile" || len(compiled.Diagnostics) != 1 {
		t.Fatalf("compile response = %#v", compiled)
	}
	if compiled.Diagnostics[0].Code != "beancount.balance_error" || compiled.Diagnostics[0].Line != 1 {
		t.Fatalf("diagnostic = %#v", compiled.Diagnostics[0])
	}
}

func TestCompileTextJSONDistinguishesStructuralDiagnostics(t *testing.T) {
	var response parseResponseV1
	payload := CompileTextJSON(`{"version":1,"filename":"bad.bean","text":"poptag #missing"}`)
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatal(err)
	}
	if response.OK || len(response.Diagnostics) != 1 || response.Diagnostics[0].Code != "beancount.compile_error" {
		t.Fatalf("response = %s", payload)
	}
}

func TestParseTextJSONEnforcesResourceLimits(t *testing.T) {
	longNumber := strings.Repeat("9", maxNumericTokenBytes+1)
	manyTokens := strings.Repeat(" + 1", maxTokensPerLine/2+1)
	manyNumbers := "2026-09-15 price USD " + strings.Repeat("1 + ", maxNumericTokensPerLine) + "1 CNY"
	tests := []struct {
		name    string
		request string
		code    string
		line    int
	}{
		{name: "request", request: strings.Repeat(" ", maxRequestBytes+1), code: "request.too_large"},
		{name: "filename", request: requestJSON(t, strings.Repeat("f", maxFilenameBytes+1), ""), code: "request.filename_too_long"},
		{name: "text", request: requestJSON(t, "large.bean", strings.Repeat("x", maxTextBytes+1)), code: "request.text_too_large"},
		{name: "line count", request: requestJSON(t, "lines.bean", strings.Repeat("\n", maxLineCount)), code: "request.too_many_lines", line: maxLineCount + 1},
		{name: "line", request: requestJSON(t, "line.bean", strings.Repeat("x", maxLineBytes+1)), code: "request.line_too_long", line: 1},
		{name: "tokens", request: requestJSON(t, "tokens.bean", manyTokens), code: "request.too_many_tokens", line: 1},
		{name: "numeric expression", request: requestJSON(t, "number.bean", manyNumbers), code: "request.numeric_expression_too_complex", line: 1},
		{name: "numeric token", request: requestJSON(t, "number.bean", "2026-09-15 price USD "+longNumber+" CNY"), code: "request.numeric_token_too_complex", line: 1},
		{name: "numeric exponent", request: requestJSON(t, "number.bean", "2026-09-15 price USD 1e65 CNY"), code: "request.numeric_token_too_complex", line: 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var response parseResponseV1
			if err := json.Unmarshal([]byte(ParseTextJSON(test.request)), &response); err != nil {
				t.Fatal(err)
			}
			if response.OK || len(response.Diagnostics) != 1 || response.Diagnostics[0].Code != test.code || response.Diagnostics[0].Line != test.line {
				t.Fatalf("response = %#v", response)
			}
		})
	}
}

func TestEncodeResponseEnforcesOutputLimit(t *testing.T) {
	payload := encodeResponse(parseResponseV1{
		Version:   1,
		Operation: "parse",
		OK:        true,
		Result: &parseResultV1{Entries: []entryV1{{
			Kind:     "custom",
			RawLines: []string{strings.Repeat("x", maxResponseBytes+1)},
		}}},
		Diagnostics: []diagnosticV1{},
	})
	var response parseResponseV1
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatal(err)
	}
	if response.OK || len(response.Diagnostics) != 1 || response.Diagnostics[0].Code != "response.too_large" {
		t.Fatalf("response = %s", payload)
	}
}

func requestJSON(t *testing.T, filename, text string) string {
	t.Helper()
	payload, err := json.Marshal(parseRequestV1{Version: 1, Filename: filename, Text: text})
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}
