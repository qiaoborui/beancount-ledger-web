package ledger

import (
	"errors"
	"strings"
	"testing"
)

func TestExactDecimal(t *testing.T) {
	var d ExactDecimal
	for _, s := range []string{"12345678901234567890.000000000000000000000001", "-.000000000000000000000002", "+1e-24", "-12345678901234567890", "1.", ".25", "-2.5E-1"} {
		if err := d.Add(s); err != nil {
			t.Fatal(err)
		}
	}
	if d.String() != "1" {
		t.Fatal(d.String())
	}
	for _, s := range []string{"1/3", "0xff", "NaN", "Inf", ".", "", "1e", "1.2.3", "1 e2", "--1", "1e+"} {
		if err := d.Add(s); !errors.Is(err, ErrDecimalSyntax) {
			t.Fatalf("%q: %v", s, err)
		}
		if d.String() != "1" {
			t.Fatal("failed addition changed accumulator")
		}
	}
	for _, s := range []string{"1e1025", "1e-1025", "1e99999999999999999999", strings.Repeat("1", 4097), "0." + strings.Repeat("0", 4095) + "1e-1"} {
		if err := d.Add(s); !errors.Is(err, ErrDecimalLimit) {
			t.Fatalf("limit: %v", err)
		}
	}
	var edge ExactDecimal
	if err := edge.Add(strings.Repeat("9", 4096)); err != nil {
		t.Fatal(err)
	}
	if err := edge.Add("1"); !errors.Is(err, ErrDecimalLimit) {
		t.Fatal(err)
	}
	if edge.String() != strings.Repeat("9", 4096) {
		t.Fatal("overflow changed accumulator")
	}
	var tiny ExactDecimal
	if err := tiny.Add("1e-1024"); err != nil {
		t.Fatal(err)
	}
	if tiny.String() != "0."+strings.Repeat("0", 1023)+"1" {
		t.Fatal("tiny mismatch")
	}
	if err := tiny.Add("-1e-1024"); err != nil || tiny.String() != "0" {
		t.Fatal(err)
	}
}

func TestExactDecimalAlignmentLimitAndLongSum(t *testing.T) {
	var d ExactDecimal
	if err := d.Add(strings.Repeat("9", 4096)); err != nil {
		t.Fatal(err)
	}
	if err := d.Add("0.1"); !errors.Is(err, ErrDecimalLimit) {
		t.Fatal("alignment limit", err)
	}
	if d.String() != strings.Repeat("9", 4096) {
		t.Fatal("alignment changed accumulator")
	}
	var sum ExactDecimal
	for n := 0; n < 10000; n++ {
		if err := sum.Add("0.00000000000000000000000000000001"); err != nil {
			t.Fatal(err)
		}
	}
	if sum.String() != "0.0000000000000000000000000001" {
		t.Fatal(sum.String())
	}
	for _, s := range []string{"+0", "-0.000", "00e+0001", "1e1024", "-1e1024"} {
		if err := sum.Add(s); err != nil {
			t.Fatal(err)
		}
	}
	if sum.String() != "0.0000000000000000000000000001" {
		t.Fatal(sum.String())
	}
}

func TestExactDecimalNormalizesAccumulatedCoefficient(t *testing.T) {
	large := "1" + strings.Repeat("0", MaxExactDecimalDigits-1)
	tiny := "." + strings.Repeat("0", MaxExactDecimalDigits-1) + "1"
	complement := "." + strings.Repeat("9", MaxExactDecimalDigits)
	for _, sign := range []string{"", "-"} {
		for _, tc := range []struct {
			name        string
			parts       []string
			coefficient string
			scale       int
		}{
			{"fractional history", []string{".1", ".9"}, "1", 0},
			{"direct integer", []string{"1"}, "1", 0},
			{"boundary carry", []string{tiny, complement}, "1", 0},
			{"reverse boundary carry", []string{complement, tiny}, "1", 0},
			{"retained fraction", []string{".01", ".09"}, "1", 1},
			{"integer trailing zero", []string{"5", "5"}, "10", 0},
		} {
			t.Run(sign+tc.name, func(t *testing.T) {
				var d ExactDecimal
				for _, part := range tc.parts {
					if err := d.Add(sign + part); err != nil {
						t.Fatal(err)
					}
				}
				if d.coefficient.String() != sign+tc.coefficient || d.scale != tc.scale {
					t.Fatalf("coefficient=%s scale=%d; want %s scale=%d", &d.coefficient, d.scale, sign+tc.coefficient, tc.scale)
				}
				if tc.coefficient == "1" && tc.scale == 0 {
					if err := d.Add(sign + large); err != nil {
						t.Fatal(err)
					}
					want := sign + "1" + strings.Repeat("0", MaxExactDecimalDigits-2) + "1"
					if d.String() != want {
						t.Fatal("large sum mismatch")
					}
				}
			})
		}
	}
}

func TestExactDecimalNormalizationFailureAtomicity(t *testing.T) {
	large := strings.Repeat("9", MaxExactDecimalDigits)
	for _, sign := range []string{"", "-"} {
		for _, tc := range []struct{ name, initial, rejected string }{
			{"integer carry overflow", large, "1"},
			{"fractional carry overflow", strings.Repeat("9", MaxExactDecimalDigits-1) + ".9", ".2"},
			{"retained operand alignment", large, ".1"},
			{"incoming operand alignment", ".1", large},
		} {
			t.Run(sign+tc.name, func(t *testing.T) {
				var d ExactDecimal
				if err := d.Add(sign + tc.initial); err != nil {
					t.Fatal(err)
				}
				coefficient, scale, value := d.coefficient.String(), d.scale, d.String()
				if err := d.Add(sign + tc.rejected); !errors.Is(err, ErrDecimalLimit) {
					t.Fatalf("want resource limit, got %v", err)
				}
				if d.coefficient.String() != coefficient || d.scale != scale || d.String() != value {
					t.Fatal("failed addition changed accumulator")
				}
				opposite := "-"
				if sign == "-" {
					opposite = ""
				}
				if err := d.Add(opposite + tc.initial); err != nil {
					t.Fatal(err)
				}
				if d.coefficient.Sign() != 0 || d.scale != 0 || d.String() != "0" {
					t.Fatal("recovery did not normalize zero")
				}
				if err := d.Add("1"); err != nil || d.String() != "1" {
					t.Fatal("accumulator unusable after failure", err)
				}
			})
		}
	}
}
