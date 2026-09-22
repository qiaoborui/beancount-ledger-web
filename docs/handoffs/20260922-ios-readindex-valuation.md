# 20260922-ios-readindex-valuation

- Status: active; updated 2026-09-22T15:18:00+08:00. App-container milestone `3dcb6a4` and verified BoundedRelease IPA complete. Physical-device connectivity blocks installation/testing; broader device acceptance remains open.
- Parent: `20260921-ios-bounded-read-model`. Current goal: finish Apple verification of bounded valuation and resolve reproducible failures. Keep the default application mode unchanged; no merge, release, production mutation, or reporting/BQL expansion authorized.
- Branch: `codex/ios-readindex-valuation`; Graphite parent `codex/ios-validation-concurrency-fixture` (PR #415). Base `7629d60e6c466aef2d565bd851a0ca2ff5072747`.
- Draft PR: [#416](https://github.com/qiaoborui/beancount-ledger-web/pull/416). Remote last verified open, draft, and mergeable at `7f79fd7812c2521c54b80287bfb64b17363a1ce7`. This note accompanies the subsequent app-container and packaging code milestone; refreshed hosted checks follow publication.

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

1. Refreshed PR #416 Backend, Frontend, Swift package, Gate, and both native configurations passed at `7f79fd7`. Vercel preview failed when its image registry reached the image-count limit; image construction succeeded. Remote image cleanup requires separate authorization.
2. Keep draft status until acceptance is agreed. The earlier standalone smoke used a trusted synthetic directory. Subsequent real app-container testing reproduced the system-ancestor incompatibility and verified the iOS-specific boundary fix below. Physical-device file protection remains a broader-task gate.
3. Physical-device cancellation, memory/latency, large-price-graph behavior, and default-mode/reporting/BQL migration remain under the parent plan. No private ledger or physical device was used here.

Earlier sandbox failures (Keychain access, TCP test listeners, simulator service access) were rerun after permissions were restored. Full Go/Swift results above supersede those environment failures. Local simulator harness, exact commands, artifact paths, and raw logs are recorded only in the local checkpoint.

## Private IPA Delivery

- User requested a private IPA and Python LAN download. Built clean `7f79fd7` using `bash scripts/build-ios-ipa.sh --private-local <fresh-output-directory>` with Xcode 27.0 (27A5252f), iPhoneOS SDK 27.0. Default Release behavior is preserved.
- Artifact: `com.qiaoborui.ledger.mobile.ipa`, 30,846,004 bytes. SHA-256: `22e1881f4b7ec9ab008c156671e8857606defc2745c26fb483013755bc56d621`.
- Fresh Go and Beancount/Python builds, arm64 checks, app/Widget/Share App Group entitlements, 48 embedded-framework signatures, deep app signature, bundled runtime resources, ZIP integrity, and checksum passed.
- Detached Python server exposes only the artifact directory on the LAN interface. A complete download through the LAN address returned HTTP 200; its SHA-256 and ZIP integrity passed. The request originated on the build Mac; phone connectivity and SideStore/iLoader installation remain untested.
- Exact local directory, download URL, server PID, log, and stop command are in the local checkpoint. No IPA or LAN address is committed to the public repository. Keep private-use licensing limits and self-signing renewal compatibility.
- This ordinary Release IPA remains available separately. The user then authorized continued bounded-mode packaging and app-container/device testing.

## App-Container And Bounded Packaging Milestone

- A real app-hosted test validated the synthetic ledger and exported its stream successfully, then failed native root pinning with `unavailable`. The old walk inspected a simulator system directory with mode `0775` above the app container. The earlier standalone executable did not exercise this boundary.
- Native iOS code now obtains the canonical application home from Foundation. Descendant roots validate all ancestors through that OS-provided container, including the container itself. Owned private roots/files, symlink denial, inode pinning, and descendant permissions remain required. Paths outside the container and other platforms keep the full filesystem-root policy. No caller-controlled trust-anchor API is exposed.
- Added nine host ancestor-policy cases and actual `BoundedNativeIntegrationTests` in the app Application Support directory. Default production Python exporter and native Go/SQLite client are used with 205 and 10,000 synthetic transactions. Both tests pass on iOS 27 simulator: publication, complete 100-row pagination, account balance, quote/valuation, scope invalidation, lock/cancel/reopen, and file mode. The physical-device protection-class assertion is retained for device runs; the simulator supplies no protection attribute.
- Native CI now executes these app-container tests in its BoundedDebug job after building real dependencies. Local workflow contract8 and packaging contract10 pass. Full macOS Swift suite504 tests/15 existing skips/zero failures, full Go suite, targeted readindex race suite, fresh device/simulator framework, shell syntax and diff checks pass. Independent security review found no high-confidence issues.
- Private packaging accepts `--configuration Release|BoundedRelease`, with Release as the unchanged default. Before archiving it verifies the actual bounded compilation flag for the app, Widget and Share targets. Both configurations use the requested `com.qiaoborui.ledger.mobile.ipa` filename in separate directories; metadata records the configuration. Existing private-use and re-signing gates remain intact.
- First physical-device test failed before installation: Xcode destination preparation timed out, followed by CoreDevice4016 connectivity errors. Existing phone installation and private ledger were left unchanged. Exact device state and local logs are in the checkpoint.
- Committed code revision: `3dcb6a452c1bc4bd0194916fb7c59affbecb5e39`. Built clean BoundedRelease IPA from this revision with Xcode27.0/SDK27.0. App/Widget/Share bounded flags, arm64, App Groups, deep app signature,48 embedded-framework signatures, runtime resources, ZIP and SHA-256 passed. Artifact is `com.qiaoborui.ledger.mobile.ipa`,27,722,596 bytes; SHA-256 `f4eaa86ac78d71fd3fa46209c72b658c89fa93e4f05f4df1e7c7b8a455458393`.
- Python LAN hosting retains the ordinary Release file and serves BoundedRelease separately. Full bounded download returned HTTP200 and matched SHA-256/ZIP checks. Simulator launch screenshot confirms the experimental locked shell. Temporary QA simulator was shut down and deleted; existing simulators and phone app were preserved. Independent architecture review found no concrete introduced regressions.
- This documentation-only follow-up records the code revision above. Next: inspect refreshed PR checks, retry device tests after trusted connectivity is restored. Physical lock transitions, file protection, memory/latency and larger-scale acceptance remain open. Full reports/BQL/write/import/Widget parity and the default-mode switch remain parent-task work.
