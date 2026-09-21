// Package boundedstream verifies the independent bounded-v1 canonical JSONL
// interchange format. It does not perform accounting validation or authenticate
// source files: source_digest is an assertion by the exporter, not a signature.
package boundedstream

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxRecordBytes = 1 << 20 // Includes the terminating LF.
	MaxValueDepth  = 16      // A typed root has depth zero.
	maxJSONDepth   = 40      // Enough for 16 nested typed wrappers, not arbitrary JSON.
)

var (
	ErrInvalid     = errors.New("invalid bounded stream")
	ErrRead        = errors.New("bounded stream read failed")
	ErrVisitor     = errors.New("bounded stream visitor failed")
	decimalPattern = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)
	integerPattern = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)$`)
	runtimePattern = regexp.MustCompile(`^beancount/[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+-]* python/[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+-]*$`)
)

// Record is one structurally validated record. Raw owns its bytes (without LF)
// and can be retained by the visitor. ALL callbacks are provisional until Verify
// returns success, including the footer callback. A future builder must stage
// changes and publish atomically only after success; it must also bound its own
// retained data. The verifier never keeps a collection of records or entry IDs.
type Record struct {
	Type string
	Raw  json.RawMessage
}

// Summary contains no ledger values or source paths. Records excludes the footer;
// Bytes and MaxRecordBytes include it. All fields are zero on any failure.
type Summary struct {
	Version        int    `json:"version"`
	Records        int64  `json:"records"`
	Directives     int64  `json:"directives"`
	Postings       int64  `json:"postings"`
	Options        int64  `json:"options"`
	Commodities    int64  `json:"commodities"`
	Metadata       int64  `json:"metadata"`
	Bytes          int64  `json:"bytes"`
	MaxRecordBytes int    `json:"max_record_bytes"`
	SHA256         string `json:"sha256"`
	SourceDigest   string `json:"source_digest"`
}

// Verify reads at most one bounded record at a time. Context is checked before
// reading each record and invoking its visitor. Cancellation cannot interrupt a
// blocked arbitrary io.Reader or visitor; callers must arrange their own I/O
// deadlines. Reader/visitor errors are deliberately not interpolated or wrapped:
// they may contain financial data or private paths. Use ErrRead/ErrVisitor with
// errors.Is. No partial summary is returned on error.
func Verify(ctx context.Context, input io.Reader, visit func(Record) error) (Summary, error) {
	if ctx == nil || input == nil {
		return Summary{}, invalid(1, "missing context or reader")
	}
	// Hide an existing *bufio.Reader so NewReaderSize cannot reuse a larger
	// caller buffer and scan beyond our own hard record bound.
	reader := bufio.NewReaderSize(struct{ io.Reader }{input}, MaxRecordBytes)
	digest := sha256.New()
	var s Summary
	var phase int // 0 header, 1 options, 2 commodities, 3 directives
	var current, ordinal int64
	ordinal = -1
	var transaction bool
	var lastCommodity, lastKey string
	var haveKey bool
	for {
		if err := ctx.Err(); err != nil {
			return Summary{}, err
		}
		n := s.Records + 1
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) || len(line) > MaxRecordBytes {
			return Summary{}, invalid(n, "record exceeds byte limit")
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return Summary{}, invalid(n, "missing footer or incomplete line")
			}
			return Summary{}, fmt.Errorf("record %d: %w", n, ErrRead)
		}
		if err := ctx.Err(); err != nil {
			return Summary{}, err
		}
		if !utf8.Valid(line) || !validEscapes(line) {
			return Summary{}, invalid(n, "invalid Unicode")
		}
		obj, ok := parseObject(line)
		if !ok {
			return Summary{}, invalid(n, "invalid JSON object or duplicate key")
		}
		kind, ok := obj["type"].(string)
		if !ok {
			return Summary{}, invalid(n, "missing record type")
		}
		if phase == 0 && kind != "header" {
			return Summary{}, invalid(n, "header must be first")
		}
		valid := false
		switch kind {
		case "header":
			version, vok := int64Value(obj["version"])
			valid = phase == 0 && fields(obj, "type version source_digest entry_file runtime exporter", "") && vok && version == 1 &&
				isDigest(obj["source_digest"]) && safePath(obj["entry_file"], false) && isRuntime(obj["runtime"]) && obj["exporter"] == "bounded-v1"
			if valid {
				phase = 1
				s.Version = 1
				s.SourceDigest = obj["source_digest"].(string)
			}
		case "option":
			valid = phase == 1 && fields(obj, "type key value", "") && isString(obj["key"]) && isString(obj["value"])
			if valid {
				key := obj["key"].(string)
				if key == "filename" || key == "include" || key == "documents" {
					valid = (key == "documents" && obj["value"] == ".") || safePath(obj["value"], true)
				}
			}
			s.Options++
		case "commodity":
			valid = phase <= 2 && fields(obj, "type value", "") && nonemptyString(obj["value"])
			if valid {
				v := obj["value"].(string)
				valid = s.Commodities == 0 || v > lastCommodity
				lastCommodity = v
			}
			phase = 2
			s.Commodities++
		case "directive":
			id, iok := int64Value(obj["id"])
			v, dok := obj["value"].(map[string]any)
			valid = fields(obj, "type id value", "") && iok && id == current+1 && dok && directive(v)
			if valid {
				current = id
				ordinal = -1
				transaction = v["Kind"] == "transaction"
				haveKey = false
				lastKey = ""
			}
			phase = 3
			s.Directives++
		case "posting":
			id, iok := int64Value(obj["entry_id"])
			o, ook := int64Value(obj["ordinal"])
			v, pok := obj["value"].(map[string]any)
			valid = phase == 3 && transaction && fields(obj, "type entry_id ordinal value", "") && iok && id == current && ook && o == ordinal+1 && pok && posting(v)
			if valid {
				ordinal = o
				haveKey = false
				lastKey = ""
			}
			s.Postings++
		case "metadata":
			id, iok := int64Value(obj["entry_id"])
			o, ook := int64Value(obj["posting"])
			key, kok := obj["key"].(string)
			valid = phase == 3 && fields(obj, "type entry_id posting key value", "") && iok && id == current && ook && o == ordinal && kok &&
				key != "filename" && key != "lineno" && !strings.HasPrefix(key, "__") && (!haveKey || key > lastKey) && typed(obj["value"], 0, false)
			if valid {
				haveKey = true
				lastKey = key
			}
			s.Metadata++
		case "footer":
			r, rok := int64Value(obj["records"])
			d, dok := int64Value(obj["directives"])
			p, pok := int64Value(obj["postings"])
			s.SHA256 = hex.EncodeToString(digest.Sum(nil))
			valid = fields(obj, "type records directives postings sha256", "") && rok && dok && pok && r == s.Records && d == s.Directives && p == s.Postings && isDigest(obj["sha256"]) && obj["sha256"] == s.SHA256
		default:
			return Summary{}, invalid(n, "unknown record type")
		}
		if !valid {
			return Summary{}, invalid(n, "schema, ordering, or integrity violation")
		}
		s.Bytes += int64(len(line))
		if len(line) > s.MaxRecordBytes {
			s.MaxRecordBytes = len(line)
		}
		if kind != "footer" {
			digest.Write(line)
			s.Records++
		}
		if err := ctx.Err(); err != nil {
			return Summary{}, err
		}
		if visit != nil {
			if err := visit(Record{Type: kind, Raw: append(json.RawMessage(nil), line[:len(line)-1]...)}); err != nil {
				return Summary{}, fmt.Errorf("record %d: %w", n, ErrVisitor)
			}
		}
		if kind == "footer" {
			if err := ctx.Err(); err != nil {
				return Summary{}, err
			}
			_, err := reader.ReadByte()
			if err == nil {
				return Summary{}, invalid(n, "bytes after footer")
			}
			if !errors.Is(err, io.EOF) {
				return Summary{}, fmt.Errorf("record %d: %w", n, ErrRead)
			}
			if err := ctx.Err(); err != nil {
				return Summary{}, err
			}
			return s, nil
		}
	}
}

func invalid(n int64, reason string) error {
	return fmt.Errorf("record %d: %w: %s", n, ErrInvalid, reason)
}

// Decode a token tree with duplicate detection at EVERY object, without losing
// integer precision. Maps are bounded by this one <=1MiB record, never a stream
// wide seen-ID/key set. Depth is checked before descending.
func parseObject(line []byte) (map[string]any, bool) {
	d := json.NewDecoder(bytes.NewReader(line))
	d.UseNumber()
	v, ok := jsonValue(d, 0)
	if !ok {
		return nil, false
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, false
	}
	obj, ok := v.(map[string]any)
	return obj, ok
}

func jsonValue(d *json.Decoder, depth int) (any, bool) {
	if depth > maxJSONDepth {
		return nil, false
	}
	t, err := d.Token()
	if err != nil {
		return nil, false
	}
	delim, container := t.(json.Delim)
	if !container {
		return t, true
	}
	switch delim {
	case '{':
		obj := make(map[string]any)
		for d.More() {
			t, err := d.Token()
			if err != nil {
				return nil, false
			}
			key, ok := t.(string)
			if !ok {
				return nil, false
			}
			if _, exists := obj[key]; exists {
				return nil, false
			}
			v, ok := jsonValue(d, depth+1)
			if !ok {
				return nil, false
			}
			obj[key] = v
		}
		end, err := d.Token()
		return obj, err == nil && end == json.Delim('}')
	case '[':
		items := make([]any, 0)
		for d.More() {
			v, ok := jsonValue(d, depth+1)
			if !ok {
				return nil, false
			}
			items = append(items, v)
		}
		end, err := d.Token()
		return items, err == nil && end == json.Delim(']')
	default:
		return nil, false
	}
}

// encoding/json replaces lone UTF-16 surrogates with U+FFFD. Reject them instead
// of silently changing source strings. All other JSON escape syntax is checked
// by the decoder. Escaped backslashes must not be mistaken for Unicode escapes.
func validEscapes(b []byte) bool {
	for i := 0; i < len(b); i++ {
		if b[i] != '\\' {
			continue
		}
		i++
		if i >= len(b) {
			return false
		}
		if b[i] != 'u' {
			continue
		}
		if i+4 >= len(b) {
			return false
		}
		n, err := strconv.ParseUint(string(b[i+1:i+5]), 16, 16)
		if err != nil {
			return false
		}
		i += 4
		if n >= 0xDC00 && n <= 0xDFFF {
			return false
		}
		if n >= 0xD800 && n <= 0xDBFF {
			if i+6 >= len(b) || b[i+1] != '\\' || b[i+2] != 'u' {
				return false
			}
			low, err := strconv.ParseUint(string(b[i+3:i+7]), 16, 16)
			if err != nil || low < 0xDC00 || low > 0xDFFF {
				return false
			}
			i += 6
		}
	}
	return true
}

func fields(obj map[string]any, required, optional string) bool {
	for _, k := range strings.Fields(required) {
		if _, ok := obj[k]; !ok {
			return false
		}
	}
	allowed := " " + required + " " + optional + " "
	for k := range obj {
		if k == "" || strings.ContainsAny(k, " \t\r\n") || !strings.Contains(allowed, " "+k+" ") {
			return false
		}
	}
	return true
}
func isString(v any) bool       { _, ok := v.(string); return ok }
func nonemptyString(v any) bool { s, ok := v.(string); return ok && s != "" }
func int64Value(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok || !integerPattern.MatchString(string(n)) {
		return 0, false
	}
	i, err := strconv.ParseInt(string(n), 10, 64)
	return i, err == nil
}
func isDecimal(v any) bool { s, ok := v.(string); return ok && decimalPattern.MatchString(s) }
func isDate(v any) bool {
	s, ok := v.(string)
	if !ok || len(s) != 10 {
		return false
	}
	t, err := time.Parse("2006-01-02", s)
	return err == nil && t.Year() >= 1 && t.Format("2006-01-02") == s
}
func isDigest(v any) bool {
	s, ok := v.(string)
	if !ok || len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func isRuntime(v any) bool { s, ok := v.(string); return ok && runtimePattern.MatchString(s) }
func safePath(v any, empty bool) bool {
	s, ok := v.(string)
	if !ok {
		return false
	}
	if s == "" {
		return empty
	}
	if strings.ContainsAny(s, "\\:") {
		return false
	}
	for _, c := range s {
		if c < 32 || c == 127 {
			return false
		}
	}
	for _, part := range strings.Split(s, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
func amount(v any) bool {
	obj, ok := v.(map[string]any)
	return ok && fields(obj, "Number Currency", "") && isDecimal(obj["Number"]) && nonemptyString(obj["Currency"])
}
func stringList(v any, sorted bool) bool {
	list, ok := v.([]any)
	if !ok {
		return false
	}
	last := ""
	for i, item := range list {
		s, ok := item.(string)
		if !ok || (sorted && i > 0 && s <= last) {
			return false
		}
		last = s
	}
	return true
}

func typed(v any, depth int, custom bool) bool {
	if depth > MaxValueDepth {
		return false
	}
	obj, ok := v.(map[string]any)
	if !ok || !fields(obj, "type value", "") {
		return false
	}
	value := obj["value"]
	switch obj["type"] {
	case "decimal":
		return isDecimal(value)
	case "date":
		return isDate(value)
	case "str":
		return isString(value)
	case "account":
		return custom && depth == 0 && isString(value)
	case "bool":
		_, ok := value.(bool)
		return ok
	case "int":
		n, ok := value.(json.Number)
		return ok && integerPattern.MatchString(string(n))
	case "none":
		return value == nil
	case "amount":
		return amount(value)
	case "list":
		items, ok := value.([]any)
		if !ok {
			return false
		}
		for _, item := range items {
			if !typed(item, depth+1, false) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

// Required fields below match non-null fields produced for Beancount's known
// directives. Optional fields are omitted by Python when their value is None;
// explicit nulls are never a substitute for omission.
func directive(v map[string]any) bool {
	kind, ok := v["Kind"].(string)
	if !ok {
		return false
	}
	required, optional := "Kind Date File Line", ""
	switch kind {
	case "open":
		required += " Account"
		optional = "Currencies Booking"
	case "close":
		required += " Account"
	case "commodity":
		required += " Currency"
	case "pad":
		required += " Account Account2"
	case "balance":
		required += " Account Currency AmountValue"
		optional = "Tolerance DiffAmount"
	case "transaction":
		required += " Flag Narration Tags Links"
		optional = "Payee"
	case "note":
		required += " Account Narration Tags Links"
	case "event":
		required += " Name Value"
	case "query":
		required += " Name Value"
	case "price":
		required += " Currency QuoteCurrency AmountValue"
	case "document":
		required += " Account Filename Tags Links"
	case "custom":
		required += " CustomType CustomValues"
	default:
		return false
	}
	if !fields(v, required, optional) || !isDate(v["Date"]) || !safePath(v["File"], true) {
		return false
	}
	line, ok := int64Value(v["Line"])
	if !ok || line < 0 {
		return false
	}
	for key, value := range v {
		switch key {
		case "Kind", "Date", "File", "Line":
		case "Currencies":
			if !stringList(value, false) {
				return false
			}
		case "Tags", "Links":
			if !stringList(value, true) {
				return false
			}
		case "AmountValue", "DiffAmount":
			if !amount(value) {
				return false
			}
		case "Tolerance":
			if !isDecimal(value) {
				return false
			}
		case "Filename":
			if !safePath(value, false) {
				return false
			}
		case "CustomValues":
			items, ok := value.([]any)
			if !ok {
				return false
			}
			for _, item := range items {
				if !typed(item, 0, true) {
					return false
				}
			}
		case "Booking":
			s, ok := value.(string)
			if !ok || !strings.Contains(" STRICT STRICT_WITH_SIZE NONE AVERAGE FIFO LIFO HIFO ", " "+s+" ") || strings.ContainsAny(s, " \t\n\r") || s == "" {
				return false
			}
		default:
			if !isString(value) {
				return false
			}
		}
	}
	if kind == "balance" || kind == "price" {
		currency := "Currency"
		if kind == "price" {
			currency = "QuoteCurrency"
		}
		if v[currency] != v["AmountValue"].(map[string]any)["Currency"] {
			return false
		}
		if diff, ok := v["DiffAmount"].(map[string]any); ok && diff["Currency"] != v["Currency"] {
			return false
		}
	}
	return true
}

func posting(v map[string]any) bool {
	if !fields(v, "account Quantity", "flag Cost CostDate CostLabel Price") || !nonemptyString(v["account"]) || !amount(v["Quantity"]) {
		return false
	}
	for key, value := range v {
		switch key {
		case "Cost", "Price":
			if !amount(value) {
				return false
			}
		case "CostDate":
			if _, ok := v["Cost"]; !ok || !isDate(value) {
				return false
			}
		case "CostLabel":
			if _, ok := v["Cost"]; !ok || !isString(value) {
				return false
			}
		case "flag":
			if !nonemptyString(value) {
				return false
			}
		}
	}
	return true
}
