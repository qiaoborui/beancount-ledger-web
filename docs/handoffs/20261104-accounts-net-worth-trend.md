# 20261104-accounts-net-worth-trend

- Status: active — code pushed on `fix/money-flow-direction-live-activity-glass`
  (PR #597), waiting for review/merge.
- Last updated: 2026-11-04 22:55 UTC+8.

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
- `App/LedgerMobile/Sources/AccountsView.swift` — chart reads the new history.
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
- Not tested: on-device UI run, UI test suite, and a rebuilt `LedgerCore`
  xcframework (the simulator build above linked the previously built framework,
  so local-session payloads only show `netWorthTrend` after
  `scripts/build-ledgercore-xcframework.sh` runs again).

## Remaining steps

1. Review and merge PR #597.
2. When packaging, rebuild the `LedgerCore` xcframework so the embedded Go engine
   returns the new field; the app falls back to the period-scoped history
   otherwise.
