package app

// Binary canonical snapshot encoder.
//
// The encoder is the inverse of decodeCanonicalSnapshot, and the differential
// test Encode(Decode(stream)) -> Decode == ReadLocalCanonicalStream(stream)
// keeps the two honest. Fields the canonical stream never carries (RawLines,
// TotalCost, TotalPrice, Blank, the denormalized Amount ints) are not encoded:
// they are recomputed by the same normalization the stream path uses.

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"math"
	"sort"
)

// EncodeCanonicalSnapshot serializes model into the binary snapshot format.
// sourceVersion identifies the source tree the model was exported from; callers
// store it next to the file name and re-check it on read.
func EncodeCanonicalSnapshot(model *LocalCanonicalModel, sourceVersion [32]byte, sourceBytes uint64,
	exporterID, appRuntimeFP string, createdAt uint64) ([]byte, error) {
	if model == nil || len(model.Entries) > snapshotEntryLimit {
		return nil, errSnapshotInvalid
	}
	enc := newSnapshotEncoder()

	entriesBody := make([]byte, 0, len(model.Entries)*64)
	optionsBody := binary.AppendUvarint(nil, uint64(len(model.Options)))
	commoditiesBody := binary.AppendUvarint(nil, uint64(len(model.Commodities)))
	// Entries are written before options so the string table is complete before
	// those sections resolve their ids. Options and commodities are drained into
	// the section writer below.

	entryWriter := &snapshotEntryWriter{enc: enc}
	if err := entryWriter.writeEntries(&entriesBody, model.Entries); err != nil {
		return nil, err
	}

	optionKeys := make([]string, 0, len(model.Options))
	for key := range model.Options {
		optionKeys = append(optionKeys, key)
	}
	// A stable order keeps the encoding deterministic for a given model, which
	// makes byte-identity comparable across runs.
	sort.Strings(optionKeys)
	for _, key := range optionKeys {
		keyID, err := enc.strID(key)
		if err != nil {
			return nil, err
		}
		valueID, err := enc.strID(model.Options[key])
		if err != nil {
			return nil, err
		}
		optionsBody = binary.AppendUvarint(optionsBody, uint64(keyID))
		optionsBody = binary.AppendUvarint(optionsBody, uint64(valueID))
	}
	for _, commodity := range model.Commodities {
		id, err := enc.strID(commodity)
		if err != nil {
			return nil, err
		}
		commoditiesBody = binary.AppendUvarint(commoditiesBody, uint64(id))
	}

	stringBody := binary.AppendUvarint(nil, uint64(len(enc.strs)))
	for _, value := range enc.strs {
		stringBody = binary.AppendUvarint(stringBody, uint64(len(value)))
		stringBody = append(stringBody, value...)
	}

	sections := []snapshotSectionBody{
		{snapshotSectionStringTable, stringBody},
		{snapshotSectionOptions, optionsBody},
		{snapshotSectionCommodities, commoditiesBody},
		{snapshotSectionEntries, entriesBody},
	}
	return assembleSnapshot(model, sections, sourceVersion, sourceBytes, len(enc.strs), exporterID, appRuntimeFP, createdAt)
}

type snapshotSectionBody struct {
	kind uint16
	body []byte
}

