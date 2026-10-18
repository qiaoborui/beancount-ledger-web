# 20261018-ios-transactions-pager

- Status: active (PR opening; branch `codex/transactions-pager-apple`)
- Last updated: 2026-10-18 18:40 +0800
- Base: `main` @ `16a005e`

## Goal

The local-ledger Transactions list footer felt bolted on. Replace the floating
capsule pager with a control that reads as part of the terminal table, in the
spirit of Apple's page steering (HIG page controls / scroll views): one small
position indicator, plain chevrons next to it, no boxed buttons at the screen
edges, and nothing at all when there is only one page.

## Decisions

- One hairline rule (`TerminalRule`) separates the stepper from the rows; the
  bar is flat `BalancedPalette.page`, same as the list, not a capsule.
- Order is `‹  第 N 页 · 共 M 笔  ›` with the chevrons hugging the label
  (18 pt gaps) instead of pinned to the screen edges. Ink-coloured glyphs, meta
  third colour for the count, 13 pt Plex matching the table.
- "本页 N 笔" was dropped: it duplicates what is on screen and was the second
  line that made the bar look like a toolbar.
- **Superseded by infinite scroll** (user decision on the same day): the pager
  was removed entirely rather than restyled. Each list now appends one bounded
  window when its tail appears, so the reading position never jumps. See
  "Infinite scroll" below.

## Infinite scroll (delivered)

- `TransactionsView`: the list renders `LedgerSession.localTransactionAccumulatedRows`
  and appends the next window from its tail row. The
  `ScrollViewReader` that scrolled back to "transaction-list-top" on a page
  change is gone. Tapping the tail retries a stalled fetch.
- `LedgerSession`: `loadNextLocalTransactionWindow` now appends instead of
  replacing, keeps an id set for de-duplication, and stops at
  `localTransactionRowCap` (1,000 retained rows). `localTransactionHasMore` is
  false at the cap, and `localTransactionReachedRowCap` drives the honest
  "已加载 N 笔，收窄时间范围可以看得更远" note.
- `PendingInboxView`: same pattern. `accumulated` / `loadedIDs` / `continuation`
  replace the `page` index; `localWindow` still carries the complete counts so
  the band summary and tab badges describe the whole range.
- `AccountsView` account history: same pattern, capped by `historyRowCap`.
- Scroll smoothness: `MoneyText.format` used to build a new `NumberFormatter`
  per call (three per row, i.e. thousands per scroll pass). It now caches
  formatters by currency/sign/symbol behind a lock that also serialises the
  formatting call, because `NumberFormatter` is not thread safe.

## Changed files

- `App/LedgerMobile/Sources/TransactionViews.swift` (`pageNavigation`,
  `pageNavigationLabel`, `pageStepButton`, and its call site in the
  `safeAreaInset(edge: .bottom)` block).
- `App/LedgerMobile/UITests/LocalLedgerUITests.swift` — assertions now wait on
  the pager label instead of `staticTexts["第 N 页"]`, and the post-navigation
  readability check uses the quick-search field (the kind chips can scroll
  away).

`GlobalSearchView` and the widget day sheet still page with text buttons; they
are excluded from the portable Swift target and were not part of this change.

## Validation

- `xcodebuild build -project LedgerMobile.xcodeproj -scheme LedgerMobile`
  on iPhone 17 Pro simulator (iOS 27.0): passed.
- Full `xcodebuild test`: 771 passed, 7 skipped, 34 failed. All 34 failures
  reproduce on `main` with every change stashed (missing `sidebar-accounts`
  selectors, "Select All" menu lookups, etc.), so they are pre-existing.
- New tests: `testScrollingAppendsWindowsAndKeepsEarlierRows` and
  `testScrollingPastRetainedRowCapStopsFetchingAndSaysWhy` (the cap test lowers
  `localTransactionRowCap` to 300 because the fixture serves at most one
  500-row page per request).
- `LocalLedgerUITests/test292TransactionsScrollLoadsEveryRowWithoutJumping`:
  passed; screenshots show the list ending on "已全部加载 292 笔" with no jump
  and no pager.

## Remaining

1. Open the PR and watch CI.
2. The global search list (`GlobalSearchView`) still pages with text buttons;
   left alone because it is excluded from the portable Swift target and was not
   part of the reported problem.
3. The 34 pre-existing UI failures should get their own task.
