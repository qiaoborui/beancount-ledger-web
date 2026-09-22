# 20260922-ios-readindex-valuation

- Status: active; updated 2026-09-22T14:01:32+08:00. Apple runtime fixes are committed and pushed; refreshed hosted checks remain pending.
- Parent: `20260921-ios-bounded-read-model`. Current goal: finish Apple verification of bounded valuation and resolve reproducible failures. Keep the default application mode unchanged; no merge, release, production mutation, or reporting/BQL expansion authorized.
- Branch: `codex/ios-readindex-valuation`; Graphite parent `codex/ios-validation-concurrency-fixture` (PR #415). Base `7629d60e6c466aef2d565bd851a0ca2ff5072747`.
- Draft PR: [#416](https://github.com/qiaoborui/beancount-ledger-web/pull/416). Remote was verified open, draft, and mergeable before this push. Code through `fde1b7a3a0910c79e7cd96ec31207d2a5e735d3d` is pushed; this note accompanies a subsequent documentation commit.

## Completed Implementation

- Shared Go scalar valuation preserves direct, inverse, then byte-lexicographic DFS and per-edge cents truncation. `legacy_cents` uses int64 with depth 64 and 100,000-operation limits; overflow, cancellation, and exhausted budgets fail explicitly.
- Schema 3 verifies normalized currency-pair keys and retains exact raw decimal quote strings. Equal-date quotes select the last source sequence; legacy unstable-sort tie parity is not claimed.
- Native `PriceLookup` / `ValueLegacyCents` and revision-bound Swift readers retain request/response caps and lifecycle guards. Schema 1/2 require explicit rebuild; failed publication preserves the previous pointer.
- `b7f302e`: Apple SQLite reports `OMIT_LOAD_EXTENSION` and rejects the extension-loading db_config operation with `SQLITE_MISUSE`. Skip that operation only with runtime proof that loading is compiled out. Other hardening and scratch-file denial remain required. Add a canonical-path native regression, portable corrupt-index rejection assertion, and macOS native-CI race gate.
- `fde1b7a`: Foundation can rewrite canonical Darwin paths back to system symlink aliases. Use POSIX `realpath` for the supplied root; native child-path checks remain intact. Add a regression that failed on the old code and update path expectations to the POSIX contract.
- Follow-up files: SQLite adapter/tests, native-checks workflow and contract tests, Swift bounded client/tests. Existing valuation scope is unchanged.

## Current Verification

Against `fde1b7a` (Go files unchanged from `b7f302e`), with synthetic fixtures only:

- macOS Go 1.27.1, cgo: `TMPDIR=<canonical-temp> go test -p 2 -timeout 180s ./...` PASS; `go build -p 2 ./cmd/ledger-web` PASS.
- `go test -race -p 2 -timeout 120s ./internal/ledger ./internal/readindex/... ./mobilereadindex` PASS. Direct security checks confirmed PRAGMA/extension-loading denial, scratch-file denial, and corrupt-index rejection.
- Both `internal/app` legacy-valuation differential tests PASS.
- Xcode 27 beta macOS Swift package: `swift test --jobs 2` PASS, 504 tests executed, 15 skipped by existing runtime conditions, zero failures. Includes all nine valuation tests and the complete publication suite.
- `python3 scripts/test_ios_native_checks.py`: 7 tests PASS. `git diff --check` and Go formatting checks PASS.
- Fresh `LedgerCore.xcframework` built from the fixed Go source for device and simulator. iOS simulator SDK Swift typecheck/native link with `LEDGER_BOUNDED_READ_INDEX` PASS.
- Standalone iOS 27 Simulator Swift -> Objective-C -> Go -> system SQLite smoke PASS: exact quote strings, direct/inverse legacy cents, missing quote, int64 extremes, overflow, schema 1/2 manifest rejection, schema-2-shaped SQLite rejection, retained selected reader, explicit schema-3 rebuild, cancel, lock/reopen, and permanent close. Temporary diagnostics were removed before the passing build.

## Boundaries And Remaining Steps

1. Follow refreshed PR #416 checks after publication of these fixes; recheck mergeability and conflicts. Before the fixes, hosted Swift, Backend/Gate, and both native build configurations passed; the Vercel preview status failed and its cause was not yet inspected.
2. Keep draft status until acceptance is agreed. The smoke used a standalone simulator executable and an owned synthetic directory with trusted ancestors. The simulator's default data ancestor was group-writable and was correctly rejected; actual app-container policy and physical-device file protection remain broader-task gates.
3. Physical-device cancellation, memory/latency, large-price-graph behavior, and default-mode/reporting/BQL migration remain under the parent plan. No private ledger or physical device was used here.

Earlier sandbox failures (Keychain access, TCP test listeners, simulator service access) were rerun after permissions were restored. Full Go/Swift results above supersede those environment failures. Local simulator harness, exact commands, artifact paths, and raw logs are recorded only in the local checkpoint.