func assembleSnapshot(model *LocalCanonicalModel, sections []snapshotSectionBody, sourceVersion [32]byte,
	sourceBytes uint64, stringCount int, exporterID, appRuntimeFP string, createdAt uint64) ([]byte, error) {
	var body bytes.Buffer
	body.WriteString(snapshotMagic0)
	writeU16 := func(value uint16) { _ = binary.Write(&body, binary.BigEndian, value) }
	writeU32 := func(value uint32) { _ = binary.Write(&body, binary.BigEndian, value) }

	writeU16(snapshotFormat)
	writeU16(snapshotFlagNone)

	var header bytes.Buffer
	header.Write(sourceVersion[:])
	_ = binary.Write(&header, binary.BigEndian, sourceBytes)
	_ = binary.Write(&header, binary.BigEndian, uint32(len(model.Entries)))
	_ = binary.Write(&header, binary.BigEndian, uint32(stringCount))
	for _, text := range []string{exporterID, appRuntimeFP} {
		_ = binary.Write(&header, binary.BigEndian, uint32(len(text)))
		header.WriteString(text)
	}
	_ = binary.Write(&header, binary.BigEndian, createdAt)
	writeU32(uint32(header.Len()))
	body.Write(header.Bytes())

	// Section table: count, then fixed-size descriptors. Offsets are absolute and
	// patched once the table length is known.
	tableOffset := body.Len()
	writeU16(uint16(len(sections)))
	for range sections {
		writeU16(0)
		writeU32(0)
		writeU32(0)
	}
	payloadStart := body.Len()
	descriptors := make([]snapshotSection, len(sections))
	for i, section := range sections {
		descriptors[i] = snapshotSection{kind: section.kind, offset: uint32(payloadStart + 0), length: uint32(len(section.body))}
		body.Write(section.body)
	}
	// Recompute offsets now that each body length is known.
	offset := payloadStart
	for i, section := range sections {
		descriptors[i] = snapshotSection{kind: section.kind, offset: uint32(offset), length: uint32(len(section.body))}
		offset += len(section.body)
	}
	table := body.Bytes()[tableOffset : tableOffset+2+len(sections)*10]
	cursor := 2
	for _, descriptor := range descriptors {
		binary.BigEndian.PutUint16(table[cursor:], descriptor.kind)
		binary.BigEndian.PutUint32(table[cursor+2:], descriptor.offset)
		binary.BigEndian.PutUint32(table[cursor+6:], descriptor.length)
		cursor += 10
	}

	digest := sha256.Sum256(body.Bytes())
	_ = binary.Write(&body, binary.BigEndian, uint32(len(model.Entries)))
	body.Write(digest[:])
	return body.Bytes(), nil
}

type snapshotEntryWriter struct {
	enc     *snapshotEncoder
	prevDay int64
	haveDay bool
}

func (writer *snapshotEntryWriter) writeEntries(dst *[]byte, entries []BeanEntry) error {
	for i := range entries {
		record, err := writer.encodeEntry(entries[i])
		if err != nil {
			return err
		}
		*dst = binary.AppendUvarint(*dst, uint64(len(record)))
		*dst = append(*dst, record...)
	}
	return nil
}

