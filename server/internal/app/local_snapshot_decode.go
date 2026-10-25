package app

// Binary canonical snapshot decoder.
//
// Every count is cross-checked against the bytes left in its section before any
// allocation, so a corrupt or hostile file cannot request a huge buffer. Any
// structural problem rejects the snapshot; the caller then re-reads the stream
// instead of trusting a partial model.

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math"
	"strconv"
)

const (
	snapshotMagicLength  = 8
	snapshotHeaderPrefix = snapshotMagicLength + 2 + 2 + 4 // magic, format, flags, header length
	snapshotSectionSize  = 10                               // u16 kind + u32 offset + u32 length
	snapshotDigestLength = 32
)

// snapshotReader walks one buffer with bounds checking.
type snapshotReader struct {
	buf []byte
	pos int
}

func (reader *snapshotReader) remaining() int { return len(reader.buf) - reader.pos }

func (reader *snapshotReader) u8() (byte, error) {
	if reader.remaining() < 1 {
		return 0, errSnapshotInvalid
	}
	value := reader.buf[reader.pos]
	reader.pos++
	return value, nil
}

func (reader *snapshotReader) uvarint() (uint64, error) {
	value, length := binary.Uvarint(reader.buf[reader.pos:])
	if length <= 0 {
		return 0, errSnapshotInvalid
	}
	reader.pos += length
	return value, nil
}

func (reader *snapshotReader) zigzag() (int64, error) {
	value, err := reader.uvarint()
	if err != nil {
		return 0, err
	}
	return zigzagDecode(value), nil
}

func (reader *snapshotReader) u32() (uint32, error) {
	if reader.remaining() < 4 {
		return 0, errSnapshotInvalid
	}
	value := binary.BigEndian.Uint32(reader.buf[reader.pos:])
	reader.pos += 4
	return value, nil
}

func (reader *snapshotReader) u64() (uint64, error) {
	if reader.remaining() < 8 {
		return 0, errSnapshotInvalid
	}
	value := binary.BigEndian.Uint64(reader.buf[reader.pos:])
	reader.pos += 8
	return value, nil
}

func (reader *snapshotReader) float64() (float64, error) {
	bits, err := reader.u64()
	if err != nil {
		return 0, err
	}
	return math.Float64frombits(bits), nil
}

// bytes borrows a length-prefixed slice. The payload is copied out by callers
// only where a Go string value is needed, keeping the buffer free of aliases.
func (reader *snapshotReader) bytes() ([]byte, error) {
	length, err := reader.uvarint()
	if err != nil {
		return nil, err
	}
	if length > uint64(reader.remaining()) {
		return nil, errSnapshotInvalid
	}
	value := reader.buf[reader.pos : reader.pos+int(length)]
	reader.pos += int(length)
	return value, nil
}

// u32String reads a u32 length-prefixed string, the header's convention.
func (reader *snapshotReader) u32String() (string, error) {
	length, err := reader.u32()
	if err != nil {
		return "", err
	}
	if uint64(length) > uint64(reader.remaining()) {
		return "", errSnapshotInvalid
	}
	value := string(reader.buf[reader.pos : reader.pos+int(length)])
	reader.pos += int(length)
	return value, nil
}

func (reader *snapshotReader) str() (string, error) {
	value, err := reader.bytes()
	if err != nil {
		return "", err
	}
	return string(value), nil
}

// IsCanonicalSnapshot reports whether the buffer starts with the snapshot MAGIC.
// This is the fallback discriminator: anything else is treated as a stream.
func IsCanonicalSnapshot(data []byte) bool {
	return len(data) >= snapshotMagicLength && string(data[:snapshotMagicLength]) == snapshotMagic0
}

