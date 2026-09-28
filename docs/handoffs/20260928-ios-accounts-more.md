# 20260928-ios-accounts-more

Status: completed. Updated: 2026-09-28T16:34+08:00.

## Goal and scope
Continue the approved compact terminal design on Accounts and More, with light/dark colors and a single date/sync header. Preserve filtering, account navigation, reconciliation, privacy and overflow routes. Account detail content, investment content and editing sheets are outside this increment.

Branch: `codex/ios-terminal-overview`. Code revision: `59f9bd9` (base `ca0fb84`). PR: https://github.com/qiaoborui/beancount-ledger-web/pull/498. Code, tests and safe screenshots are committed; this note accompanies the same PR update.

## Completed
- Accounts uses a ruled balance summary, flat filters and a contextual add/reconcile menu. Existing period balance calculations and row reconciliation actions are retained. Labels distinguish period end from current values; summary establishes currency.
- More uses compact numbered sections/rows and a header search shortcut. Existing overflow routing and navigation stacks remain.
- Both roots share the date/sync header. Local-only mode hides sync; configured Git icon opens storage details without initiating exchange.
- Restored Dynamic Type through terminalFont; accessibility layouts stack account metrics/groups, use three filter columns, and omit decorative More indices/icons. Toolbar glyphs remain compact with 44 pt targets.
- Moved account group identifiers to their labels to avoid overriding child account link identifiers. Removed the unused old hero card. Updated UI tests for custom root headers.

## Validation
Simulator build and five unique UI scenarios passed across targeted runs: account/More navigation (including add-sheet cancel, account expand/detail/back, privacy, report return and header search); accessibility XXXL reachability; native analysis back/cached reentry; overflow route persistence across tabs; local-only/configured Git status and details. Final source passed account/More navigation in light and dark, plus accessibility in dark. Safe 375 pt screenshots of both roots, expanded/hidden accounts and accessibility were exported and visually inspected under `docs/design/ios-terminal/`. Main simulator app was installed and launched with safe preview data.

Initial tests found group identifiers propagated into child rows and an offscreen storage switch assertion. Corrected the identifier placement and test scrolling. Visual inspection caught excess spacing, oversized accessibility icons and wrapped decorative indices; corrected. Architecture review found fixed text sizes; corrected and re-reviewed. `git diff --check` passed.

No private ledger used. Local sync test uses a UUID-isolated synthetic ledger and in-memory Git transport. No full-app sweep, iPad runtime, physical-device/signing or distribution acceptance. GitHub Gate passed on the previous head; Vercel web preview had failed before this increment. Check the updated head separately; native validation does not imply hosted web deployment success.

## Next step
This increment is complete. Continue account detail, investment content and editing sheets for remaining terminal styling. Do not merge without the user's instruction; inspect current PR checks before any merge.
