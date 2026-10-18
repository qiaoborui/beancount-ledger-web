# 20261019-ios-row-presentation-perf

- Status: active (PR opening; branch `codex/ios-perf-row-presentation`)
- Last updated: 2026-10-19 01:10 +0800
- Base: `main` @ `4040c74`

## Goal

Scrolling the transaction list re-derived every row's title, amount, icon and
category colour on each body evaluation. Measured 126.76 ms per pass over a
1,000-row window. Target: no behaviour change, big reduction.

## Result

`rows + visual per pass` 126.76 ms -> 12.94 ms (9.8x), measured with a throwaway
probe on iPhone 17 Pro / iOS 27 simulator, 1,000 rows x 240 accounts.

| Probe | Before | After |
| --- | --- | --- |
| rows + visual per pass | 126.76 ms | 12.94 ms |
| single presentation | 0.0008 ms | 0.0003 ms |
| group + day summary | 1.28 ms | 0.76 ms |
| accountLabels lookup | 0.032 ms | 0.032 ms |

## Changes

1. `TransactionVisualCategory.resolve` memoized on row identity + label map
   version (`TransactionVisualCategoryCache`, 4,096 entries, wholesale clear).
   The uncached path lowercased each posting account and allocated a `Color`.
2. `AccountLabelCache` compares a hash of `(account, label, alias)` instead of the
   whole `[LedgerAccount]` array, and seeds the label version when it builds the
   map so the per-row version lookup is a hit.
3. `TransactionPresentation` replaces two allocating `filter`s with two small
   loops.

## Trap worth remembering

The version must be a **full** hash of the label map. A truncated
(count + first pair) version is faster but a collision silently changes a row's
icon and category. Do not "optimise" it back.

`TransactionPresentation` must sum expense, act on it, and only then touch
income. A fused single pass sums the income branch too, and
`testCheckedArithmeticAllowsSafeFinalSumsAndSkipsUnreachableBranches` includes
fixtures where that branch holds `Int.max + 1`, which traps. This was caught by
the full suite, not by running that file alone (it passed in isolation because
of test ordering).

## Validation

- 729 unit tests pass (`xcodebuild test -only-testing:LedgerMobileTests`).
- Probe was temporary and is not committed; re-create it from this note if you
  need the numbers again.
- The 34 pre-existing UI failures from `20261018-ios-transactions-pager` are
  unchanged and unrelated.

## Machine notes

- `xcode-select` points at CommandLineTools; every xcodebuild call needs
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- New test files need `xcodegen generate` before `-only-testing` will find them.
- xcodebuild swallows `print` from unit tests; assert or `XCTFail` the numbers.