// DecodeCanonicalSnapshot parses and verifies a snapshot produced by
// EncodeCanonicalSnapshot. The returned model is byte-equivalent to what
// ReadLocalCanonicalStream yields for the same source.
func DecodeCanonicalSnapshot(data []byte) (*snapshotData, error) {
	if !IsCanonicalSnapshot(data) {
		return nil, errSnapshotInvalid
	}
	if len(data) > snapshotStreamLimit {
		return nil, errSnapshotInvalid
	}
	reader := &snapshotReader{buf: data, pos: snapshotMagicLength}

	format, err := reader.u16()
	if err != nil {
		return nil, err
	}
	if format != snapshotFormat {
		// A newer or older format is well-formed but unreadable here.
		return nil, errSnapshotUnsupported
	}
	flags, err := reader.u16()
	if err != nil {
		return nil, err
	}
	if flags != snapshotFlagNone {
		return nil, errSnapshotUnsupported
	}
	headerLength, err := reader.u32()
	if err != nil {
		return nil, err
	}
	if uint64(headerLength) > uint64(reader.remaining()) {
		return nil, errSnapshotInvalid
	}
	headerEnd := reader.pos + int(headerLength)
	headerReader := &snapshotReader{buf: data[:headerEnd], pos: reader.pos}
	reader.pos = headerEnd

	result := &snapshotData{}
	// The source version is a fixed 32-byte digest, written without a length
	// prefix; every other string in the header is length-prefixed.
	if headerReader.remaining() < 32 {
		return nil, errSnapshotInvalid
	}
	copy(result.sourceVersion[:], headerReader.buf[headerReader.pos:headerReader.pos+32])
	headerReader.pos += 32
	if result.sourceBytes, err = headerReader.u64(); err != nil {
		return nil, err
	}
	entryCount, err := headerReader.u32()
	if err != nil {
		return nil, err
	}
	stringCount, err := headerReader.u32()
	if err != nil {
		return nil, err
	}
	if uint64(entryCount) > snapshotEntryLimit || uint64(stringCount) > snapshotStringLimit {
		return nil, errSnapshotInvalid
	}
	// Header strings carry a u32 length prefix; section strings use varint.
	if result.exporterID, err = headerReader.u32String(); err != nil {
		return nil, err
	}
	if result.appRuntimeFP, err = headerReader.u32String(); err != nil {
		return nil, err
	}
	if result.createdAt, err = headerReader.u64(); err != nil {
		return nil, err
	}
	if headerReader.remaining() != 0 {
		return nil, errSnapshotInvalid
	}

	sectionCount, err := reader.u16()
	if err != nil {
		return nil, err
	}
	if sectionCount == 0 || uint64(sectionCount) > uint64(reader.remaining())/snapshotSectionSize {
		return nil, errSnapshotInvalid
	}
	seen := make(map[uint16]snapshotSection, sectionCount)
	for i := 0; i < int(sectionCount); i++ {
		kind, err := reader.u16()
		if err != nil {
			return nil, err
		}
		offset, err := reader.u32()
		if err != nil {
			return nil, err
		}
		length, err := reader.u32()
		if err != nil {
			return nil, err
		}
		if _, duplicate := seen[kind]; duplicate {
			return nil, errSnapshotInvalid
		}
		if uint64(offset)+uint64(length) > uint64(len(data)) || offset < uint32(reader.pos) {
			return nil, errSnapshotInvalid
		}
		seen[kind] = snapshotSection{kind: kind, offset: offset, length: length}
	}

	// The trailer must be the last thing in the file, and its digest covers
	// everything before it.
	trailerStart := len(data) - 4 - snapshotDigestLength
	if trailerStart < reader.pos {
		return nil, errSnapshotInvalid
	}
	trailer := &snapshotReader{buf: data, pos: trailerStart}
	trailerCount, err := trailer.u32()
	if err != nil {
		return nil, err
	}
	if trailerCount != entryCount || trailer.remaining() != snapshotDigestLength {
		return nil, errSnapshotInvalid
	}
	wantDigest := sha256.Sum256(data[:trailerStart])
	if !bytes.Equal(wantDigest[:], data[trailerStart+4:]) {
		return nil, errSnapshotInvalid
	}
	// Sections must live strictly inside the payload area, before the trailer.
	for _, section := range seen {
		if uint64(section.offset)+uint64(section.length) > uint64(trailerStart) {
			return nil, errSnapshotInvalid
		}
	}

	strings, err := decodeSnapshotStrings(data, seen[snapshotSectionStringTable], stringCount)
	if err != nil {
		return nil, fmt.Errorf("strings section: %w", err)
	}
	options, err := decodeSnapshotOptions(data, seen[snapshotSectionOptions], strings)
	if err != nil {
		return nil, fmt.Errorf("options section: %w", err)
	}
	commodities, err := decodeSnapshotCommodities(data, seen[snapshotSectionCommodities], strings)
	if err != nil {
		return nil, fmt.Errorf("commodities section: %w", err)
	}
	entries, err := decodeSnapshotEntries(data, seen[snapshotSectionEntries], strings, entryCount)
	if err != nil {
		return nil, fmt.Errorf("entries section: %w", err)
	}

	result.model = &LocalCanonicalModel{Version: 1, Options: options, Commodities: commodities, Entries: entries}
	return result, nil
}

