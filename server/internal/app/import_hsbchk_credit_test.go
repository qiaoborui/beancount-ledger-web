package app

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHsbcHKCreditProviderDetectionAndMetadata(t *testing.T) {
	detection, err := detectBillProvider("hsbc-credit.csv", hsbchkCreditCSVFixture(true), "")
	if err != nil {
		t.Fatal(err)
	}
	if detection.Provider != "hsbchk-credit" || detection.Confidence != "high" {
		t.Fatalf("unexpected detection: %#v", detection)
	}

	importer, ok := importProvider("hsbchk-credit")
	if !ok {
		t.Fatal("missing hsbchk-credit provider")
	}
	if importer.ImportEngine().ID() != "deg-module" || importer.ProviderConfig().DEGProviderID != "hsbchk" {
		t.Fatalf("unexpected importer engine/config: %s %#v", importer.ImportEngine().ID(), importer.ProviderConfig())
	}
	if got := strings.Join(importer.DedupArgs(importDedupOptions{}), ","); got != "--credit-card" {
		t.Fatalf("dedup args = %q", got)
	}
	accounts := map[string]bool{"Liabilities:HK:HSBC:CreditCard": true}
	if got := importer.DocumentAccount(accounts, "Assets:HK:HSBC:HKD"); got != "Liabilities:HK:HSBC:CreditCard" {
		t.Fatalf("document account = %s", got)
	}
}

func TestPrepareHsbcHKCreditInputNormalizesOfficialCSV(t *testing.T) {
	cfg := testLedger(t)
	input := filepath.Join(t.TempDir(), "hsbc-credit.csv")
	if err := os.WriteFile(input, hsbchkCreditCSVFixture(true), 0o600); err != nil {
		t.Fatal(err)
	}

	server := &Server{cfg: cfg}
	prepared, err := server.prepareHsbcHKCreditInput(input, "hsbchk-normalize")
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RawRowCount != 4 || prepared.FilteredRowCount != 4 || prepared.DateStart != "2025-03-24" || prepared.DateEnd != "2025-04-09" {
		t.Fatalf("unexpected prepared input: %#v", prepared)
	}
	normalized := mustRead(t, prepared.InputFile)
	if bytes.HasPrefix(normalized, []byte{0xEF, 0xBB, 0xBF}) || bytes.Contains(normalized, []byte{'\t'}) || bytes.Contains(normalized, []byte{'\r'}) {
		t.Fatalf("normalized CSV retained BOM/tab/CRLF: %q", normalized)
	}
	if !strings.Contains(string(normalized), `"-1,099.14"`) || !strings.Contains(string(normalized), "香港商戶") {
		t.Fatalf("normalized CSV lost amount or UTF-8 merchant: %s", normalized)
	}

	gb18030Input := filepath.Join(t.TempDir(), "hsbc-credit-gb18030.csv")
	if err := os.WriteFile(gb18030Input, encodeAlipayCSV(string(hsbchkCreditCSVFixture(false))), 0o600); err != nil {
		t.Fatal(err)
	}
	gb18030Prepared, err := server.prepareHsbcHKCreditInput(gb18030Input, "hsbchk-gb18030")
	if err != nil {
		t.Fatal(err)
	}
	if text := string(mustRead(t, gb18030Prepared.InputFile)); !strings.Contains(text, "香港商戶") {
		t.Fatalf("GB18030 merchant was not preserved: %s", text)
	}
}

