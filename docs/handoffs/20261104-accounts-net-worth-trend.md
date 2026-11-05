# 20261104-accounts-net-worth-trend

- Status: completed — PR #597 squash-merged to `main` as `180aa49c`.
- Last updated: 2026-11-05 00:05 UTC+8.

## Goal

The accounts page gained a net-worth trend line with 1月 / 3月 / 6月 / 今年 / 1年 /
全部 buttons (PR #597). Tapping the buttons changed nothing and the curve
followed the header's global time range, because the chart read
`netWorthHistory`, which the bootstrap only fills for the requested range.

## Decisions

- The chart windows cut the **ledger's own** net-worth history, not the selected
  period, so the buttons stay meaningful inside a one-month view.
- The bootstrap payload carries one bounded series (`netWorthTrend`): every point
  in the final 92 days, the last point of each earlier month, hard cap 240
  points. The bound keeps the native bootstrap page inside its 1 MB budget on a
  multi-year ledger.
- The series is cut at the selected period's end (`netWorthTrendHistory(before:)`)
  so the curve finishes on the closing figure the header prints, matching how the
  web net-worth page scopes its chart.
- `netWorthHistory` keeps its period contract; clients that predate
  `netWorthTrend` fall back to it.
- The chart (and its picker) stays amounts-hidden safe: it draws no figures, and
  the server still returns an empty series while sensitive values are locked.

## Follow-up: readable curve (commit ba44dcfc)

The first cut sent the raw series to the chart, so the line was dense with sharp
corners and had no scale. Now each window thins its series to a budget
(`NetWorthTrendRange.pointBudget`: a month day by day, `全部` as a shape, 40-64
points) by keeping real closing points — never averaged — draws it with
Catmull-Rom smoothing, and labels three dates and three compact amounts. Amount
labels mask with the ledger amounts; the silhouette stays.

## Changed files

- `server/internal/app/ledger.go` — `NetWorthTrendPoints`, trend budgets.
- `server/internal/app/read_models.go`, `ledger_read_service.go` — `netWorthTrend`
  in the bootstrap payload.
- `server/internal/app/net_worth_trend_test.go` — bounding, ordering, and
  payload-level regression tests.
- `server/internal/app/ledger_read_service_test.go`, `local_response_test.go` —
  JSON contract and required-collection updates.
- `App/LedgerMobile/Sources/LedgerModels.swift` — `netWorthTrend` decoding,
  `NetWorthTrendRange` (moved from `AccountsView.swift` so it is testable),
  `LedgerBootstrap.netWorthTrendHistory(before:)`.
- `App/LedgerMobile/Sources/AccountsView.swift` — chart reads the new history,
  thins it per window, smooths it, and draws the scale labels.
- `App/LedgerMobile/Sources/LedgerModels.swift` — `pointBudget`, `series(_:)`,
  `LedgerNetWorthPoint.sampled(_:maxPoints:)`.
- `App/LedgerMobile/Sources/LedgerSession.swift` — `replacingTransactions` keeps
  the series.
- `App/LedgerMobile/Sources/SafePreviewLedgerAPI.swift` — preview carries dated
  trend points so screenshots show a real curve.
- `App/LedgerMobile/Tests/LedgerModelsTests.swift` — decode, fallback, and window
  tests.
- `App/LedgerMobile/DESIGN.md`, `FEATURE_PARITY.md` — chart contract.

## Validation

- `cd server && go build ./... && go test ./...` — pass.
- `cd App/LedgerMobile && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test`
  — 879 tests, 22 skipped, 0 failures.
- `xcodebuild -scheme LedgerMobile -destination 'generic/platform=iOS Simulator' build`
  — succeeds (covers `AccountsView.swift`, which the SwiftPM target excludes).
- `scripts/build-ios-ipa.sh --private-local` — packaged 0.3.0 (47) then (48)
  successfully; ad-hoc IPA verified by the script.
- Not tested: on-device UI run and the UI test suite. `xcodebuild test` is
  blocked by a pre-existing app-host compile error in
  `Tests/LedgerAgentTests.swift:666` (main-actor isolation), and a headless
  simulator launch of the debug app fails, so the chart was reviewed from code
  rather than a screenshot.

## Remaining steps

1. Done: PR #597 merged (`180aa49c`). No follow-up code is pending.
2. Packaging already rebuilds the `LedgerCore` xcframework, so the embedded Go
   engine returns `netWorthTrend`; local ad-hoc builds 0.3.0 (47) and (48) were
   produced from the branch that became this merge.