func (reader *snapshotReader) u16() (uint16, error) {
	if reader.remaining() < 2 {
		return 0, errSnapshotInvalid
	}
	value := binary.BigEndian.Uint16(reader.buf[reader.pos:])
	reader.pos += 2
	return value, nil
}

func snapshotSectionReader(data []byte, section snapshotSection, required bool) (*snapshotReader, error) {
	if section.length == 0 && section.offset == 0 && section.kind == 0 {
		if required {
			return nil, errSnapshotInvalid
		}
		return nil, errSnapshotInvalid
	}
	end := uint64(section.offset) + uint64(section.length)
	if end > uint64(len(data)) {
		return nil, errSnapshotInvalid
	}
	return &snapshotReader{buf: data[:end], pos: int(section.offset)}, nil
}

// decodeSnapshotStrings materializes each distinct string once. Every reference
// shares these values, so a 100k ledger keeps one header per account name.
func decodeSnapshotStrings(data []byte, section snapshotSection, declared uint32) ([]string, error) {
	reader, err := snapshotSectionReader(data, section, true)
	if err != nil {
		return nil, err
	}
	count, err := reader.uvarint()
	if err != nil {
		return nil, err
	}
	if count != uint64(declared) {
		return nil, errSnapshotInvalid
	}
	// Each entry costs at least one length byte, so the count cannot exceed the
	// remaining bytes; this bounds the allocation before it happens.
	if count > uint64(reader.remaining()) {
		return nil, errSnapshotInvalid
	}
	table := make([]string, 0, count)
	for i := uint64(0); i < count; i++ {
		value, err := reader.str()
		if err != nil {
			return nil, err
		}
		table = append(table, value)
	}
	if reader.remaining() != 0 {
		return nil, errSnapshotInvalid
	}
	return table, nil
}

func decodeSnapshotOptions(data []byte, section snapshotSection, strings []string) (map[string]string, error) {
	reader, err := snapshotSectionReader(data, section, true)
	if err != nil {
		return nil, err
	}
	count, err := reader.uvarint()
	if err != nil {
		return nil, err
	}
	// Two ids per option, each at least one byte.
	if count > uint64(reader.remaining())/2 {
		return nil, errSnapshotInvalid
	}
	options := make(map[string]string, count)
	for i := uint64(0); i < count; i++ {
		keyID, err := reader.uvarint()
		if err != nil {
			return nil, err
		}
		valueID, err := reader.uvarint()
		if err != nil {
			return nil, err
		}
		key, ok := snapshotString(strings, keyID)
		if !ok {
			return nil, errSnapshotInvalid
		}
		if key == "" {
			return nil, errSnapshotInvalid
		}
		if _, duplicate := options[key]; duplicate {
			return nil, errSnapshotInvalid
		}
		value, ok := snapshotString(strings, valueID)
		if !ok {
			return nil, errSnapshotInvalid
		}
		options[key] = value
	}
	if reader.remaining() != 0 {
		return nil, errSnapshotInvalid
	}
	return options, nil
}

func decodeSnapshotCommodities(data []byte, section snapshotSection, strings []string) ([]string, error) {
	reader, err := snapshotSectionReader(data, section, true)
	if err != nil {
		return nil, err
	}
	count, err := reader.uvarint()
	if err != nil {
		return nil, err
	}
	if count > uint64(reader.remaining()) {
		return nil, errSnapshotInvalid
	}
	commodities := make([]string, 0, count)
	for i := uint64(0); i < count; i++ {
		id, err := reader.uvarint()
		if err != nil {
			return nil, err
		}
		value, ok := snapshotString(strings, id)
		if !ok || value == "" {
			return nil, errSnapshotInvalid
		}
		commodities = append(commodities, value)
	}
	if reader.remaining() != 0 {
		return nil, errSnapshotInvalid
	}
	return commodities, nil
}

func snapshotString(table []string, id uint64) (string, bool) {
	if id >= uint64(len(table)) {
		return "", false
	}
	return table[id], true
}

