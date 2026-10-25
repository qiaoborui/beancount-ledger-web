package app

// Binary canonical snapshot format (BLWSNAP, format 1).
//
// This is a cache representation of the canonical stream, never an authority:
// the exporter stream stays the source of truth, and a snapshot that fails any
// check below is rejected so the caller falls back to re-reading the stream.
//
// Layout (all integers big endian):
//
//	MAGIC         8 bytes  "BLWSNAP\x00"
//	FORMAT        u16      = 1
//	FLAGS         u16      optional feature bits; unknown bit => reject
//	HEADER LEN    u32      length of the header section that follows
//	HEADER        sourceVersion[32] | sourceBytes u64 | entryCount u32 |
//	              stringCount u32 | exporterID str | appRuntimeFP str |
//	              createdAt u64
//	SECTION TABLE u16 count, then count x { u16 kind, u32 offset, u32 length }
//	SECTIONS      STRING_TABLE, OPTIONS, COMMODITIES, ENTRIES (see below)
//	TRAILER       u32 entryCount, then sha256(MAGIC..end of last section)
//
// No byte may follow the trailer. Section offsets are absolute from the start of
// the file, must sit inside the payload, must not overlap the tables, and each
// required kind must appear exactly once.
//
// Costs are bounded before allocation: every count is cross-checked against the
// bytes that remain in its section, so a corrupt length cannot request a huge
// allocation.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"strconv"
)

const (
	snapshotMagic0 = "BLWSNAP\x00"
	snapshotFormat = 1

	snapshotFlagNone = 0

	snapshotSectionStringTable = 1
	snapshotSectionOptions     = 2
	snapshotSectionCommodities = 3
	snapshotSectionEntries     = 4

	// snapshotFormatTag is embedded in the cache file name so a reader can pick
	// the decoder before touching the contents. Bump it only on incompatible
	// changes; additive optional sections use a FLAGS bit instead.
	snapshotFormatTag = "snap1"

	snapshotModeAbsolute = 0
	snapshotModeDelta    = 1

	snapshotEntryMinimalBytes = 3 // mode + at least one flag byte + record length
)

var errSnapshotInvalid = errors.New("invalid or incomplete canonical snapshot")

// errSnapshotUnsupported marks a well-formed snapshot this build cannot read.
// Callers fall back to the stream instead of caching a failure.
var errSnapshotUnsupported = errors.New("unsupported canonical snapshot format")

// entry field presence bits, in the order the encoder writes fields.
const (
	entryFlagMetadata uint64 = 1 << iota
	entryFlagName
	entryFlagValue
	entryFlagFilename
	entryFlagFlagChar
	entryFlagPayee
	entryFlagNarration
	entryFlagAccount
	entryFlagAccount2
	entryFlagCurrencies
	entryFlagCurrency
	entryFlagAmountValue
	entryFlagTolerance
	entryFlagQuoteCurrency
	entryFlagTags
	entryFlagLinks
	entryFlagCustomType
	entryFlagCustomValues
	entryFlagPostings
	entryFlagDate
)

// posting field presence bits, in the order the encoder writes fields.
const (
	postingFlagAccount uint64 = 1 << iota
	postingFlagQuantity
	postingFlagCurrency
	postingFlagFlagChar
	postingFlagCostAmount
	postingFlagCostCurrency
	postingFlagCost
	postingFlagPriceAmount
	postingFlagPriceCurrency
	postingFlagPrice
	postingFlagCostDate
	postingFlagCostLabel
)

// metadata value tags. The set is closed: an unknown tag rejects the snapshot
// rather than silently dropping data.
const (
	metadataTagNull byte = iota
	metadataTagBoolTrue
	metadataTagBoolFalse
	metadataTagInt
	metadataTagFloat
	metadataTagString
	metadataTagList
)

const (
	snapshotMetadataDepthLimit  = 8
	snapshotMetadataLengthLimit = 4096
)

