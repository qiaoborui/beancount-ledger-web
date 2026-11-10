# 20261110-home-spending-trend

- Status: completed (awaiting PR review)
- Last updated: 2026-11-10 18:00 (+08:00)
- Branch: `codex/home-spending-trend`, based on `main` at `51a3dafb`

## Goal

The iOS overview gets a quick trend chart of recent monthly spending. The user chose design variant A from `docs/design/ios-balanced/home-trend.html`: monthly expense bars with a 6/12 window, average of ended months, month-end estimate for the month in progress, and "查看该月" to jump the global range.

## Decisions

- One server field, `monthlyExpenseTrend` (`[{month, expense}]`, up to 12 months), is added to the bootstrap and lite bootstrap. Remote and local-ledger modes both read it. The window ends at the month of the period's last day, capped at today's month, and is trimmed to the ledger's first month.
- Swift decodes the field with `decodeIfPresent ?? []`. With an empty field, the module is hidden (older servers).
- `OverviewExpenseTrend` (LedgerModels.swift) holds the logic:
  - The average covers ended months only.
  - The estimate appears from day 5 and is cleared on the month's last day.
  - It needs at least 2 months to draw.
- The chart is drawn with SwiftUI shapes, not Swift Charts, so it can have the hatched estimate box and top-rounded bars.
- `LedgerSession.now` exposes the pinned clock, so previews and tests drive the in-progress month.
- Feature PR only: `MARKETING_VERSION` and the build number are untouched. A release is still needed.

## Validation

- `server/`: `go test ./...` passed (1215 tests); `go build ./cmd/ledger-web` succeeded.
- `App/LedgerMobile`: `swift test` passed (953 tests, 0 failures); the Xcode simulator build of the LedgerMobile scheme succeeded.
- Safe-preview screenshots were checked in light and dark mode, with the preview clock temporarily moved to mid-month and then reverted.
- Not tested: tap selection, the 12-month window (the preview has only 6 months), VoiceOver, and a real device.

## Next

Review and merge the PR, then include it in the next iOS release.