func decodeSnapshotEntries(data []byte, section snapshotSection, strings []string, declared uint32) ([]BeanEntry, error) {
	reader, err := snapshotSectionReader(data, section, true)
	if err != nil {
		return nil, err
	}
	entries := make([]BeanEntry, 0, declared)
	decode := &snapshotEntryDecoder{strings: strings}
	for i := uint32(0); i < declared; i++ {
		length, err := reader.uvarint()
		if err != nil {
			return nil, err
		}
		if length < snapshotEntryMinimalBytes || length > uint64(reader.remaining()) {
			return nil, errSnapshotInvalid
		}
		recordStart := reader.pos
		entry, err := decode.entry(reader)
		if err != nil {
			return nil, err
		}
		if reader.pos-recordStart != int(length) {
			return nil, errSnapshotInvalid
		}
		entries = append(entries, entry)
	}
	if reader.remaining() != 0 {
		return nil, errSnapshotInvalid
	}
	return entries, nil
}

type snapshotEntryDecoder struct {
	strings []string
	prevDay int64
	haveDay bool
}

func (decoder *snapshotEntryDecoder) entry(reader *snapshotReader) (BeanEntry, error) {
	var entry BeanEntry
	kindID, err := reader.uvarint()
	if err != nil {
		return entry, err
	}
	kind, ok := snapshotString(decoder.strings, kindID)
	if !ok || kind == "" {
		return entry, errSnapshotInvalid
	}
	entry.Kind = kind
	flags, err := reader.uvarint()
	if err != nil {
		return entry, err
	}
	line, err := reader.uvarint()
	if err != nil {
		return entry, err
	}
	entry.Line = int(line)

	if flags&entryFlagDate != 0 {
		mode, err := reader.u8()
		if err != nil {
			return entry, err
		}
		var day int64
		switch mode {
		case snapshotModeAbsolute:
			raw, err := reader.u32()
			if err != nil {
				return entry, err
			}
			day = int64(raw)
		case snapshotModeDelta:
			if !decoder.haveDay {
				return entry, errSnapshotInvalid
			}
			delta, err := reader.zigzag()
			if err != nil {
				return entry, err
			}
			day = decoder.prevDay + delta
		default:
			return entry, errSnapshotInvalid
		}
		text, err := dayToDate(day)
		if err != nil {
			return entry, err
		}
		entry.Date = text
		decoder.prevDay = day
		decoder.haveDay = true
	}

	fileID, err := reader.uvarint()
	if err != nil {
		return entry, err
	}
	if entry.File, ok = snapshotString(decoder.strings, fileID); !ok {
		return entry, errSnapshotInvalid
	}

	if flags&entryFlagFlagChar != 0 {
		code, err := reader.u8()
		if err != nil {
			return entry, err
		}
		switch code {
		case 0:
			entry.Flag = ""
		case 1:
			entry.Flag = "*"
		case 2:
			entry.Flag = "!"
		default:
			return entry, errSnapshotInvalid
		}
	}
	for _, field := range []struct {
		flag  uint64
		target *string
	}{
		{entryFlagPayee, &entry.Payee},
		{entryFlagNarration, &entry.Narration},
		{entryFlagName, &entry.Name},
		{entryFlagValue, &entry.Value},
		{entryFlagFilename, &entry.Filename},
		{entryFlagCustomType, &entry.CustomType},
	} {
		if flags&field.flag == 0 {
			continue
		}
		value, err := reader.str()
		if err != nil {
			return entry, err
		}
		*field.target = value
	}
	for _, field := range []struct {
		flag   uint64
		target *string
	}{
		{entryFlagAccount, &entry.Account},
		{entryFlagAccount2, &entry.Account2},
		{entryFlagCurrency, &entry.Currency},
		{entryFlagQuoteCurrency, &entry.QuoteCurrency},
	} {
		if flags&field.flag == 0 {
			continue
		}
		id, err := reader.uvarint()
		if err != nil {
			return entry, err
		}
		value, ok := snapshotString(decoder.strings, id)
		if !ok {
			return entry, errSnapshotInvalid
		}
		*field.target = value
	}
	if flags&entryFlagTolerance != 0 {
		if entry.Tolerance, err = reader.str(); err != nil {
			return entry, err
		}
	}
	for _, list := range []struct {
		flag   uint64
		target *[]string
	}{
		{entryFlagCurrencies, &entry.Currencies},
		{entryFlagTags, &entry.Tags},
		{entryFlagLinks, &entry.Links},
	} {
		if flags&list.flag == 0 {
			continue
		}
		count, err := reader.uvarint()
		if err != nil {
			return entry, err
		}
		if count > uint64(reader.remaining()) {
			return entry, errSnapshotInvalid
		}
		values := make([]string, 0, count)
		for i := uint64(0); i < count; i++ {
			id, err := reader.uvarint()
			if err != nil {
				return entry, err
			}
			value, ok := snapshotString(decoder.strings, id)
			if !ok {
				return entry, errSnapshotInvalid
			}
			values = append(values, value)
		}
		*list.target = values
	}
	if flags&entryFlagAmountValue != 0 {
		if entry.AmountValue, err = decoder.amount(reader); err != nil {
			return entry, err
		}
	}
	if flags&entryFlagMetadata != 0 {
		count, err := reader.uvarint()
		if err != nil {
			return entry, err
		}
		if count > uint64(reader.remaining())/2 {
			return entry, errSnapshotInvalid
		}
		metadata := make(map[string]MetadataValue, count)
		for i := uint64(0); i < count; i++ {
			keyID, err := reader.uvarint()
			if err != nil {
				return entry, err
			}
			key, ok := snapshotString(decoder.strings, keyID)
			if !ok {
				return entry, errSnapshotInvalid
			}
			value, err := decoder.metadata(reader, 0)
			if err != nil {
				return entry, err
			}
			metadata[key] = value
		}
		entry.Metadata = metadata
	}
	if flags&entryFlagCustomValues != 0 {
		count, err := reader.uvarint()
		if err != nil {
			return entry, err
		}
		if count > uint64(reader.remaining()) {
			return entry, errSnapshotInvalid
		}
		values := make([]MetadataValue, 0, count)
		for i := uint64(0); i < count; i++ {
			value, err := decoder.metadata(reader, 0)
			if err != nil {
				return entry, err
			}
			values = append(values, value)
		}
		entry.CustomValues = values
	}
	if flags&entryFlagPostings != 0 {
		count, err := reader.uvarint()
		if err != nil {
			return entry, err
		}
		if count > uint64(reader.remaining()) {
			return entry, errSnapshotInvalid
		}
		postings := make([]parsedPosting, 0, count)
		for i := uint64(0); i < count; i++ {
			posting, err := decoder.posting(reader)
			if err != nil {
				return entry, err
			}
			postings = append(postings, posting)
		}
		entry.Postings = postings
	} else if entry.Kind == "transaction" {
		// The stream normalizes a transaction without postings to an empty slice.
		entry.Postings = []parsedPosting{}
	}
	return entry, nil
}

