# 20261108-ios-island-redesign

- Status: completed — local commits on `codex/ios-island-redesign`, not pushed, no PR.
- Last updated: 2026-11-08 (UTC+8).
- Branch: `codex/ios-island-redesign`, based on `main` at `f58874e8`; code
  covered by this note ends at `8a41c885` (review fixes included).

## Goal

Redo the in-app Dynamic Island confirmation for saved entries and imports.
Before, every manual save showed the bill-import notice ("快速记账导入") in a
354x115 slab with a fake progress track and rolling digits that landed on
wrong values. Ledger writes keep preview, validate, then append; bean-check /
canonical validation and rollback are untouched. Versions are unchanged.

## Decisions

- Single-row card (~88pt) under the camera band, then a compact pill, then
  retract. Every frame is a pure function of time (`LedgerIslandStage`), so a
  new notice interrupts mid-flight and keeps the shape's velocity. Reduce
  Motion crossfades settled shapes instead of morphing.
- Callers say what they prepared (`BookkeepingPreviewView.IslandNotice`): one
  entry shows payee, category label and signed amount; several entries or a
  pasted .bean file show a count; a bill import shows the provider and count.
- One hue per notice: expense #CF7A52, income #4FBFAB (dark `BalancedPalette`
  values, since the island is always black); transfer, entries and imports
  are white.
- Compact pill: the disc shows the category symbol for one entry
  (`LedgerCategoryIcon`, shared with the transaction list), the tray for an
  import, the check for several entries. The expanded disc draws the check.
- The pill's trailing text (`LedgerIslandNotice.compactText`) is built from
  minor units, never by re-parsing the display string (comma-decimal regions
  would scale it 100x). Counts use the short key
  `LedgerIsland.compactCount` ("128 笔" / "128 txns").
- Notices reach the overlay via `LedgerIslandNotices.post`, not published
  session state. VoiceOver gets an announcement.
- The import Live Activity uses the same disc and hue and a two-stage track
  (written, indexed) instead of a timed fake progress.

## Changed files

- `Sources/LedgerIslandEntryView.swift`, `LedgerIslandMotion.swift`,
  `LedgerIslandTypography.swift` — stage, layout, rendering.
- `Sources/LedgerModels.swift` — notice model, `LedgerCategoryIcon`.
- `Sources/TransactionVisualCategory.swift` — uses `LedgerCategoryIcon`.
- `Sources/BookkeepingPreviewView.swift` and callers
  (`TransactionViews.swift`, `NaturalLanguageBookkeepingView.swift`,
  `NativeImportFlowView.swift`, `BeanTransactionImport.swift`).
- `Sources/BookkeepingPipeline.swift`, `LocalLedgerRepository.swift` —
  `PreparedBookkeepingChange.entryCount` for .bean input (count only; the
  write path is unchanged).
- `Sources/MoneyText.swift` — optional `maximumFractionDigits` on `format`.
- `Sources/LedgerSession.swift`, `RootView.swift` — direct notice post.
- `Resources/Localizable.xcstrings` — English for the new island strings.
- `WidgetExtension/ImportIndexLiveActivity.swift`, `WidgetDesign.swift`.
- `Tests/LedgerIslandMotionTests.swift`, `Tests/LedgerIslandNoticeTests.swift`.

## Validation (at `8a41c885`)

- `cd App/LedgerMobile && swift test` — pass: XCTest 889 executed, 22
  skipped, 0 failures; Swift Testing 20 tests in 2 suites passed.
- `xcodebuild build -scheme LedgerMobile` (iPhone 17 Pro simulator,
  `CODE_SIGNING_ALLOWED=NO`) — succeeds, no warnings in changed files. The
  built bundle's `en.lproj` contains the new keys and the
  `LedgerIsland.compactCount` plural.
- `xcodebuild test -only-testing:LedgerMobileTests` — test build fails at
  `Tests/LedgerAgentTests.swift:768` (main-actor isolation). The file is not
  touched here and the same error reproduces on `main` at `f58874e8`, so the
  app-host unit tests did not run.
- `cd server && go test ./... && go build ./cmd/ledger-web` — pass (1169
  tests). No Go changes on this branch.
- Not tested: the animation frame by frame on a device, haptics, VoiceOver
  announcement, English UI and comma-decimal regions on a simulator, the
  Live Activity rendering, and the UI test suite.

## Remaining / next

1. Review and open a PR from `codex/ios-island-redesign`
   (需要发版：灵动岛入账反馈重做).
2. Separate fix: make `testInterruptionNotificationNamesTheCause` main-actor
   isolated so `LedgerMobileTests` builds again.
