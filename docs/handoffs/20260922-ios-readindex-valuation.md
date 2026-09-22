# 20260922-ios-readindex-valuation

- Status: active; updated 2026-09-22T13:17:34.364329+08:00. Implementation checkpoint ready for publication; Apple validation remains pending.
- Parent task: `20260921-ios-bounded-read-model`. User requested committing/pushing the current work and saving progress; no merge, release, default-mode switch, or further feature expansion requested.
- Branch: `codex/ios-readindex-valuation`; Graphite parent `codex/ios-validation-concurrency-fixture` (PR [#415](https://github.com/qiaoborui/beancount-ledger-web/pull/415)). Base revision `7629d60e6c466aef2d565bd851a0ca2ff5072747`; the implementation accompanies this checkpoint. Child PR pending creation.

## Scope and completed work

- Shared Go scalar valuation policy preserves direct, inverse, then byte-lexicographic DFS and per-edge cents truncation. Explicit `legacy_cents` int64 basis; depth 64 and 100,000-operation limits; overflow, cancellation and exhausted budgets fail explicitly. Existing application PriceIndex traversal remains intact except shared normalization helpers.
- Read-index schema 3 stores and verifies Go-normalized currency-pair keys. Indexed scalar price lookup retains raw exact quantities; bounded valuation avoids loading an entire price graph. Equal-date quotes select the last source sequence; parity with legacy unstable-sort ties is not claimed.
- Native bridge exposes `PriceLookup` and `ValueLegacyCents` with existing request/response caps and lifecycle guards.
- Swift adds both transports, strict result validation, int64 cents, raw decimal quote strings and revision-bound reader methods. Schema 1/2 indexes require explicit rebuild; failed rebuilds preserve the existing pointer. Default application/reporting behavior is not switched.
- Code changes: 16 Go files under `server/internal/ledger`, `server/internal/readindex`, `server/internal/app`, and `server/mobilereadindex`; six Swift files under `App/LedgerMobile/Sources` and `App/LedgerMobile/Tests`, including new `BoundedValuationTests.swift`.

## Validation and review

Against the current implementation based on `7629d60`, freshly checked in this publication session:

- Go 1.25.10, cgo enabled: `go test -p 1 ./...` PASS (cached package results); `go build -p 1 -o /dev/null ./cmd/ledger-web` PASS.
- Swift 6.0.3 Linux harness: 73 tests PASS, including all nine new valuation tests and extracted revision/lifetime reader checks. Harness uses the real client and selected source/tests, with platform stubs; excludes two existing Apple-validator-only tests and does not run the full publication suite.
- Apple-target frontend syntax parsing of all six changed Swift files PASS in default and `LEDGER_BOUNDED_READ_INDEX` modes. This is not Apple SDK typechecking or native linking.
- `git diff --check` PASS. Independent architecture and Go security reviews found no concrete blockers.
- Earlier implementation evidence: full Go/race passes and differential legacy comparisons (56,250 shared-policy, 2,880 SQLite cases). Those race runs were not repeated during publication.
- No private ledger, production mutation, local application server, or physical-device testing used.

## Remaining steps

1. Push this checkpoint and create a draft child PR; verify its base, head and mergeability.
2. Run hosted macOS Swift package tests and freshly rebuilt native simulator checks. Resolve failures before marking the PR ready; local harness/syntax checks do not replace these gates.
3. Verify old-index rebuild and new valuation calls through the native Apple bridge. Physical-device protection, cancellation, memory/latency and large-price-graph behavior remain broader-task gates.
4. Resume reporting/BQL/default-mode migration only under the broader plan, separately from this publication request.

The implementation is not claimed release-ready. No concrete source-level blocker was found; full Apple validation is the outstanding acceptance step.