func (decoder *snapshotEntryDecoder) amount(reader *snapshotReader) (BeanAmount, error) {
	number, err := decoder.amountNumber(reader)
	if err != nil {
		return BeanAmount{}, err
	}
	currencyID, err := reader.uvarint()
	if err != nil {
		return BeanAmount{}, err
	}
	currency, ok := snapshotString(decoder.strings, currencyID)
	if !ok {
		return BeanAmount{}, errSnapshotInvalid
	}
	return BeanAmount{Number: number, Currency: currency}, nil
}

// amountNumber reads just the numeric part. Postings store the currency in a
// separate field, so their quantity keeps it empty here.
func (decoder *snapshotEntryDecoder) amountNumber(reader *snapshotReader) (string, error) {
	mode, err := reader.u8()
	if err != nil {
		return "", err
	}
	if mode == 0 {
		return reader.str()
	}
	header, err := reader.u8()
	if err != nil {
		return "", err
	}
	negative := header&1 == 1
	scale := int(header >> 1)
	digits, err := reader.uvarint()
	if err != nil {
		return "", err
	}
	return formatFixedPoint(digits, scale, negative), nil
}

// formatFixedPoint renders sign+scale+digits back to the decimal text the
// exporter wrote, so BeanAmount.Number round-trips byte for byte.
func formatFixedPoint(digits uint64, scale int, negative bool) string {
	text := strconv.FormatUint(digits, 10)
	if scale > 0 {
		for len(text) <= scale {
			text = "0" + text
		}
		text = text[:len(text)-scale] + "." + text[len(text)-scale:]
	}
	if negative && digits != 0 {
		text = "-" + text
	}
	return text
}

