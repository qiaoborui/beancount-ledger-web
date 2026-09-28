# 20260928-ios-terminal-overview

Status: completed. Updated: 2026-09-28T15:18:06+08:00.

## Goal and accepted scope
Implement the approved terminal overview in native SwiftUI, with light/dark themes, then correct the oversized first implementation to match the reference proportions. Keep one compact title/date/sync row, plain date selection, no local-only status text, and existing financial/privacy/manual-confirmation behavior. This increment includes overview, shared visual primitives/date controls, and compact navigation; analysis and other content screens remain for later work.

Branch: `codex/ios-terminal-overview`. Code revision covered: `584f5a0e8d00d5a58a31b8bd539625cff00b3752`. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/498. Code and screenshots are committed; the checkpoint and code are being published together. No merge or release is authorized/performed. Check the PR for current remote CI state.

## Completed
Reference CSS dimensions are documented in `docs/design/ios-terminal/README.md`. Overview now has a square summary, 28 pt medium net, separate income/expense ratio bars, a 13 pt table containing every positive category, and independent recent-transaction dates. Currency symbols are omitted where the unit is established; mixed-currency rows and VoiceOver retain currency context.

Compact chrome uses a 56 pt header with plain 13 pt date and 18 pt status glyph, plus a flat 60 pt tab strip. Native TabView stacks and configurable destinations remain; search is reachable in More. Non-root overview has an explicit back button. Regular-width navigation retains native sidebar controls. Local Git status comes from the existing storage presentation; tapping status opens details without starting synchronization. Server preview mode retains an explicitly labeled refresh action and does not pretend to have Git status.

Content scales with Dynamic Type; accessibility category rows and section headings stack, and ratio/date columns grow. Amounts, proportions, and bars respect privacy masking. Images include light, dark, local Git synced, date sheet, hidden amounts, and largest text.

## Verification
Xcode simulator builds passed. During this correction, 34 `LedgerModelsTests` passed, including sign/precision behavior for currency-free formatting. Nine unique UI scenarios passed across the 375 pt light/dark runs: four overview scenarios, local Git sync/details, custom tab add/reorder and non-root overview back, overflow navigation persistence, search return to More, and search state across tabs/detail. Final five-scenario overview/local-sync run passed on the final source. The final build was also installed and visually inspected on the main larger iPhone simulator.

Initial failures exposed stale analysis-title assertions and small-screen first-ledger/keyboard test setup; the harness now waits for onboarding dismissal, follows the existing initial-navigation retry convention, and submits the repository field before scrolling. All affected scenarios were rerun successfully. Architecture review found and resolved non-root back navigation and content text-scaling issues; final review had no new blocking findings. `git diff --check` passed.

No real ledger was read or mutated; safe preview data and UUID-isolated local fixtures with in-memory Git transport were used. No full-app UI sweep, iPad runtime, physical-device, signing, or IPA acceptance claim.

## Files and next step
Changed sources: `OverviewView.swift`, `TerminalDesignSystem.swift`, `RootView.swift`, `MoreView.swift`, `DesignSystem.swift`, `MoneyText.swift` under `App/LedgerMobile/Sources/`. Related unit/UI selectors and navigation tests are updated. Evidence: `docs/design/ios-terminal/`.

The requested correction is complete. Next step is visual review of the updated screenshots/PR; remaining content-page migration is separate work. There are no remaining local implementation tasks for this increment.
