# 20261108-ios-motion-polish

- Status: completed — local commits on `codex/ios-motion-polish`, not pushed, no PR.
- Last updated: 2026-11-08 19:05 UTC+8.
- Branch: `codex/ios-motion-polish`, based on `main` at `f58874e8`; code covered
  by this note ends at `24602a1e` (review fixes included).

## Goal

Give the iOS app one consistent motion language without changing ledger
behaviour: shared motion tokens with a Reduce Motion fallback, a livelier fast
entry keypad, staged import flow, animated list states and totals, and a
one-shot chart reveal. Ledger writes keep preview, validate, then append;
bean-check / canonical validation and rollback are untouched.

## Decisions

- `LedgerMotion` (in `DesignSystem.swift`) owns every curve: `value`, `entry`,
  `toggle`, `segment`, `selection`, `disclose`, `press`, `privacy`, `stage`,
  `reveal`, plus `stageTransition`. `withLedgerAnimation` and
  `.ledgerAnimation(_:value:)` drop the animation under Reduce Motion, so
  migrated call sites honour it without their own checks.
- `.ledgerRollingAmount(_:)` is the one rolling-figure modifier (numericText,
  opacity under Reduce Motion, privacy fade). `AmountLabel` and `BalancedAmount`
  both use it, so `BalancedAmount` now also fades on privacy toggles.
- Fast entry: each keypad key gives exactly one haptic. Keys turn off the press
  style's haptic and keep their own selection tick; save gives a light tap. The
  display and the "= result" line roll with numericText.
- Import flow is modelled as `ImportStage` (preparation, parsing, review,
  completion) with asymmetric transitions. The completion page draws its rules
  and settles its heading once, after the bookkeeping preview sheet closes. No
  extra success haptic. Reduce Motion and UI-test fixtures (`--safe-*` /
  `--local-*`, via `LedgerMotion.allowsAmbientMotion`) show it fully drawn, so
  UI tests can assert on the text immediately.
- List: the loading row crossfades into rows, the mutation badge transitions
  with its phase, and a confirmed deletion hides its local row with an
  animation (view-side filter on `transactionResolution(for:) == .unavailable`;
  no `LedgerSession` change). Before, the row stayed until the next generation.
  The list animation is keyed on the placeholder showing, not on
  `isAwaitingRows`, so infinite-scroll appends are never animated; the
  deletion animation is keyed on the hidden deletion row IDs only, so edits
  and bulk tag adds do not animate the list.
- The filter settle block (合计) and day summaries roll their totals. The settle
  block keeps `Text` plus the shared modifier rather than `BalancedAmount`,
  because `minimumScaleFactor` mismeasures inside List rows.
- Behaviour change: day summaries now mask to `••••••` when amounts are hidden.
  They were never masked before.
- Charts (accounts net worth, account balance trend, cash flow trend, analysis
  net worth) reveal from the leading edge on first appearance. The analysis
  pages and account detail rebuild their charts on every reload (cached vs
  loaded branch, loading row), so they hold a `LedgerChartRevealMemory` in
  the environment and the reveal plays once per screen; range changes, saves
  and returning from a pushed row do not replay it. The accounts net worth
  chart stays mounted and keeps the per-view-lifetime default.
- `LedgerIsland*`, `LedgerAgent*`, `LedgerLaunch*` and `LedgerSession.swift`
  are untouched. Versions are unchanged.

## Changed files

- `App/LedgerMobile/Sources/DesignSystem.swift` — tokens, helpers, rolling
  amount and chart reveal modifiers.
- `App/LedgerMobile/Sources/BalancedDesignSystem.swift` — `BalancedAmount` uses
  the shared modifier.
- `App/LedgerMobile/Sources/TransactionViews.swift` — keypad haptics and
  rolling display, list states, badge, confirmed-deletion hide, rolling totals,
  day-summary masking.
- `App/LedgerMobile/Sources/NativeImportFlowView.swift` — stages and
  completion reveal.
- `App/LedgerMobile/Sources/AccountsView.swift`, `AnalysisViews.swift` — chart
  reveal and token migration.
- Token migration only: `PendingInboxView.swift`, `EventTagViews.swift`,
  `ReconciliationView.swift`, `TransactionShareView.swift`,
  `OnboardingWizardView.swift`, `CurrencyAnalysisView.swift`, `RootView.swift`.

## Validation

- Re-run after review fixes, at `24602a1e`:
- `cd App/LedgerMobile && swift test` — pass: XCTest 889 executed, 22 skipped, 0 failures;
  Swift Testing 21 tests in 2 suites passed. (One earlier run under heavy
  concurrent load reported 1 expected failure, 0 unexpected; the rerun was clean.)
- `xcodebuild build -project LedgerMobile.xcodeproj -scheme LedgerMobile
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO`
  — succeeds, no new warnings in changed files.
- `xcodebuild test ... -only-testing:LedgerMobileTests CODE_SIGNING_ALLOWED=NO`
  — test build fails at `Tests/LedgerAgentTests.swift:768` (main-actor
  isolated `LedgerAgentBackgroundRun.summary` called from a nonisolated test).
  The same error reproduces on `main` at `f58874e8`; it is pre-existing and not
  touched here, so the unit tests did not run.
- Simulator (iPhone 17, `--safe-preview`): transactions list and fast entry
  sheet (`--open-create-transaction`) render correctly at rest.
- Not tested: the animations themselves frame by frame, haptics on a device,
  the import completion reveal, confirmed-deletion hide, page appends staying
  unanimated, the chart reveal not replaying on reload, and the UI test suite.
  No unit test pins the day-summary masking or the confirmed-deletion filter:
  `TransactionViews.swift` is outside the Swift package and `LedgerMobileTests`
  does not build (see above).

## Remaining / next

1. Review and open a PR from `codex/ios-motion-polish` (需要发版：iOS 动效统一).
2. Follow-up: animate a newly saved row into the list. It depends on the list
   keeping rows on screen across saves (large-ledger perf work).
3. Follow-up: `PressScaleButtonStyle` / `TactilePillButtonStyle` still gate
   their haptic on Reduce Motion; haptics should be independent of it.
4. Follow-up: the island notice content belongs to the island work, not here.
5. Separate fix: make `testInterruptionNotificationNamesTheCause` main-actor
   isolated so `LedgerMobileTests` builds again.
6. Follow-up: once tests build, move the confirmed-deletion predicate into a
   testable helper (confirmed delete hidden; confirmed edit, pending delete and
   failed delete kept) and assert the day summary masks when amounts are hidden.
7. Call out the day-summary masking (a privacy fix) in the PR body.