func (decoder *snapshotEntryDecoder) metadata(reader *snapshotReader, depth int) (MetadataValue, error) {
	if depth > snapshotMetadataDepthLimit {
		return nil, errSnapshotInvalid
	}
	tag, err := reader.u8()
	if err != nil {
		return nil, err
	}
	switch tag {
	case metadataTagNull:
		return nil, nil
	case metadataTagBoolTrue:
		return true, nil
	case metadataTagBoolFalse:
		return false, nil
	case metadataTagInt:
		value, err := reader.zigzag()
		if err != nil {
			return nil, err
		}
		return value, nil
	case metadataTagFloat:
		return reader.float64()
	case metadataTagString:
		return reader.str()
	case metadataTagList:
		count, err := reader.uvarint()
		if err != nil {
			return nil, err
		}
		if count > snapshotMetadataLengthLimit || count > uint64(reader.remaining()) {
			return nil, errSnapshotInvalid
		}
		// The stream path decodes a JSON array into []any, so the snapshot must
		// produce the same dynamic type: read paths assert on it, and a
		// []MetadataValue here would silently change behavior.
		list := make([]any, 0, count)
		for i := uint64(0); i < count; i++ {
			item, err := decoder.metadata(reader, depth+1)
			if err != nil {
				return nil, err
			}
			list = append(list, item)
		}
		return list, nil
	}
	return nil, errSnapshotInvalid
}

func (decoder *snapshotEntryDecoder) posting(reader *snapshotReader) (parsedPosting, error) {
	var posting parsedPosting
	flags, err := reader.uvarint()
	if err != nil {
		return posting, err
	}
	if flags&postingFlagAccount != 0 {
		id, err := reader.uvarint()
		if err != nil {
			return posting, err
		}
		value, ok := snapshotString(decoder.strings, id)
		if !ok {
			return posting, errSnapshotInvalid
		}
		posting.Account = value
	}
	if flags&postingFlagFlagChar != 0 {
		code, err := reader.u8()
		if err != nil {
			return posting, err
		}
		switch code {
		case 0:
			posting.Flag = ""
		case 1:
			posting.Flag = "*"
		case 2:
			posting.Flag = "!"
		default:
			return posting, errSnapshotInvalid
		}
	}
	if flags&postingFlagQuantity != 0 {
		if posting.Quantity, err = decoder.amount(reader); err != nil {
			return posting, err
		}
	}
	if flags&postingFlagCurrency != 0 {
		id, err := reader.uvarint()
		if err != nil {
			return posting, err
		}
		value, ok := snapshotString(decoder.strings, id)
		if !ok {
			return posting, errSnapshotInvalid
		}
		posting.Quantity.Currency = value
	}
	if flags&postingFlagCost != 0 {
		if posting.Cost, err = decoder.amount(reader); err != nil {
			return posting, err
		}
	}
	if flags&postingFlagCostCurrency != 0 {
		id, err := reader.uvarint()
		if err != nil {
			return posting, err
		}
		value, ok := snapshotString(decoder.strings, id)
		if !ok {
			return posting, errSnapshotInvalid
		}
		posting.CostCurrency = value
	}
	if flags&postingFlagCostAmount != 0 {
		value, err := reader.zigzag()
		if err != nil {
			return posting, err
		}
		posting.CostAmount = int(value)
	}
	if flags&postingFlagPrice != 0 {
		if posting.Price, err = decoder.amount(reader); err != nil {
			return posting, err
		}
	}
	if flags&postingFlagPriceCurrency != 0 {
		id, err := reader.uvarint()
		if err != nil {
			return posting, err
		}
		value, ok := snapshotString(decoder.strings, id)
		if !ok {
			return posting, errSnapshotInvalid
		}
		posting.PriceCurrency = value
	}
	if flags&postingFlagPriceAmount != 0 {
		value, err := reader.zigzag()
		if err != nil {
			return posting, err
		}
		posting.PriceAmount = int(value)
	}
	if flags&postingFlagCostDate != 0 {
		raw, err := reader.u32()
		if err != nil {
			return posting, err
		}
		text, err := dayToDate(int64(raw))
		if err != nil {
			return posting, err
		}
		posting.CostDate = text
	}
	if flags&postingFlagCostLabel != 0 {
		if posting.CostLabel, err = reader.str(); err != nil {
			return posting, err
		}
	}
	return posting, nil
}