// snapshotLimits bounds what a single snapshot may contain. They mirror the
// stream limits so a snapshot can never represent more than the stream allows.
const (
	snapshotStreamLimit = localCanonicalStreamLimit
	snapshotEntryLimit  = 8 << 20
	snapshotStringLimit = 4 << 20
)

type snapshotSection struct {
	kind   uint16
	offset uint32
	length uint32
}

// snapshotData is the decoded payload plus the metadata a caller verifies.
type snapshotData struct {
	sourceVersion [32]byte
	sourceBytes   uint64
	exporterID    string
	appRuntimeFP  string
	createdAt     uint64
	model         *LocalCanonicalModel
}

// snapshotEncoder accumulates sections while writing.
type snapshotEncoder struct {
	buf    bytes.Buffer
	strIDs map[string]uint32
	strs   [][]byte
}

func newSnapshotEncoder() *snapshotEncoder {
	return &snapshotEncoder{strIDs: make(map[string]uint32, 1024)}
}

func (enc *snapshotEncoder) strID(value string) (uint32, error) {
	if id, ok := enc.strIDs[value]; ok {
		return id, nil
	}
	if len(enc.strs) >= snapshotStringLimit {
		return 0, errSnapshotInvalid
	}
	id := uint32(len(enc.strs))
	enc.strIDs[value] = id
	enc.strs = append(enc.strs, []byte(value))
	return id, nil
}

// dateToDay converts a canonical ISO date to a day number (days since
// 1970-01-01). The stream only ever contains dates the exporter produced with
// date.isoformat(), so anything else is treated as corruption, not coerced.
func dateToDay(value string) (int64, error) {
	if len(value) != 10 || value[4] != '-' || value[7] != '-' {
		return 0, errSnapshotInvalid
	}
	year, err := strconv.Atoi(value[0:4])
	if err != nil {
		return 0, errSnapshotInvalid
	}
	month, err := strconv.Atoi(value[5:7])
	if err != nil || month < 1 || month > 12 {
		return 0, errSnapshotInvalid
	}
	day, err := strconv.Atoi(value[8:10])
	if err != nil || day < 1 || day > 31 {
		return 0, errSnapshotInvalid
	}
	if month == 2 && day > 29 {
		return 0, errSnapshotInvalid
	}
	if day > daysInMonth(year, month) {
		return 0, errSnapshotInvalid
	}
	return civilToDays(int64(year), int64(month), int64(day)), nil
}

func daysInMonth(year, month int) int {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	}
	if year%4 == 0 && (year%100 != 0 || year%400 == 0) {
		return 29
	}
	return 28
}

// civilToDays is Howard Hinnant's days_from_civil.
func civilToDays(year, month, day int64) int64 {
	if month <= 2 {
		year--
	}
	era := year / 400
	if year < 0 && year%400 != 0 {
		era--
	}
	yoe := year - era*400
	mp := month + 9
	if month > 2 {
		mp = month - 3
	}
	doy := (153*mp+2)/5 + day - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// dayToDate is the exact inverse of civilToDays.
func dayToDate(days int64) (string, error) {
	z := days + 719468
	era := z / 146097
	if z < 0 && z%146097 != 0 {
		era--
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	year := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	day := doy - (153*mp+2)/5 + 1
	month := mp + 3
	if mp >= 10 {
		month = mp - 9
	}
	if month <= 2 {
		year++
	}
	if year < 0 || year > 9999 {
		return "", errSnapshotInvalid
	}
	return fmt.Sprintf("%04d-%02d-%02d", year, month, day), nil
}

func zigzagEncode(value int64) uint64 {
	return uint64(value<<1) ^ uint64(value>>63)
}

func zigzagDecode(value uint64) int64 {
	return int64(value>>1) ^ -int64(value&1)
}

func appendUvarint(dst []byte, value uint64) []byte {
	return binary.AppendUvarint(dst, value)
}

func appendZigzag(dst []byte, value int64) []byte {
	return binary.AppendUvarint(dst, zigzagEncode(value))
}

func appendFloats(dst []byte, value float64) []byte {
	return binary.BigEndian.AppendUint64(dst, math.Float64bits(value))
}
