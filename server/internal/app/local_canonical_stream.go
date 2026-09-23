package app

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
)

const localCanonicalRecordLimit = 1 << 20
const localCanonicalStreamLimit = 256 << 20

// ReadLocalCanonicalStream ingests a completed trusted exporter stream. The
// caller must supply a confined, owned file and verify the source revision.
// Only one record buffer exists; the resulting canonical model is still O(N).
// This function does NOT authorize registration or select an arbitrary path.
func ReadLocalCanonicalStream(input io.Reader) (*LocalCanonicalModel, error) {
	reader := bufio.NewReaderSize(io.LimitReader(input, localCanonicalStreamLimit+1), 64<<10)
	digest := sha256.New()
	model := &LocalCanonicalModel{Version: 1, Options: map[string]string{}, Entries: []BeanEntry{}, Commodities: []string{}}
	var pending *BeanEntry
	total, records := 0, 0
	entriesStarted := false
	fail := func() (*LocalCanonicalModel, error) { return nil, errors.New("invalid or incomplete canonical stream") }
	for {
		// ReadSlice bounds allocation even if the input has no newline.
		var line []byte
		for {
			fragment, err := reader.ReadSlice('\n')
			if len(line)+len(fragment) > localCanonicalRecordLimit {
				return fail()
			}
			line = append(line, fragment...)
			if err == bufio.ErrBufferFull {
				continue
			}
			if err != nil {
				return fail()
			}
			break
		}
		total += len(line)
		if total > localCanonicalStreamLimit {
			return fail()
		}
		var record struct {
			Type    string          `json:"type"`
			Version int             `json:"version"`
			Key     string          `json:"key"`
			Value   string          `json:"value"`
			Entry   json.RawMessage `json:"entry"`
			Posting json.RawMessage `json:"posting"`
			Entries int             `json:"entries"`
			SHA256  string          `json:"sha256"`
		}
		decoder := json.NewDecoder(bytes.NewReader(line))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&record) != nil {
			return fail()
		}
		if decoder.Decode(new(any)) != io.EOF {
			return fail()
		}
		if records == 0 && (record.Type != "header" || record.Version != 1) {
			return fail()
		}
		if record.Type == "footer" {
			if records == 0 || pending != nil || record.Entries != len(model.Entries) || record.SHA256 != hex.EncodeToString(digest.Sum(nil)) {
				return fail()
			}
			if _, err := reader.ReadByte(); err != io.EOF {
				return fail()
			}
			return model, nil
		}
		digest.Write(line)
		records++
		switch record.Type {
		case "header":
			if records != 1 || record.Version != 1 {
				return fail()
			}
		case "option":
			if entriesStarted || record.Key == "" {
				return fail()
			}
			if _, exists := model.Options[record.Key]; exists {
				return fail()
			}
			model.Options[record.Key] = record.Value
		case "commodity":
			if entriesStarted || record.Value == "" {
				return fail()
			}
			model.Commodities = append(model.Commodities, record.Value)
		case "entry":
			if pending != nil || len(record.Entry) == 0 {
				return fail()
			}
			entriesStarted = true
			var entry BeanEntry
			if json.Unmarshal(record.Entry, &entry) != nil || entry.Kind == "" || len(entry.Postings) != 0 {
				return fail()
			}
			if entry.Kind == "transaction" {
				entry.Postings = []parsedPosting{}
			}
			pending = &entry
		case "posting":
			if pending == nil || pending.Kind != "transaction" {
				return fail()
			}
			var posting parsedPosting
			if json.Unmarshal(record.Posting, &posting) != nil || posting.Account == "" || posting.Quantity.Number == "" || posting.Quantity.Currency == "" {
				return fail()
			}
			pending.Postings = append(pending.Postings, posting)
		case "end_entry":
			if pending == nil {
				return fail()
			}
			model.Entries = append(model.Entries, *pending)
			pending = nil
		default:
			return fail()
		}
	}
}
