# 20261003-ios-event-report-all-history

Status: active (code complete, PR open, awaiting merge). Updated: 2026-10-03 19:03 +08:00.

## Goal and scope

Fix two reported iOS defects on the native event/project accounting screens
(`EventTagReportView`, `EventTagListView`):

1. Opening a tag from the transaction list under-counted the event whenever the
   tag's history extended beyond the selected date range. Aggregates, category
   shares, daily rhythm, the transaction list and the Markdown export were all
   clipped to `selectedRange`.
2. The report page showed an odd loading indicator: a "读取完整事件汇总" button
   flashed on first frame before switching to a spinner, and two independent
   inline `ProgressView`s appeared above the scroll content and shifted layout.

Approved decision: events/projects are independent accounting units, so their
reads default to **all history**. No range toggle was requested. Native iOS
only; the web client and the server's transaction page contract are unchanged
(the server already accepts `0001-01-01`/`9999-12-31`).

Out of scope: analysis pages that legitimately honour `selectedRange`
(income/expense dashboard, asset trends, reconciliation, widget day views),
server/Go code, and the web client.

Branch: `codex/ios-event-report-all-history`. Base revision: `0c4a238` (main).
Code revision: `a009f81`, pushed to origin. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/503
(MERGEABLE; `mergeStateStatus` UNSTABLE only because of the pre-existing Vercel
preview failure below).

## Completed

- `LedgerSession.allHistoryEventRange` (`0001-01-01` / `9999-12-31`) added and
  applied to all four event read paths: `localEventTagReport`,
  `localEventTagWindow`, `loadLocalEventTagSummaries`, and
  `prepareLocalEventReportExport`.
- `EventTagReportView` body reworked: the first-frame button branch is gone, and
  the aggregate / window / export states each render exactly one panel, so the
  loading UI no longer duplicates or shifts content.
- New terminal-styled components in `EventTagViews.swift`:
  `EventReportLoadingPanel`, `EventReportErrorPanel`, `EventReportInlineNotice`.
- Hero card now reads "事件独立核算 · 全部时间" in local mode.
- Share sheet accepts `completeTransactionCount`. The local row array is only
  the first bounded window, so the sheet now states the preview is partial and
  points at the complete Markdown file export instead of silently presenting a
  truncated list as complete.
- Pagination extracted to `paginationControls`.

## Validation

- `xcodebuild build -scheme LedgerMobile -sdk iphonesimulator -configuration Debug`:
  BUILD SUCCEEDED (Xcode-beta, iOS 27.0 simulator SDK).
- `xcodebuild test` for `LocalTransactionWindowSessionTests` plus the three event
  scan/export suites: 66 + 83 tests, 0 failures on iPhone 17 Pro / iOS 27.0,
  re-run against the committed revision `a009f81`.
- New regression `testEventReadsSpanAllHistoryRegardlessOfSelectedRange` asserts
  every event page request uses `0001-01-01`/`9999-12-31`. The pre-existing
  `testEventReportReturnsCompleteAggregatesWithoutChangingPresentation` was
  updated from `session.selectedRange` to the all-history bounds.
- Temporary DEBUG fixture (30 `#trip` rows across five months) drove the report
  page on the simulator: it rendered `30 笔流水`, span `2026-01-01 至 2026-05-06`,
  30 spending days, and the share sheet showed `共 30 笔`. Screenshots inspected
  and the fixture hook reverted before committing; no test-only code remains in
  the diff.
- Full `LedgerMobileTests` run: 684 tests, 3 failures, all Keychain-related
  (`BookkeepingPipelineTests`, `ImportClassificationTests`,
  `LocalGitBackgroundCredentialTests`). Reproduced identically on a clean
  `git stash` of this change, so they are pre-existing simulator-environment
  failures and unrelated.
- `LocalLedgerUITests/testLocalContextActionsHydrateCancelReopenAndCommit` fails
  at its transaction-creation step (line 418) both with and without this change.
  Pre-existing; the event-report assertions downstream of it were not exercised
  by the suite.
- The Vercel preview check fails on this PR. It is unrelated: the diff touches
  no `web/`, `server/`, Docker or `vercel.json` files, and PRs 500, 501 and 502
  (including already-merged ones) fail the same way.

Not tested: physical device, iPad, Release/IPA build, and the full UI suite. No
private ledger data was used; the temporary fixture was synthetic and isolated.

## Next step

PR 503 is open and mergeable; only the pre-existing Vercel preview check is red.
Merge when approved, then verify the report page on a physical device, since the
loading-panel change is visual and was only reviewed on one simulator size.