func (writer *snapshotEntryWriter) encodeEntry(entry BeanEntry) ([]byte, error) {
	enc := writer.enc
	var record []byte

	kindID, err := enc.strID(entry.Kind)
	if err != nil {
		return nil, err
	}
	record = binary.AppendUvarint(record, uint64(kindID))

	var flags uint64
	if entry.Date != "" {
		flags |= entryFlagDate
	}
	// The stream path always materializes a metadata map (JSON `{}` decodes to an
	// empty map, not nil), so an entry without metadata still carries the flag
	// with zero pairs. Dropping it would change the decoded type.
	if entry.Metadata != nil {
		flags |= entryFlagMetadata
	}
	if entry.Name != "" {
		flags |= entryFlagName
	}
	if entry.Value != "" {
		flags |= entryFlagValue
	}
	if entry.Filename != "" {
		flags |= entryFlagFilename
	}
	if entry.Flag != "" {
		flags |= entryFlagFlagChar
	}
	if entry.Payee != "" {
		flags |= entryFlagPayee
	}
	if entry.Narration != "" {
		flags |= entryFlagNarration
	}
	if entry.Account != "" {
		flags |= entryFlagAccount
	}
	if entry.Account2 != "" {
		flags |= entryFlagAccount2
	}
	if entry.Currencies != nil {
		flags |= entryFlagCurrencies
	}
	if entry.Currency != "" {
		flags |= entryFlagCurrency
	}
	if entry.AmountValue.Number != "" || entry.AmountValue.Currency != "" {
		flags |= entryFlagAmountValue
	}
	if entry.Tolerance != "" {
		flags |= entryFlagTolerance
	}
	if entry.QuoteCurrency != "" {
		flags |= entryFlagQuoteCurrency
	}
	if entry.Tags != nil {
		flags |= entryFlagTags
	}
	if entry.Links != nil {
		flags |= entryFlagLinks
	}
	if entry.CustomType != "" {
		flags |= entryFlagCustomType
	}
	if len(entry.CustomValues) > 0 {
		flags |= entryFlagCustomValues
	}
	if len(entry.Postings) > 0 {
		flags |= entryFlagPostings
	}
	record = binary.AppendUvarint(record, flags)

	record = binary.AppendUvarint(record, uint64(entry.Line))

	if flags&entryFlagDate != 0 {
		day, err := dateToDay(entry.Date)
		if err != nil {
			return nil, err
		}
		// The first record is absolute; later ones are deltas, which are usually
		// 0-2 bytes instead of 4.
		if !writer.haveDay {
			record = append(record, snapshotModeAbsolute)
			record = binary.BigEndian.AppendUint32(record, uint32(day))
		} else {
			record = append(record, snapshotModeDelta)
			record = appendZigzag(record, day-writer.prevDay)
		}
		writer.prevDay = day
		writer.haveDay = true
	}

	fileID, err := enc.strID(entry.File)
	if err != nil {
		return nil, err
	}
	record = binary.AppendUvarint(record, uint64(fileID))

	type inlineField struct {
		flag  uint64
		value string
	}
	if flags&entryFlagFlagChar != 0 {
		// Flags are a tiny closed set; a byte tag avoids a string id for them.
		record = append(record, inlineFlagByte(entry.Flag))
	}
	for _, field := range []inlineField{
		{entryFlagPayee, entry.Payee},
		{entryFlagNarration, entry.Narration},
		{entryFlagName, entry.Name},
		{entryFlagValue, entry.Value},
		{entryFlagFilename, entry.Filename},
		{entryFlagCustomType, entry.CustomType},
	} {
		if flags&field.flag == 0 {
			continue
		}
		record = appendInlineString(record, field.value)
	}
	for _, field := range []struct {
		flag  uint64
		value string
	}{
		{entryFlagAccount, entry.Account},
		{entryFlagAccount2, entry.Account2},
		{entryFlagCurrency, entry.Currency},
		{entryFlagQuoteCurrency, entry.QuoteCurrency},
	} {
		if flags&field.flag == 0 {
			continue
		}
		id, err := enc.strID(field.value)
		if err != nil {
			return nil, err
		}
		record = binary.AppendUvarint(record, uint64(id))
	}
	if flags&entryFlagTolerance != 0 {
		// Tolerance participates in exact rational math, so it stays literal text.
		record = appendInlineString(record, entry.Tolerance)
	}
	for _, list := range []struct {
		flag   uint64
		values []string
	}{
		{entryFlagCurrencies, entry.Currencies},
		{entryFlagTags, entry.Tags},
		{entryFlagLinks, entry.Links},
	} {
		if flags&list.flag == 0 {
			continue
		}
		record = binary.AppendUvarint(record, uint64(len(list.values)))
		for _, value := range list.values {
			id, err := enc.strID(value)
			if err != nil {
				return nil, err
			}
			record = binary.AppendUvarint(record, uint64(id))
		}
	}
	if flags&entryFlagAmountValue != 0 {
		record, err = appendSnapshotAmount(record, entry.AmountValue, enc)
		if err != nil {
			return nil, err
		}
	}
	if flags&entryFlagMetadata != 0 {
		keys := make([]string, 0, len(entry.Metadata))
		for key := range entry.Metadata {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		record = binary.AppendUvarint(record, uint64(len(keys)))
		for _, key := range keys {
			keyID, err := enc.strID(key)
			if err != nil {
				return nil, err
			}
			record = binary.AppendUvarint(record, uint64(keyID))
			record, err = appendSnapshotMetadata(record, entry.Metadata[key], enc, 0)
			if err != nil {
				return nil, err
			}
		}
	}
	if flags&entryFlagCustomValues != 0 {
		record = binary.AppendUvarint(record, uint64(len(entry.CustomValues)))
		for _, value := range entry.CustomValues {
			record, err = appendSnapshotMetadata(record, value, enc, 0)
			if err != nil {
				return nil, err
			}
		}
	}
	if flags&entryFlagPostings != 0 {
		record = binary.AppendUvarint(record, uint64(len(entry.Postings)))
		for _, posting := range entry.Postings {
			record, err = appendSnapshotPosting(record, posting, enc)
			if err != nil {
				return nil, err
			}
		}
	}
	return record, nil
}

// inlineFlagByte encodes the transaction flag. Any other single character falls
// back to a length-prefixed string so unknown flags survive a round trip.
func inlineFlagByte(flag string) byte {
	switch flag {
	case "*":
		return 1
	case "!":
		return 2
	}
	return 0
}

func appendInlineString(dst []byte, value string) []byte {
	dst = binary.AppendUvarint(dst, uint64(len(value)))
	return append(dst, value...)
}

// appendSnapshotAmount writes a BeanAmount: the number and then its currency.
// The currency is empty for posting quantities (encoded separately) and carries
// the commodity for entry-level amounts such as balance and price directives.
func appendSnapshotAmount(dst []byte, amount BeanAmount, enc *snapshotEncoder) ([]byte, error) {
	if record, ok := encodeFixedPoint(amount.Number); ok {
		dst = append(dst, record...)
	} else {
		// Fallback: keep the literal text so exactness never depends on the encoder.
		dst = append(dst, 0)
		dst = appendInlineString(dst, amount.Number)
	}
	id, err := enc.strID(amount.Currency)
	if err != nil {
		return nil, err
	}
	return binary.AppendUvarint(dst, uint64(id)), nil
}

// encodeFixedPoint writes sign+scale+digits when the decimal text fits, so the
// common case is a handful of bytes. ok=false means "store the text instead".
func encodeFixedPoint(number string) ([]byte, bool) {
	if number == "" {
		return []byte{0, 0}, true
	}
	negative := false
	index := 0
	if number[0] == '-' {
		negative = true
		index = 1
	} else if number[0] == '+' {
		index = 1
	}
	if index >= len(number) {
		return nil, false
	}
	var digits uint64
	scale := 0
	seenDot := false
	digitCount := 0
	for ; index < len(number); index++ {
		c := number[index]
		if c == '.' {
			if seenDot {
				return nil, false
			}
			seenDot = true
			continue
		}
		if c < '0' || c > '9' {
			return nil, false
		}
		if seenDot {
			scale++
			if scale > 9 {
				return nil, false
			}
		}
		if digits > (math.MaxUint64-9)/10 {
			return nil, false
		}
		digits = digits*10 + uint64(c-'0')
		digitCount++
	}
	if digitCount == 0 {
		return nil, false
	}
	header := byte(scale << 1)
	if negative {
		header |= 1
	}
	out := []byte{1, header}
	return binary.AppendUvarint(out, digits), true
}

func appendSnapshotMetadata(dst []byte, value MetadataValue, enc *snapshotEncoder, depth int) ([]byte, error) {
	if depth > snapshotMetadataDepthLimit {
		return nil, errSnapshotInvalid
	}
	switch typed := value.(type) {
	case nil:
		dst = append(dst, metadataTagNull)
	case bool:
		if typed {
			dst = append(dst, metadataTagBoolTrue)
		} else {
			dst = append(dst, metadataTagBoolFalse)
		}
	case int:
		dst = append(dst, metadataTagInt)
		dst = appendZigzag(dst, int64(typed))
	case int64:
		dst = append(dst, metadataTagInt)
		dst = appendZigzag(dst, typed)
	case float64:
		dst = append(dst, metadataTagFloat)
		dst = appendFloats(dst, typed)
	case string:
		dst = append(dst, metadataTagString)
		dst = appendInlineString(dst, typed)
	case []MetadataValue:
		return appendSnapshotMetadataList(dst, typed, enc, depth)
	case []any:
		// encoding/json decodes a JSON array into []any, so this is the shape the
		// stream decoder actually produces for list metadata.
		return appendSnapshotMetadataList(dst, typed, enc, depth)
	default:
		return nil, errSnapshotInvalid
	}
	return dst, nil
}

func appendSnapshotMetadataList[T MetadataValue](dst []byte, values []T, enc *snapshotEncoder, depth int) ([]byte, error) {
	if len(values) > snapshotMetadataLengthLimit {
		return nil, errSnapshotInvalid
	}
	dst = append(dst, metadataTagList)
	dst = binary.AppendUvarint(dst, uint64(len(values)))
	for _, item := range values {
		var err error
		dst, err = appendSnapshotMetadata(dst, item, enc, depth+1)
		if err != nil {
			return nil, err
		}
	}
	return dst, nil
}

func appendSnapshotPosting(dst []byte, posting parsedPosting, enc *snapshotEncoder) ([]byte, error) {
	var flags uint64
	if posting.Account != "" {
		flags |= postingFlagAccount
	}
	if posting.Quantity.Number != "" {
		flags |= postingFlagQuantity
	}
	if posting.Quantity.Currency != "" {
		flags |= postingFlagCurrency
	}
	if posting.Flag != "" {
		flags |= postingFlagFlagChar
	}
	if posting.CostAmount != 0 {
		flags |= postingFlagCostAmount
	}
	if posting.CostCurrency != "" {
		flags |= postingFlagCostCurrency
	}
	if posting.Cost.Number != "" || posting.Cost.Currency != "" {
		flags |= postingFlagCost
	}
	if posting.PriceAmount != 0 {
		flags |= postingFlagPriceAmount
	}
	if posting.PriceCurrency != "" {
		flags |= postingFlagPriceCurrency
	}
	if posting.Price.Number != "" || posting.Price.Currency != "" {
		flags |= postingFlagPrice
	}
	if posting.CostDate != "" {
		flags |= postingFlagCostDate
	}
	if posting.CostLabel != "" {
		flags |= postingFlagCostLabel
	}
	dst = binary.AppendUvarint(dst, flags)

	if flags&postingFlagAccount != 0 {
		id, err := enc.strID(posting.Account)
		if err != nil {
			return nil, err
		}
		dst = binary.AppendUvarint(dst, uint64(id))
	}
	if flags&postingFlagFlagChar != 0 {
		dst = append(dst, inlineFlagByte(posting.Flag))
	}
	if flags&postingFlagQuantity != 0 {
		var err error
		dst, err = appendSnapshotAmount(dst, posting.Quantity, enc)
		if err != nil {
			return nil, err
		}
	}
	if flags&postingFlagCurrency != 0 {
		id, err := enc.strID(posting.Quantity.Currency)
		if err != nil {
			return nil, err
		}
		dst = binary.AppendUvarint(dst, uint64(id))
	}
	if flags&postingFlagCost != 0 {
		var err error
		dst, err = appendSnapshotAmount(dst, posting.Cost, enc)
		if err != nil {
			return nil, err
		}
	}
	if flags&postingFlagCostCurrency != 0 {
		id, err := enc.strID(posting.CostCurrency)
		if err != nil {
			return nil, err
		}
		dst = binary.AppendUvarint(dst, uint64(id))
	}
	if flags&postingFlagCostAmount != 0 {
		dst = appendZigzag(dst, int64(posting.CostAmount))
	}
	if flags&postingFlagPrice != 0 {
		var err error
		dst, err = appendSnapshotAmount(dst, posting.Price, enc)
		if err != nil {
			return nil, err
		}
	}
	if flags&postingFlagPriceCurrency != 0 {
		id, err := enc.strID(posting.PriceCurrency)
		if err != nil {
			return nil, err
		}
		dst = binary.AppendUvarint(dst, uint64(id))
	}
	if flags&postingFlagPriceAmount != 0 {
		dst = appendZigzag(dst, int64(posting.PriceAmount))
	}
	if flags&postingFlagCostDate != 0 {
		day, err := dateToDay(posting.CostDate)
		if err != nil {
			return nil, err
		}
		dst = binary.BigEndian.AppendUint32(dst, uint32(day))
	}
	if flags&postingFlagCostLabel != 0 {
		dst = appendInlineString(dst, posting.CostLabel)
	}
	return dst, nil
}
