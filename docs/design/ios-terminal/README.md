# Native terminal design

The approved visual reference is the terminal variant. This first native increment covers reusable visual primitives and overview; other screens retain their current implementation.

| Token | Light | Dark |
| --- | --- | --- |
| Page | `#F5F6F4` | `#181D21` |
| Panel | `#E9EDE8` | `#222A30` |
| Text | `#202B2E` | `#E1E7E6` |
| Secondary | `#536266` | `#A2AFAF` |
| Rule | `#CBD3CF` | `#354047` |
| Accent | `#855300` | `#E5B55F` |

System Chinese typography with monospaced amounts, 16 pt outer spacing, 4 pt corners, thin separators, no content shadows or gradients. Native text scaling and privacy masking remain functional.

Overview hierarchy: one navigation row (title, compact date, optional sync icon), net balance and income/expense, spending matrix, recent transactions. The date sheet edits a draft; cancel does not change the active range. No duplicate period row or quick-entry dock.

Local-only ledgers have no sync icon. Configured Git ledgers show their actual repository state; tapping the icon opens storage details and does not immediately sync. Counts/timestamps from the prototype are not fabricated. Server mode retains an explicitly labeled refresh action.

Amounts and derived proportions obey the existing visibility setting. Category aggregation uses the full local period aggregate, not just the loaded transaction page. Transactions and manual write confirmation continue through existing native views.

Simulator screenshots are stored alongside this document after verification and use safe synthetic preview data only.

## Simulator evidence

All images use the safe synthetic preview fixture on an iPhone 13 mini (375 pt). Its refresh icon belongs to server preview mode. The Git status/details and local-only hidden state are separately exercised by `LocalSyncToolbarUITests` against an isolated local ledger.

| Light | Dark |
| --- | --- |
| ![Light overview](overview-light.png) | ![Dark overview](overview-dark.png) |

Additional checks: [largest accessibility type](overview-accessibility.png), [amounts hidden](overview-private.png), [date sheet](date-sheet-dark.png).

Validation uses Xcode simulator builds, `LedgerModelsTests`, `LocalSyncPresentationTests`, the two date-session tests, `TerminalOverviewUITests`, and `LocalSyncToolbarUITests`. The overview checks exercise draft cancel/apply, native detail return, 44 pt date targets, accessibility reachability, and privacy masking including percentages. No physical-device, signing, or IPA distribution acceptance is implied.

The existing app tab bar and other pages are deliberately outside this increment. Shared date controls use native sheets and pickers with terminal colors; all accounting calculations and transaction confirmation flows continue through the existing models and views.
