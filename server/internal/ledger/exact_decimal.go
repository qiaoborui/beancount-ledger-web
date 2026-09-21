package ledger

import (
	"math/big"
	"strings"
)

const (
	// Explicit arithmetic budgets, independent of the stream's record limit.
	// Canonical projection storage does not apply these limits or alter spelling.
	MaxExactDecimalDigits   = 4096
	MaxExactDecimalExponent = 1024
)

type decimalError string

func (e decimalError) Error() string { return string(e) }

var (
	ErrDecimalSyntax = decimalError("invalid exact decimal")
	ErrDecimalLimit  = decimalError("exact decimal resource limit exceeded")
)

// ExactDecimal is a bounded base-ten accumulator. Its zero value is zero.
// It accepts only finite canonical decimal notation, not Rat's fractions or
// base prefixes, and never rounds. Failed additions leave the accumulator unchanged.
// Not safe for concurrent use. String emits normalized plain decimal notation.
type ExactDecimal struct {
	coefficient big.Int
	scale       int
}

func decimalParts(raw string) (*big.Int, int, error) {
	if len(raw) > MaxExactDecimalDigits+32 {
		return nil, 0, ErrDecimalLimit
	}
	s := raw
	negative := false
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		negative = s[0] == '-'
		s = s[1:]
	}
	var digits strings.Builder
	frac, dot, count := 0, false, 0
	i := 0
	for i < len(s) && s[i] != 'e' && s[i] != 'E' {
		c := s[i]
		i++
		if c == '.' && !dot {
			dot = true
			continue
		}
		if c < '0' || c > '9' {
			return nil, 0, ErrDecimalSyntax
		}
		count++
		if count > MaxExactDecimalDigits {
			return nil, 0, ErrDecimalLimit
		}
		digits.WriteByte(c)
		if dot {
			frac++
		}
	}
	if count == 0 {
		return nil, 0, ErrDecimalSyntax
	}
	exp := 0
	if i < len(s) {
		i++
		sign := 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			if s[i] == '-' {
				sign = -1
			}
			i++
		}
		if i == len(s) {
			return nil, 0, ErrDecimalSyntax
		}
		for ; i < len(s); i++ {
			if s[i] < '0' || s[i] > '9' {
				return nil, 0, ErrDecimalSyntax
			}
			exp = exp*10 + int(s[i]-'0')
			if exp > MaxExactDecimalExponent {
				return nil, 0, ErrDecimalLimit
			}
		}
		exp *= sign
	}
	scale := frac - exp
	text := strings.TrimLeft(digits.String(), "0")
	if text == "" {
		return new(big.Int), 0, nil
	}
	// Strip fractional trailing zeros before alignment, without changing value.
	for scale > 0 && strings.HasSuffix(text, "0") {
		text = text[:len(text)-1]
		scale--
	}
	if scale < 0 {
		if len(text)-scale > MaxExactDecimalDigits {
			return nil, 0, ErrDecimalLimit
		}
		text += strings.Repeat("0", -scale)
		scale = 0
	}
	if scale > MaxExactDecimalDigits {
		return nil, 0, ErrDecimalLimit
	}
	n, ok := new(big.Int).SetString(text, 10)
	if !ok {
		return nil, 0, ErrDecimalSyntax
	}
	if negative {
		n.Neg(n)
	}
	return n, scale, nil
}

func alignDecimal(n *big.Int, places int) (*big.Int, error) {
	if n.Sign() == 0 {
		return new(big.Int), nil
	}
	if len(n.Text(10))-btoi(n.Sign() < 0)+places > MaxExactDecimalDigits {
		return nil, ErrDecimalLimit
	}
	out := new(big.Int).Set(n)
	if places > 0 {
		out.Mul(out, new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil))
	}
	return out, nil
}
func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (d *ExactDecimal) Add(raw string) error {
	n, scale, err := decimalParts(raw)
	if err != nil {
		return err
	}
	return d.addParts(n, scale)
}

// AddDecimal adds an already validated exact value without reparsing its display
// spelling. It applies the same arithmetic budgets as Add and leaves both values
// unchanged on failure. The operand is not mutated unless it is d itself.
func (d *ExactDecimal) AddDecimal(other *ExactDecimal) error {
	return d.addParts(&other.coefficient, other.scale)
}

func (d *ExactDecimal) addParts(n *big.Int, scale int) error {
	target := max(scale, d.scale)
	a, err := alignDecimal(&d.coefficient, target-d.scale)
	if err != nil {
		return err
	}
	b, err := alignDecimal(n, target-scale)
	if err != nil {
		return err
	}
	// Each aligned operand has at most MaxExactDecimalDigits digits, so the
	// temporary sum is bounded by MaxExactDecimalDigits+1 (a single carry).
	a.Add(a, b)
	if a.Sign() == 0 {
		target = 0
	} else {
		// Normalize before the final coefficient budget and before retaining
		// scale: fractional zeros must not consume future alignment capacity.
		text := a.Text(10)
		normalized := text
		for target > 0 && strings.HasSuffix(normalized, "0") {
			normalized = normalized[:len(normalized)-1]
			target--
		}
		if len(normalized)-btoi(a.Sign() < 0) > MaxExactDecimalDigits {
			return ErrDecimalLimit
		}
		if normalized != text {
			a.SetString(normalized, 10)
		}
	}
	d.coefficient.Set(a)
	d.scale = target
	return nil
}

func (d *ExactDecimal) String() string {
	if d.coefficient.Sign() == 0 {
		return "0"
	}
	s := d.coefficient.Text(10)
	sign := ""
	if s[0] == '-' {
		sign = "-"
		s = s[1:]
	}
	if d.scale > 0 {
		if len(s) <= d.scale {
			s = strings.Repeat("0", d.scale-len(s)+1) + s
		}
		cut := len(s) - d.scale
		s = s[:cut] + "." + s[cut:]
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	return sign + s
}