func TestHsbcHKCreditDEGGenerationHandlesPurchasesRefundsRepaymentsAndCurrencies(t *testing.T) {
	cfg := testLedger(t)
	mustWrite(t, filepath.Join(cfg.LedgerRoot, "imports", "hsbchk-credit-card-config.yaml"), strings.Join([]string{
		"defaultMinusAccount: Income:Other",
		"defaultPlusAccount: Expenses:Unknown",
		"defaultCashAccount: Liabilities:HK:HSBC:CreditCard",
		"defaultCurrency: HKD",
		"title: HSBC HK credit card test",
		"hsbchk:",
		"  rules:",
		"    - item: RETURN",
		"      targetAccount: Expenses:Shopping:Other",
		"    - item: PAYMENT - THANK YOU",
		"      targetAccount: Assets:HK:HSBC:HKD",
		"",
	}, "\n"))
	input := filepath.Join(t.TempDir(), "hsbc-credit.csv")
	if err := os.WriteFile(input, hsbchkCreditCSVFixture(true), 0o600); err != nil {
		t.Fatal(err)
	}

	server := &Server{cfg: cfg}
	importer, ok := importProvider("hsbchk-credit")
	if !ok {
		t.Fatal("missing hsbchk-credit provider")
	}
	prepared, err := importer.Prepare(server, importFileInput{InputFile: input, OriginalFilename: "hsbc-credit.csv", ImportID: "hsbchk-generate"})
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "hsbchk-credit.bean")
	if err := importer.Generate(context.Background(), server, prepared, output); err != nil {
		t.Fatal(err)
	}
	generated := string(mustRead(t, output))
	for _, expected := range []string{
		`2025-04-09 * "香港商戶"`,
		"Expenses:Unknown 1099.14 HKD",
		"Liabilities:HK:HSBC:CreditCard -1099.14 HKD",
		"Expenses:Unknown 18.00 CNY",
		"Liabilities:HK:HSBC:CreditCard 25.00 HKD",
		"Expenses:Shopping:Other -25.00 HKD",
		"Liabilities:HK:HSBC:CreditCard 3266.16 HKD",
		"Assets:HK:HSBC:HKD -3266.16 HKD",
		`credit_or_debit: "CREDIT"`,
		`post_date: "24/03/2025"`,
	} {
		if !strings.Contains(generated, expected) {
			t.Fatalf("generated bean missing %q:\n%s", expected, generated)
		}
	}
	entries, err := parsePreviewEntries(generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 4 || entries[0].Date != "2025-03-24" || entries[3].Currency != "HKD" {
		t.Fatalf("unexpected preview entries: %#v", entries)
	}
	warnings, err := importer.PreviewWarnings(prepared, providerSourceAnalysis{}, parseBeanSummary(generated), beanSummary{CandidateCount: len(entries)}, generated)
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "CSV 明细 4 条") {
		t.Fatalf("unexpected warnings: %#v", warnings)
	}
}

func TestPrepareHsbcHKCreditInputRejectsInvalidFields(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg}
	tests := []struct {
		name      string
		date      string
		postDate  string
		amount    string
		currency  string
		direction string
		message   string
	}{
		{name: "invalid transaction date", date: "2025-04-09", message: "交易日期无效"},
		{name: "invalid post date", postDate: "2025-04-10", message: "入账日期无效"},
		{name: "invalid currency", currency: "HK", message: "币种无效"},
		{name: "positive debit", amount: "18.00", message: "DEBIT 金额应为负数"},
		{name: "negative credit", amount: "-18.00", direction: "CREDIT", message: "CREDIT 金额应为正数"},
		{name: "unknown direction", direction: "CHARGE", message: "收支方向无效"},
		{name: "scientific amount", amount: "-1e3", message: "账单金额无效"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			input := filepath.Join(t.TempDir(), "hsbc-credit.csv")
			date := valueOr(test.date, "09/04/2025")
			postDate := valueOr(test.postDate, "10/04/2025")
			amount := valueOr(test.amount, "-18.00")
			currency := valueOr(test.currency, "HKD")
			direction := valueOr(test.direction, "DEBIT")
			text := strings.Join([]string{
				strings.Join(hsbchkCreditCSVHeaders, ","),
				strings.Join([]string{date, postDate, "TEST", amount, currency, "POSTED", "TEST", "HONG KONG", "HKG", direction}, ","),
			}, "\n")
			mustWrite(t, input, text)
			if _, err := server.prepareHsbcHKCreditInput(input, "hsbchk-invalid"); err == nil || !strings.Contains(err.Error(), test.message) {
				t.Fatalf("error = %v, want %q", err, test.message)
			}
		})
	}

	input := filepath.Join(t.TempDir(), "hsbc-credit.csv")
	headers := append([]string(nil), hsbchkCreditCSVHeaders...)
	headers[3] = "Transaction amount"
	mustWrite(t, input, strings.Join(headers, ",")+"\n")
	if _, err := server.prepareHsbcHKCreditInput(input, "hsbchk-invalid-header"); err == nil || !strings.Contains(err.Error(), `"Billing amount"`) {
		t.Fatalf("header error = %v", err)
	}
}

func hsbchkCreditCSVFixture(withBOM bool) []byte {
	text := strings.Join([]string{
		strings.Join(hsbchkCreditCSVHeaders, ","),
		`09/04/2025,10/04/2025,QR HSBC HK TEST,"-1,099.14"	,HKD,POSTED,香港商戶,HONG KONG,HKG,DEBIT`,
		`08/04/2025,09/04/2025,FOREIGN PURCHASE,"-18.00"	,CNY,POSTED,FOREIGN MERCHANT,CHINA,CHN,DEBIT`,
		`31/03/2025,01/04/2025,RETURN: TEST,"25.00"	,HKD,POSTED,TEST SHOP,HONG KONG,HKG,CREDIT`,
		`24/03/2025,24/03/2025,PAYMENT - THANK YOU,"3,266.16"	,HKD,POSTED,,,,CREDIT`,
	}, "\r\n") + "\r\n"
	raw := []byte(text)
	if !withBOM {
		return raw
	}
	return append([]byte{0xEF, 0xBB, 0xBF}, raw...)
}
