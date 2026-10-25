package app

import (
	"bytes"
	"crypto/sha256"
	"reflect"
	"strings"
	"testing"
)

func roundTripModel(t *testing.T, model *LocalCanonicalModel) *LocalCanonicalModel {
	t.Helper()
	encoded, err := EncodeCanonicalSnapshot(model, sha256.Sum256([]byte("source")), 1234,
		"beancount@3.2.3", "runtime-1", 99)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, err := DecodeCanonicalSnapshot(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return decoded.model
}

// A stream fixture that touches every encoded field, including the variants
// that only appear in real ledgers.
const snapshotFixtureStream = `{"type":"header","version":1}
{"type":"option","key":"title","value":"Synthetic"}
{"type":"option","key":"operating_currency","value":"CNY"}
{"type":"commodity","value":"CNY"}
{"type":"commodity","value":"USD"}
{"type":"entry","entry":{"Kind":"open","Date":"2020-01-01","File":"accounts.bean","Line":1,"Account":"Assets:Cash","Currencies":["CNY","USD"]}}
{"type":"end_entry"}
{"type":"entry","entry":{"Kind":"transaction","Date":"2026-10-24","File":"transactions/2026-10.bean","Line":12,"Flag":"*","Payee":"雇主","Narration":"月度工资","Tags":["work"],"Links":["batch-1"],"Metadata":{"id":"tx-1","amount":12.5,"count":3,"ok":true,"missing":null,"nested":["a","b"]}}}
{"type":"posting","posting":{"account":"Assets:Cash","quantity":{"Number":"1234.56","Currency":"CNY"}}}
{"type":"posting","posting":{"account":"Income:Salary","quantity":{"Number":"-1234.56","Currency":"CNY"},"cost":{"Number":"7.10","Currency":"USD"},"costCurrency":"USD","costAmount":710}}
{"type":"end_entry"}
{"type":"entry","entry":{"Kind":"balance","Date":"2026-10-25","File":"transactions/2026-10.bean","Line":30,"Account":"Assets:Cash","Currency":"CNY","AmountValue":{"Number":"1234.56","Currency":"CNY"},"Tolerance":"0.01"}}
{"type":"end_entry"}
{"type":"entry","entry":{"Kind":"price","Date":"2026-10-25","File":"prices.bean","Line":3,"Currency":"USD","AmountValue":{"Number":"7.1","Currency":"CNY"},"QuoteCurrency":"CNY"}}
{"type":"end_entry"}
{"type":"entry","entry":{"Kind":"custom","Date":"2026-10-26","File":"main.bean","Line":5,"CustomType":"budget","CustomValues":["food",42,true]}}
{"type":"end_entry"}
{"type":"footer","entries":5,"sha256":"ignored"}
`

func streamModel(t *testing.T, stream string) *LocalCanonicalModel {
	t.Helper()
	// Drop the sentinel footer: ReadLocalCanonicalStream verifies the digest.
	lines := strings.Split(strings.TrimSpace(stream), "\n")
	body := strings.Join(lines[:len(lines)-1], "\n") + "\n"
	digest := sha256.Sum256([]byte(body))
	footer := `{"type":"footer","entries":5,"sha256":"` + hexDigest(digest) + `"}` + "\n"
	model, err := ReadLocalCanonicalStream(strings.NewReader(body + footer))
	if err != nil {
		t.Fatalf("read stream: %v", err)
	}
	return model
}

func hexDigest(sum [32]byte) string {
	const hexDigits = "0123456789abcdef"
	out := make([]byte, 0, 64)
	for _, b := range sum {
		out = append(out, hexDigits[b>>4], hexDigits[b&0xf])
	}
	return string(out)
}

// The snapshot must reproduce exactly what the stream decoder produces; this is
// the gate that keeps the two paths from drifting apart.
func TestSnapshotRoundTripMatchesStream(t *testing.T) {
	want := streamModel(t, snapshotFixtureStream)
	got := roundTripModel(t, want)
	if !reflect.DeepEqual(want, got) {
		t.Fatalf("round trip differs from stream decode\nwant: %#v\ngot:  %#v", want, got)
	}
	if len(got.Entries) != len(want.Entries) {
		t.Fatalf("entry count %d, want %d", len(got.Entries), len(want.Entries))
	}
}

// Encoding the same model twice must produce identical bytes so cache identity
// stays comparable across runs.
func TestSnapshotEncodeIsDeterministic(t *testing.T) {
	model := streamModel(t, snapshotFixtureStream)
	version := sha256.Sum256([]byte("source"))
	first, err := EncodeCanonicalSnapshot(model, version, 1234, "beancount@3.2.3", "runtime-1", 99)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	second, err := EncodeCanonicalSnapshot(model, version, 1234, "beancount@3.2.3", "runtime-1", 99)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("encoding is not deterministic")
	}
}

