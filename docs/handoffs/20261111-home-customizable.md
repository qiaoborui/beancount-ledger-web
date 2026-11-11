# 20261111-home-customizable

- Status: completed (awaiting PR review)
- Last updated: 2026-11-11 15:00 (+08:00)
- Branch: `codex/home-customizable`, based on `main` at `bf1fcca3`

## Goal

Feature A of a two-part request: the iOS overview gains more stat sections, and the user chooses which sections show and in what order. Feature B (AI-native onboarding that reuses the on-device agent, with the manual wizard kept as a fallback) is a separate, later PR and has not started.

## Decisions

- New sections chosen by the user: 信用卡待还, 商户排行, 收入构成, 资产与负债, 币种分布. Net-worth trend was not chosen.
- The period stats grid gains 支出同比 and 收入同比 (calendar months only, like month-over-month).
- The hero and period cashflow merge into one 本期结余 section.
- Sections are rows on the page canvas, not cards (DESIGN.md). A section with no data for the period hides itself.
- The layout is one device preference shared by all ledgers (`ledger.mobile.overview-sections` in `UserDefaults`), following the compact-tab precedent: dedupe, drop unknown raw values, never empty. A saved layout never auto-adds future sections; they wait under 可添加.
- The editor opens from a toolbar button on the overview and from Settings → 首页模块.
- Data is decode-only: the server bootstrap already sends `creditCards` and `incomeStatement` in remote and local modes. Swift now decodes them with `decodeIfPresent`, so older servers simply hide those sections. No Go change.
- Merchants never fold and map the server's `（无商户）` to 未填商户. Income folds anything past five into 其他. Currency mix needs at least two asset currencies and names currencies without an exchange rate.
- Overdue cards use the new key `逾期 %lld 天`, because `已过 %lld 天` already means "N days so far".
- Feature PR only: `MARKETING_VERSION` and the build number are untouched. A release is still needed.

## Validation

- `App/LedgerMobile`: `swift test` passed (1022 tests, 26 skipped, 0 failures), using the full Xcode toolchain (`DEVELOPER_DIR` pointing at Xcode.app; the Command Line Tools toolchain crashes `swift test`).
- The iOS SDK cross-build (`swift build --triple arm64-apple-ios17.0`) succeeded.
- `xcodegen generate` plus the Xcode simulator build of the LedgerMobile scheme succeeded; this is the only build that compiles `OverviewView.swift`, `SettingsView.swift` and `SafePreviewLedgerAPI.swift`.
- Not tested: safe-preview screenshots (no simulator device was available), drag reordering, VoiceOver, app-host tests, and a real device.

## Next

1. Review and merge the PR; include it in the next iOS release.
2. Start Feature B on its own branch: an onboarding mode in `server/mobileagent` without an existing ledger, draft tools ported from the Python onboarding agent, an onboarding sheet that configures the model first, and creation through `createCustomLocalLedger`.
