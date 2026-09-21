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

func TestExactDecimalAddDecimalMaxScale(t *testing.T) {
	for _, sign := range []string{"", "-"} {
		t.Run("sign="+sign, func(t *testing.T) {
			var operand, sum, lexical ExactDecimal
			if err := operand.Add(sign + "." + strings.Repeat("0", MaxExactDecimalDigits-1) + "1"); err != nil {
				t.Fatal(err)
			}
			before, coefficient, scale := operand.String(), operand.coefficient.String(), operand.scale
			if err := lexical.Add(before); !errors.Is(err, ErrDecimalLimit) {
				t.Fatalf("normalized spelling must still exceed raw digit budget: %v", err)
			}
			for n := 1; n <= 2; n++ {
				if err := sum.AddDecimal(&operand); err != nil {
					t.Fatal(err)
				}
				want := sign + "0." + strings.Repeat("0", MaxExactDecimalDigits-1) + string(rune('0'+n))
				if sum.String() != want {
					t.Fatal("incorrect maximal-scale sum")
				}
				if operand.String() != before || operand.coefficient.String() != coefficient || operand.scale != scale {
					t.Fatal("addition mutated operand")
				}
			}
			// The destination and operand must not share mutable coefficient storage.
			if err := sum.AddDecimal(&sum); err != nil {
				t.Fatal(err)
			}
			if operand.String() != before || sum.coefficient.String() != sign+"4" || sum.scale != scale {
				t.Fatal("self-addition or operand isolation failed")
			}
		})
	}
}

func TestExactDecimalAddDecimalFailureAtomicity(t *testing.T) {
	large := strings.Repeat("9", MaxExactDecimalDigits)
	for _, sign := range []string{"", "-"} {
		for _, tc := range []struct{ name, initial, incoming string }{
			{"integer carry", large, "1"},
			{"fractional carry", strings.Repeat("9", MaxExactDecimalDigits-1) + ".9", ".2"},
			{"destination alignment", large, ".1"},
			{"operand alignment", ".1", large},
		} {
			t.Run(sign+tc.name, func(t *testing.T) {
				var d, operand ExactDecimal
				if err := d.Add(sign + tc.initial); err != nil {
					t.Fatal(err)
				}
				if err := operand.Add(sign + tc.incoming); err != nil {
					t.Fatal(err)
				}
				value, coefficient, scale := d.String(), d.coefficient.String(), d.scale
				otherValue, otherCoefficient, otherScale := operand.String(), operand.coefficient.String(), operand.scale
				if err := d.AddDecimal(&operand); !errors.Is(err, ErrDecimalLimit) {
					t.Fatalf("want resource limit: %v", err)
				}
				if d.String() != value || d.coefficient.String() != coefficient || d.scale != scale || operand.String() != otherValue || operand.coefficient.String() != otherCoefficient || operand.scale != otherScale {
					t.Fatal("failed addition mutated destination or operand")
				}
				var inverse ExactDecimal
				opposite := "-"
				if sign == "-" {
					opposite = ""
				}
				if err := inverse.Add(opposite + tc.initial); err != nil {
					t.Fatal(err)
				}
				if err := d.AddDecimal(&inverse); err != nil || d.String() != "0" || d.scale != 0 {
					t.Fatal("accumulator failed to recover", err)
				}
			})
		}
	}
}

func TestExactDecimalAddDecimalSelfAndNormalization(t *testing.T) {
	for _, tc := range []struct{ name, raw, want string }{
		{"zero", "0", "0"},
		{"fraction", ".25", "0.5"},
		{"negative", "-.25", "-0.5"},
		{"normalize", ".5", "1"},
		{"overflow", strings.Repeat("9", MaxExactDecimalDigits), ""},
		{"negative overflow", "-" + strings.Repeat("9", MaxExactDecimalDigits), ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var d ExactDecimal
			if err := d.Add(tc.raw); err != nil {
				t.Fatal(err)
			}
			coefficient, scale := d.coefficient.String(), d.scale
			err := d.AddDecimal(&d)
			if tc.want == "" {
				if !errors.Is(err, ErrDecimalLimit) || d.coefficient.String() != coefficient || d.scale != scale {
					t.Fatal("self-addition failure was not atomic", err)
				}
			} else if err != nil || d.String() != tc.want {
				t.Fatal("incorrect self-addition", err)
			}
		})
	}
	// A fractional carry is normalized before enforcing the coefficient limit.
	var tiny, complement ExactDecimal
	if err := tiny.Add("." + strings.Repeat("0", MaxExactDecimalDigits-1) + "1"); err != nil {
		t.Fatal(err)
	}
	if err := complement.Add("." + strings.Repeat("9", MaxExactDecimalDigits)); err != nil {
		t.Fatal(err)
	}
	before := complement.String()
	if err := tiny.AddDecimal(&complement); err != nil || tiny.String() != "1" || tiny.scale != 0 {
		t.Fatal("boundary carry not normalized", err)
	}
	if complement.String() != before {
		t.Fatal("normalization mutated operand")
	}
}
