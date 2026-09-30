# 20260930-ios-missing-code-audit

- Status: audit completed; restoration pending.
- Updated: 2026-09-30T15:56:44.131475+08:00
- Goal: identify missing changes from the previously delivered native iOS builds, including import and other page redesigns.
- Current checkout: `codex/ios-dynamic-island-entry`, HEAD `97c3bc6` (three existing bookkeeping source edits preserved).
- Reference: historical local deliveries based on `b921e5a`, up through the integrated Build 59. Those packages contained uncommitted changes beyond PR 498.
- Comparison: locally available `origin/main` at `ba52111`, plus brand restoration commit `8d69d15` (PR 502, new Build 57). Remote PR state was not refreshed during this audit.

## Confirmed missing

1. Shared style migration: `DesignSystem.swift` still uses blue/system grouped colors and radii 6–999. Historical implementation mapped LedgerPalette to TerminalPalette, used compact corners and plain ruled lists, and introduced `TerminalNativeChrome` in `TerminalDesignSystem.swift`. The helper is absent now.
2. Remaining-page migration: the historical pre-brand diff covered 30 source files, including import flow/history, local ledger import/editor, pending inbox, classification settings, onboarding, bookkeeping, account/category editing and details, reconciliation, event reports, transaction sharing, time picker and investment analysis. Current `NativeImportFlowView.swift` still lacks the native terminal chrome and retains explicit rounded cards. `TerminalInvestmentsReport` is absent.
3. Native tab bar: RootView still hides system tab bars and inserts `TerminalTabBar`; the delivered native-tab implementation removed that custom bar, supported scroll minimization and routed search through More.
4. Floating pagination capsule: TransactionViews still has `.background(.bar)` in pageNavigation; the delivered code used thin material, capsule border and floating spacing.
5. Refresh cancellation fix: `preservingOverviewCategories` is absent from LedgerSession, and OverviewView uses the earlier direct refresh action. The historical regression tests are absent too.
6. Receipt export crash fix: `isShareReceipt` and `TransactionReceiptRenderingTests` are absent. The standalone ShareAmountText type exists but the money-flow receipt path lacks the recovered explicit export mode.
7. Startup cache optimization: `cachedStartupPresentation` is absent. Historical code read bootstrap and overview in a single validated snapshot and reused the matching categories.
8. Widget/startup cache collision fix: LocalLedgerRepository still uses the shared `.bootstrap-page-presentation.json` path; historical `bootstrapPageCache(limit:)` isolated the widget limit-1 page from the app limit-100 page. Its regression test is absent.
9. Cold-start authentication coordination: `didStartSession` gate in LedgerMobileApp is absent. Historical implementation avoided the initial foreground callback starting a second automatic unlock while start owned cold authentication.
10. Associated UI/unit tests and safe screenshots were also local-only; recover alongside the corresponding implementation rather than relying on historical pass claims.

## Present / separately restored

- Terminal overview, initial reports, accounts and More foundation: in PR 498's committed base.
- Independent authentication/privacy switches: in PR 500, merge `c8b16b9`.
- Widget visual redesign: in PR 499, merge `ba52111`.
- Icon/launch resources and animation: recovered in PR 502 commit `8d69d15` only; this does not restore the wider page migration.
- Today's Dynamic Island changes: on the original branch at `97c3bc6`; the new brand Build 57 was built from the separate brand branch and DOES NOT include those commits or the three uncommitted fullscreen bookkeeping changes. It must not be described as an integrated replacement for that package.

## Recovery order and validation

1. Reconstruct the shared style + remaining-page delta from the historical commands on a separate source tree; preserve new bookkeeping work and already merged privacy/widgets.
2. Restore native navigation and pagination with their UI tests.
3. Restore receipt, refresh and startup/cache fixes in focused changes with their regression tests.
4. Integrate the brand branch and current bookkeeping/Island changes explicitly, then perform light/dark page screenshot review and synthetic ledger tests.
5. Build an IPA only from an identifiable committed integrated revision; use a version above prior delivered Build 59. List included PRs and verify packaged assets/signatures.

This audit ran source and historical-record comparisons only. No app code was changed, no current tests were run, and no new IPA or hosting service was created. The original temporary source tree no longer exists; historical edit bodies remain recoverable. Local checkpoint writes under Git metadata are unavailable in the current read-only Git sandbox; recovery evidence was extracted to temporary storage instead. This shared note is local-only and uncommitted.
