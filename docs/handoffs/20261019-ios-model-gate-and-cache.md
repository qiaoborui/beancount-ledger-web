# 20261019-ios-model-gate-and-cache

- Status: active (PR opening; branch `codex/ios-model-gate-rw`)
- Last updated: 2026-10-19 00:55 +0800
- Base: `main` @ `4040c74`

## Goal

Two architectural changes to the iOS ledger read path: let independent reads
run concurrently (P0), and stop re-running the Python loader for ledger content
that was already parsed (P1).

## Measured baseline (before any change)

20,000 transactions across 24 included files, iPhone 17 Pro / iOS 27 simulator,
via a temporary phase probe:

| Phase | Cost |
| --- | --- |
| parse | 134 ms |
| **booking** | **321 ms** |
| run_transformations | 37 ms |
| validate | 129 ms |
| **total** | **770 ms** |

2,000 transactions / 12 files: 421-508 ms.

## P0: reader/writer gate (done)

`LocalModelRequestGate` was a plain FIFO mutex. Every page fetch, bootstrap and
analysis read queued behind whichever request held it, including a multi-second
Python export.

It is now a reader/writer gate, extracted to
`Sources/LocalModelRequestGate.swift`:

- **Reads** (`acquireRead`) only read an immutable registered snapshot, so they
  run together. The Go side already guards its own caches.
- **Writes** (`acquireWrite`) cover registration, canonical export and release,
  which mutate the handle table and the exporter scratch directory.
- Writers are preferred, so a scroll burst cannot starve a mutation.

`EmbeddedLocalLedgerEngine.response` takes the read path first and serves the
request from the live committed handle when one matches; only registration,
export, or a missing/stale handle falls through to the exclusive path. There is
no suspension point between the handle check and the native call, so the handle
cannot be released underneath a reader.

Tests: `LocalModelRequestGateTests` (4) cover concurrent reads, write exclusion,
write exclusivity, and writer preference over queued readers.

## P1: re-parse avoidance (partial, honestly)

**The original plan does not work and was abandoned after measurement.**

Splitting canonical export per included file cannot work: Beancount's booking
(`booking_full._book`, 321 ms of the 770 ms) is a **global, sequential** pass
over the sorted entry list because it carries inventory balances forward.
Parse is per file (134 ms total), but `loader._parse_recursive` does not expose
a cache seam, so reuse would mean forking Beancount internals. That was judged
too risky for 134/770 ms.

What was actually delivered, plus one real bug found:

1. **`LocalCanonicalStreamCache.capacity` 2 -> 4.** With two entries, the stage
   export and the generation export of a single write evicted the committed
   stream, so the next read re-ran the full loader. This is the concrete
   repeat-parse path in normal use.
2. `testKeepsOnlyTheMostRecentEntries` now derives its version count from
   `LocalCanonicalStreamCache.capacity` instead of hard-coding three, while
   still asserting the eviction contract.

The cache directory was verified to be ledger-level
(`workspace.rootDirectory/runtime/canonical-cache`), not per generation, so a
stage and its published generation do share entries. A speculative
`ledgerCacheRoot` helper was written and then removed once this was confirmed.

## Validation

- 733 unit tests pass (`xcodebuild test -only-testing:LedgerMobileTests`).
- Phase timings were measured with a throwaway probe and a temporary
  `LEDGER_VALIDATOR_TIMINGS` hook; **both were removed before commit**. Do not
  look for them in the tree.

## Next candidates, with the numbers in hand

- Booking (321 ms) is the dominant cost. Real options: keep a persisted booked
  model between launches (biggest win, largest change), or reduce entry count
  per load.
- `LocalModelRequestGate` is now the throughput limiter only for writes; if
  writes feel slow, the staging double-validation (stage, then generation) is
  the next thing to measure.

## Machine notes

- `xcode-select` points at CommandLineTools; every xcodebuild call needs
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- New source/test files need `xcodegen generate` before they compile.
- xcodebuild drops `print` from unit tests; assert or `XCTFail` the values.
