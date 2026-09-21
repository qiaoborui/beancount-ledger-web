# Bounded canonical export (phase 1)

This standalone tool is the first delivery of the [bounded read-model plan](plans/20260921-ios-bounded-read-model.md). It does **not** change the default iOS engine, install SQLite, or make existing screens bounded. Beancount still holds its booked AST in memory.

## Run against a disposable, frozen source generation

Use Python with the embedded runtime's pinned Beancount version (currently 3.2.3). Do not point automated experiments at a private production ledger. Output must be outside the ledger in an existing, owned directory with mode `0700`; files are exclusively created with mode `0600` and never overwrite another export.

```sh
mkdir -m 700 /tmp/ledger-stream-output
PYTHONPATH=App/LedgerMobile/Runtime python - <<'PY'
from ledger_stream import export_stream
export_stream('examples/chinese-personal-ledger', '/tmp/ledger-stream-output/canonical.jsonl')
PY
(cd server && go run ./cmd/ledger-stream-check /tmp/ledger-stream-output/canonical.jsonl)
```

The CLI prints only counts, bounds and digests. Export exceptions are for the caller: canonical validation messages can include source data and must not be logged or forwarded unsanitized. POSIX permissions are not encryption or verified iOS file-protection classes.

## Contract v1

The Python module docstring is the detailed wire contract. Each UTF-8 JSONL record, including LF, is at most 1 MiB. The stream consists of a header, public string options, commodities, sequential directives with separate postings and typed metadata, then a footer authenticating **stream consistency**, not source provenance. Each owner has at most 8,192 metadata keys, checked before sorting; excessive metadata fails explicitly. Metadata is sorted by key. Decimal strings, costs, prices, booking methods and typed custom values remain exact.

There is no all-entry JSON array. The exporter incrementally encodes one record and hashes sources in 64 KiB chunks. Source discovery and canonical loading still scale with source/entry count. The Go verifier buffers one bounded record, enforces schema/order/types/paths/depth, rejects duplicate JSON keys, checks footer counts and SHA256, and rejects trailing bytes. A record bound is not a total heap or RSS guarantee.

Wire paths are workspace-relative and reject traversal, absolute paths, backslashes, colons and control characters. `.` is allowed only for a documents-directory option. Source identity hashes sorted path/size/content framing; before/after checks detect ordinary mutation, but the caller **must freeze** the source against concurrent change-and-restore races.

`boundedstream.Verify(ctx, reader, visitor)` callbacks are provisional until the entire stream and EOF pass. A future SQLite builder must rollback on failure and bound anything it retains. Cancellation is checked between reads/callbacks; callers must separately interrupt blocking I/O. The verifier does not independently validate accounting or compare the asserted source hash with external source files.

## Validation

```sh
(cd server && go build -o /tmp/ledger-stream-check ./cmd/ledger-stream-check)
LEDGER_STREAM_CHECK=/tmp/ledger-stream-check python -m unittest discover \
  -s App/LedgerMobile/Runtime -p 'test_*.py'
(cd server && LEDGER_STREAM_PYTHON=/path/to/python-with-beancount \
  go test ./internal/boundedstream ./cmd/ledger-stream-check)
```

Both integration environment variables are optional, but omitting them may skip cross-language tests. No database, hosted service or private data is needed.

Synthetic host runs with 1k/10k/100k two-posting transactions passed export and independent verification. The 100k run produced 44,820,464 stream bytes, 100,002 directives and 200,000 postings; largest record was 205 bytes. This demonstrates streaming a payload larger than the old whole-request cap—not bounded on-device reads, an index build or a measured RSS plateau. Golden tests separately cover plugins, lots/costs, multiple currencies and exact typed metadata.

## Next gates

Build the native SQLite adapter and immutable index, then integrate a coherent source/index manifest and revision-bound page/detail APIs behind explicit opt-in. Do not switch default screens until reports, BQL, imports/editor, Widgets, failure/privacy and physical-device scale gates pass. Apple packaging, Swift compilation, device data protection and memory profiling have not been validated by this host-only milestone.