// The header carries the source identity; a reader rejects a snapshot whose
// recorded version does not match the ledger it is being registered for.
func TestSnapshotHeaderRoundTrip(t *testing.T) {
	model := streamModel(t, snapshotFixtureStream)
	version := sha256.Sum256([]byte("source-tree"))
	encoded, err := EncodeCanonicalSnapshot(model, version, 4096, "beancount@3.2.3", "runtime-9", 12345)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, err := DecodeCanonicalSnapshot(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if decoded.sourceVersion != version {
		t.Fatal("source version did not round trip")
	}
	if decoded.sourceBytes != 4096 || decoded.exporterID != "beancount@3.2.3" ||
		decoded.appRuntimeFP != "runtime-9" || decoded.createdAt != 12345 {
		t.Fatalf("header metadata did not round trip: %+v", decoded)
	}
}

func TestSnapshotDateRoundTrip(t *testing.T) {
	for _, value := range []string{"1970-01-01", "2000-02-29", "2026-10-24", "1999-12-31", "2038-01-19"} {
		day, err := dateToDay(value)
		if err != nil {
			t.Fatalf("dateToDay(%q): %v", value, err)
		}
		back, err := dayToDate(day)
		if err != nil {
			t.Fatalf("dayToDate(%d): %v", day, err)
		}
		if back != value {
			t.Fatalf("date round trip %q -> %d -> %q", value, day, back)
		}
	}
	for _, bad := range []string{"", "2026-13-01", "2026-02-30", "2026-1-01", "not-a-date", "2026-00-10"} {
		if _, err := dateToDay(bad); err == nil {
			t.Fatalf("dateToDay(%q) accepted an invalid date", bad)
		}
	}
}

// Fixed-point encoding must be exact for the shapes real ledgers use, and fall
// back to literal text instead of rounding anything else.
func TestSnapshotAmountRoundTrip(t *testing.T) {
	for _, value := range []string{"0", "1", "-1", "1234.56", "-1234.56", "7.1", "0.01", "100.000",
		"1234567890123456789.123456789", "3.14159265358979", "-0.5", "1000000"} {
		enc := newSnapshotEncoder()
		encoded, err := appendSnapshotAmount(nil, BeanAmount{Number: value}, enc)
		if err != nil {
			t.Fatalf("encode %q: %v", value, err)
		}
		reader := &snapshotReader{buf: encoded}
		decoder := &snapshotEntryDecoder{}
		number, err := decoder.amountNumber(reader)
		if err != nil {
			t.Fatalf("decode %q: %v", value, err)
		}
		if number != value {
			t.Fatalf("amount round trip %q -> %q", value, number)
		}
	}
	// Values outside the fixed-point range must use the text fallback.
	for _, value := range []string{"1e10", "abc", "1.2345678901", "", "1,5"} {
		if _, ok := encodeFixedPoint(value); ok {
			// "" is representable; the rest must not be.
			if value != "" {
				t.Fatalf("encodeFixedPoint(%q) should have fallen back", value)
			}
		}
	}
}
