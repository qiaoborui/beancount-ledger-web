//go:build cgo

package mobilereadindex

import (
	"bytes"
	"encoding/json"
	"io"
	"reflect"
	"strings"
	"unicode/utf8"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

const (
	maxRequestBytes  = 4 << 10
	maxManifestBytes = 16 << 10
)

// These wire objects are flat. Reject null, duplicate/case-folded/unknown keys,
// wrong scalar types and trailing values rather than silently ignoring inputs.
func decodeObject(raw string, limit int, target any) error {
	bad := readindex.ErrInvalidRequest
	if len(raw) > limit || !utf8.ValidString(raw) {
		return bad
	}
	d := json.NewDecoder(strings.NewReader(raw))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return bad
	}
	typ := reflect.TypeOf(target).Elem()
	fields := make(map[string]bool, typ.NumField())
	for i := 0; i < typ.NumField(); i++ {
		fields[strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]] = false
	}
	for d.More() {
		token, err = d.Token()
		if err != nil {
			return bad
		}
		key, ok := token.(string)
		seen, known := fields[key]
		if !ok || !known || seen {
			return bad
		}
		fields[key] = true
		var value json.RawMessage
		if d.Decode(&value) != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return bad
		}
	}
	if token, err = d.Token(); err != nil || token != json.Delim('}') {
		return bad
	}
	if d.Decode(new(any)) != io.EOF {
		return bad
	}
	d = json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(target) != nil {
		return bad
	}
	return nil
}
