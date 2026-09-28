# 20260928-ios-terminal-reports

Status: completed. Updated: 2026-09-28 15:56 +08:00.

## Goal and scope

Continue the approved terminal design in native income/expense analysis, asset analysis and transactions. Match compact overview typography, ruled sections and a single date/sync header in light and dark mode. Preserve analytics, navigation, privacy, local paging and manual write confirmation. Account management, More, investment content and editing/detail sheets are outside this increment and retain existing styles.

Branch: `codex/ios-terminal-overview`. Code revision: `07c376a`. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/498. Code and screenshots committed; this handoff accompanies the same PR update. No merge or release authorized.

## Completed

- Added `TerminalAnalysisViews.swift`: metric grids, numbered sections, charts with numeric disclosure, category/merchant/account tables and event accounting. Accessibility sizes switch metrics to one column.
- Integrated reports into `AnalysisViews.swift` without replacing resource loading/caching or accounting logic.
- Migrated `TransactionViews.swift` to terminal rows, scoped quick search, flat filters and a contextual action menu. Preserved local paging, selection, mutation badges, context/swipe actions and confirmation sheets.
- Extended shared header with contextual actions and restored native back gestures for compact pushed pages, including the iOS 26+ content-area recognizer. Shared rows retain complete accessible dates and visible years across year boundaries.
- Fixed review findings: label asset snapshots as current rather than historical period-end; preserve event original currency; distinguish missing-price and unavailable-period data. Historical attribution and category-share comparisons are not fabricated.
- Saved safe synthetic screenshots under `docs/design/ios-terminal/`; updated its README. Updated navigation tests for the current header and More-based global search.

## Validation

Xcode simulator builds passed. The increment passed 34 `LedgerModelsTests` and nine unique UI scenarios across targeted runs: four report tests (date/header/drill-down, search/selection/detail, privacy, accessibility), local 292-row pagination, overflow return, overview accessibility, native back/cached reentry, and the isolated local create/edit/tags/export/search/delete flow. The final five-test run on the delivered source passed with dark appearance, including native back and all report tests. Light and dark 375pt screenshots were visually inspected. The delivered app was installed and launched on the larger main simulator, and its overview was inspected.

Initial visual checks caught abbreviated-date chart gaps and oversized metric spacing; corrected before final screenshots. The original native-back test failed after hiding the system navbar; enabling the public edge and content pop recognizers restored it and the unchanged gesture assertion passed. The local mutation test initially reached an obsolete Search-tab selector after the write flows passed; it now enters global search through More and the complete test passed.

No full-app sweep, iPad runtime, physical device, signing or IPA distribution acceptance. No private ledger was used. Tests wrote only UUID-isolated synthetic simulator ledgers.

## Next step

This three-page increment is complete. Check PR status before merging; continue account management and More styling as the next design increment. PR hosted web-preview status is separate from native simulator validation.
