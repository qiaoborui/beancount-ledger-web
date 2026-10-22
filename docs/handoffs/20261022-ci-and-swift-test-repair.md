# 20261022-ci-and-swift-test-repair

- Status: completed
- Updated: 2026-10-22 21:55 (Asia/Shanghai)
- Branch: qiaoborui/codex-fix-ci-swift; PR https://github.com/qiaoborui/beancount-ledger-web/pull/533
- Code revision: PR head, two commits on top of main 09c730a

## Goal
Make CI green and `swift test` in `App/LedgerMobile` work again, and remove the
Vercel deployment now that the iOS app is the product.

## What was broken
- `Package.swift` listed sources by hand. `LocalModelRequestGate` and
  `LocalCanonicalStreamCache` were missing while `LocalLedgerEngine` used them.
- `LedgerIslandFonts` and `LedgerIslandTextLayout` lived in
  `LedgerIslandEntryView.swift`, which the package excludes because it imports
  SwiftUI/UIKit; `LedgerIslandMotion.swift` and its tests need the type metrics.
- `BalancedBucketAxis` lived in `TerminalAnalysisViews.swift` (Charts + palette).
- `LocalLedgerEngine` called `release`/`nativeResponse` outside the
  `canImport(LedgerCore)` region.
- Several tests need the iOS app host: SwiftUI receipt rendering, the bundled
  launch resources, and `PerfProbeTests` (already marked not-for-commit).
- CI's `pnpm audit --audit-level=high` gate failed on `vite` (GHSA-587h-7wmj-h5pm)
  and `source-map-js` (GHSA-68fv-2mgg-jv7q).
- `test-deploy-selfhost-submit.sh` fails on this Mac (bash 3.2 cannot parse the
  associative array in `scripts/selfhost/beancount-ledger-deploy-submit`). It
  fails identically on `main`; CI runs it on Ubuntu, so it is not part of this
  task.

## Decisions
- Portable layout maths moved to new files the package compiles:
  `LedgerIslandTypography.swift` (fonts, Core Text measurement, text folding,
  `LedgerIslandTextLayout`) and `BalancedBucketAxis.swift` (labels only; the
  Charts `marks(for:)` stays in `TerminalAnalysisViews.swift` as an extension).
  Text is measured with Core Text so the same code runs on macOS and iOS.
- `LocalLedgerEngine` gained `releaseHandle`, a no-op without `LedgerCore`, and
  `concurrentResponse` returns nil there so the exclusive path reports
  `runtimeUnavailable`.
- App-host tests are excluded from the package target; the receipt test moved to
  `Tests/TransactionReceiptRenderingTests.swift`. Two Keychain tests
  (`BookkeepingPipelineTests`, `ImportClassificationTests`) now `XCTSkip`
  outside iOS instead of relying on the login keychain.
- `String(localized: "\(year)年")` grouped the year into "2,026年"; it now uses
  `.number.grouping(.never)`.
- `LedgerBackupStore` rebuilt listed entries from the caller's folder spelling,
  because `NSFileCoordinator` returns `/private/var/...` while the first backup
  used `/var/...`, so `.unchanged` never compared equal.
- CI has a new `iOS core` job: `swift test` on the self-hosted Mac runner for
  `App/`, `server/`, `examples/` and CI changes, gating the merge. Fork pull
  requests skip it. `.github/scripts/select-xcode.sh` picks the newest Xcode in
  /Applications for both this job and the IPA build, because the runner defaults
  to Command Line Tools whose `swift` cannot load the SwiftPM build service.
- Vercel removed entirely: root and `web/` configs, `Dockerfile.vercel` (the
  image publisher now builds `docker/Dockerfile` target `server`),
  `@vercel/speed-insights` plus its build flag, the routing test, ignore entries,
  and the doc references.

## Validation
- `swift test` (Xcode 27.0): 732 tests, 22 skipped, 0 failures.
- `pnpm run typecheck`, `pnpm run test` (277 passed), `pnpm run build`;
  `pnpm audit --audit-level=high` reports no high or critical findings.
- `go test ./...`: 1014 tests in 37 packages.
- Workflow guards `verify-deploy-google-cloud.sh`, `verify-deploy-selfhost.sh`,
  `test_ios_private_ipa.py` pass; all five workflow YAML files parse.
- PR 533 checks: Plan checks, Backend, Bub Agent, Frontend, iOS core and Gate
  pass. The only red check is the Vercel GitHub App's own status, which this
  change cannot remove from the repository settings.
- Not tested: the Xcode scheme's app-host tests (no Xcode project is checked in),
  and no physical-device run.

## Next
- The Vercel integration is still installed on the repository; disconnect it in
  GitHub settings so PRs stop showing a failed Vercel status.
