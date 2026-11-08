# 20261108-ios-motion-polish

- Status: completed — local commits on `codex/ios-motion-polish`, not pushed, no PR.
- Last updated: 2026-11-08 18:25 UTC+8.
- Branch: `codex/ios-motion-polish`, based on `main` at `f58874e8`; code covered
  by this note ends at `63327c06`.

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
- The filter settle block (合计) and day summaries roll their totals. The settle
  block keeps `Text` plus the shared modifier rather than `BalancedAmount`,
  because `minimumScaleFactor` mismeasures inside List rows.
- Behaviour change: day summaries now mask to `••••••` when amounts are hidden.
  They were never masked before.
- Charts (accounts net worth, account balance trend, cash flow trend, analysis
  net worth) reveal from the leading edge once per view lifetime; range changes
  do not replay it.
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

- `cd App/LedgerMobile && swift test` — pass: XCTest 889 executed, 22 skipped, 0 failures;
  Swift Testing 21 tests in 2 suites passed.
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
  the import completion reveal, confirmed-deletion hide, and the UI test suite.

## Remaining / next

1. Review and open a PR from `codex/ios-motion-polish` (需要发版：iOS 动效统一).
2. Follow-up: animate a newly saved row into the list. It depends on the list
   keeping rows on screen across saves (large-ledger perf work).
3. Follow-up: `PressScaleButtonStyle` / `TactilePillButtonStyle` still gate
   their haptic on Reduce Motion; haptics should be independent of it.
4. Follow-up: the island notice content belongs to the island work, not here.
5. Separate fix: make `testInterruptionNotificationNamesTheCause` main-actor
   isolated so `LedgerMobileTests` builds again.
