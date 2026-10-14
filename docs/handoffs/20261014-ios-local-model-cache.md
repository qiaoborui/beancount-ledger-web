# 20261014-ios-local-model-cache

- Status: completed (merged with PR #507 after the user's device test)
- Last updated: 2026-10-14 16:00 +0800
- Branch: `codex/ios-local-model-cache` (from `main` @ `3911814`)
- PR: https://github.com/qiaoborui/beancount-ledger-web/pull/507

## Goal

The iOS app runs hot and feels slow with a local ledger. Measure where the
time goes and remove the repeated full-ledger work without changing which
engine is authoritative (canonical Beancount stays the read model).

## Findings (synthetic 15k-transaction ledger, iOS simulator on an M-series Mac)

- Every model registration ran the embedded Python Beancount loader over the
  whole ledger and exported a canonical stream (about 1.7 s at 15k), then Go
  ingested it (about 0.35 s). That happened on every cold launch, on the
  staged copy before a mutation, again for publication validation, and again
  after the commit published a new generation path.
- One write (add a tag) took about 4.9 s plus 2.2 s to reload.
- Python export cost was dominated by the exporter's own record encoding:
  chunked `json.JSONEncoder.iterencode` runs the pure-Python encoder.
- Every native request re-read and re-hashed every source file two or three
  times for the source version (about 12 ms each at 15k).
- Idle CPU with the preview fixture is 0%; no UI redraw loop was found.

## Changes

1. `LocalCanonicalStreamCache` (Swift): content-addressed store of exported
   streams under `runtime/canonical-cache/<build fingerprint>/`, keyed by the
   Go source version. Entries are verified by size and whole-file SHA-256
   before reuse, at most two are kept, and other build fingerprints are
   removed. `EmbeddedLocalLedgerEngine.register` restores from it before
   falling back to Python.
2. Publication validation through the catalog's default validator now calls
   `EmbeddedLocalLedgerEngine.validateCanonical`: a successful export is a
   successful validation, so the export is kept for the generation it becomes.
   Injected validators (tests) still run exactly as given.
3. Exporter (`Runtime/ledger_validator.py`): one C-accelerated `encode` per
   record after the existing worst-case size precheck; path-bearing options
   (`filename`, `include`) are exported relative to the ledger root and
   `input_hash` is dropped, so copies of the same tree export identical bytes.
4. Go: per-file memo of content hash and include directives keyed by device,
   inode, size, mtime and ctime (`local_source_memo*.go`). The line-collecting
   parse path is unchanged. `copyLocalRuntime` skips `canonical-cache`.
5. Export diagnostics now carry the same `file:line` prefix as validate-only.

## Results (same probe, 15k)

| Step | Before | After |
| --- | --- | --- |
| First model build | 2019 ms | ~410 ms (no Python) |
| One write | 4928 ms | ~2020 ms |
| Reload after write | 2172 ms | ~395 ms |
| Source version (Go) | 12.4 ms | 0.38 ms |
| Page requests (warm) | 16–41 ms | 10–30 ms |

## Validation

- Swift unit tests (`LedgerMobileTests`): pass except three keychain tests
  that fail identically on clean `main` in the simulator.
- New `LocalCanonicalStreamCacheTests` (7) pass, including an end-to-end
  import through the bundled runtimes.
- Python `unittest discover App/LedgerMobile/Runtime`: pass, plus a new
  path-independence test.
- Go `go test ./...` and `go build ./cmd/ledger-web`: pass.
- Local-ledger UI suites: six failures, all of which also fail on clean
  `main` @ `3911814`. Two were known to fail before PR #506; whether the
  other four predate #506 was not checked. They need a follow-up fix.
- The user installed the branch IPA and reported no problems on device.

## Next steps

1. Possible follow-ups: Go stream ingest speed, deferring widget refreshes,
   avoiding the extra staged Go ingest used only for the publication version
   check.
