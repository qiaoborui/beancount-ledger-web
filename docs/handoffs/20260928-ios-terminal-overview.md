# 20260928-ios-terminal-overview

Status: completed. Updated: 2026-09-28T14:43:52+08:00.

## Delivered scope
Native SwiftUI terminal overview and reusable light/dark colors, amounts, rules, and page chrome. One title/date/status row; no local-only sync indicator; configured Git opens existing storage details. Overview contains net balance, income/expense, spending matrix, and recent transactions, with no quick-entry dock or repeated period row. Shared date controls retain draft/apply/cancel and have 44 pt targets. Financial calculations, local aggregation, privacy masking, and manual write confirmation reuse existing code.

Branch: `codex/ios-terminal-overview`. Code revision: `febe8ab07d3425ce21d696d42947c2b4801deba6`. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/498 (open, not merged; no merge conflicts when checked). Code, screenshots, and this note are committed/pushed through the branch workflow. CI was running at the initial PR check; native acceptance is based on the local simulator results below.

## Validation
Xcode simulator build passed. `LedgerModelsTests` and `LocalSyncPresentationTests`: 40 passed. `LedgerSessionTests/testRangeSteppingEditsOnlyDraftUntilConfirmation` and `testInjectedLedgerClockKeepsCalendarRangesStable`: 2 passed. `TerminalOverviewUITests` covers date cancel/apply and detail return, largest accessibility text/reachability, and amounts/percentage privacy; all passed on iPhone 13 mini (375 pt), with date/detail also rerun successfully in dark mode. iPhone 17 Pro checks also passed for date/detail, large text, and `LocalSyncToolbarUITests` local-only/configured Git behavior. Initial date-label assertion failure was corrected and rerun green. Architecture/security specialists found no new issues. `git diff --check` passed.

Light/dark, date-sheet, privacy, and accessibility images were exported from safe-preview UI tests and visually inspected: `docs/design/ios-terminal/README.md`. Local sync tests used UUID isolation and an in-memory Git transport. No real ledger was accessed. No full-app UI sweep, physical-device, signing, or IPA delivery claim.

## Files and next step
Changed: `App/LedgerMobile/Sources/OverviewView.swift`, `TerminalDesignSystem.swift`, `DesignSystem.swift`, `TimeRangePicker.swift`; `App/LedgerMobile/Package.swift`; three UI-test files; design evidence and this handoff.

This first increment is complete. Next product increment: migrate income/expense and asset analysis to the same terminal components, then remaining pages and navigation. Those screens and the existing tab bar are outside this PR. Review the native screenshots/PR before merging; no merge or release was performed.
