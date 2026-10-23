# iOS and mobile web feature coverage

This file records what the native app actually implements. Keep it aligned with
the code, not with a plan: every row states the current behaviour and points at
the source of truth. When a shipped feature changes, update this file in the
same change.

The production app is **local-only** (`docs/ios-local-first-ledger.md`). Hosted
features — remote authentication, Gmail automation, the agent workspace, web
push — stay out of scope by design, not as pending work.

## Product areas

| Product area | Native status | Access | Source of truth |
| --- | --- | --- | --- |
| Library and local ledgers | Create, import a folder, add an HTTPS Git repository, restore a `.ledgerbackup`, switch, rename, delete | Local write | `LocalLedgerViews.swift`, `LedgerLibraryView` |
| Overview | Balance sheet, retention, period cashflow, category spending, recent transactions | Read | `OverviewView.swift` |
| Transactions | List with infinite scroll, keyword/type/account/tag filters, detail, fast and advanced editing, duplicate, confirmed deletion, bulk tagging, selection share/export | Read and validated write | `TransactionViews.swift`, `LedgerSession` mutations |
| Accounts | Grouped balances with a category filter bar (全部/资金/信用/理财/应收), account detail with running history and trend, per-account reconciliation | Read and validated write | `AccountsView.swift` |
| Reconciliation | Balance review across accounts, per-account actual-balance entry, difference adjustment written as a validated transaction | Write with preview | `ReconciliationView.swift` |
| Ledger files | Browse `.bean` files under the ledger root, edit in a plain editor, validate the whole ledger, export a snapshot folder | Write with validation | `LocalLedgerFilesView`, `LocalLedgerFileEditor` |
| Settings and privacy | Face ID/Touch ID/passcode, lock interval, app language, compact tab customization, device-local storage settings | Device/auth | `SettingsView.swift`, `LocalLedgerAuthentication.swift` |
| Home Screen widgets | Weekly/monthly/yearly overview, expense calendar, 30-day trend, 12-week heatmap, configurable account balance, import recency, Lock Screen families | Read-only snapshot | `WidgetExtension/`, `LedgerWidgetSnapshot.swift` |
| Live Activity | Import index progress | Read-only | `ImportIndexLiveActivity.swift` |
| Assets, income statement, investments | Net worth history and trend, hierarchical income/expense statements, holdings with market value, cost, and return | Read | `AnalysisViews.swift` |
| Currencies | Current, inverse, and CNY-cross rate cards with sparklines, missing-rate warnings, valuation currency per server origin | Read | `CurrencyAnalysisView.swift` |
| BQL | Multi-statement editor, examples, table/bar/pie/line results, device-local history | Read plus runtime history | `BQLQueryView.swift` |
| Global search | Search across transactions, accounts, tags, and files with filters | Read | `GlobalSearchView.swift` |
| Imports | File picker for CSV/XLSX/PDF/ZIP (including encrypted) and EML/HTML, shared-inbox files from the Share Extension, provider detection, duplicate review, per-entry and bulk tagging, confirmation, commit result, channel coverage, archive history | Preview-confirmed write | `NativeImportFlowView.swift`, `ImportHistoryView.swift` |
| Import classification (Jev) | Optional two-question account classification with a user-supplied TypeSafe key; suggestions require explicit acceptance | Network opt-in | `ImportClassification*.swift` |
| Natural-language bookkeeping | One-sentence drafts through an OpenAI-compatible endpoint the user configures, edited and confirmed before writing | Network opt-in | `NaturalLanguageBookkeepingView.swift`, `BookkeepingSettings.swift` |
| Backup and restore | iCloud Drive (or any folder) snapshots with hash verification, restore into the current ledger or as a new one, daily automatic backup | Local read/write | `LocalLedgerBackup*.swift` |
| Git synchronization | HTTPS remote, branch, Keychain credentials, pull/validate/push, conflict review and resolution, automatic sync | Network | `GitLocalStorage.swift`, `LocalLedgerAutoSyncCoordinator.swift` |
| iCloud Drive folder sync | Third storage provider beside device-only and Git: a picked folder holds immutable content-addressed snapshots plus one head file per device; peers merge three-way and reuse the conflict review; no push, so peers are picked up on save, foreground, periodic or background sync, or 立即同步 | Local read/write over iCloud Drive | `FolderLocalStorage.swift`, `LocalLedgerStorageView.swift` |
| App Intents and URL routes | Open a page, search, `ledger://` deep links, Dynamic Island entry notice | Read | `LedgerAppIntents.swift`, `LedgerExternalRoute.swift` |

## Deliberately out of scope

| Area | Why |
| --- | --- |
| Remote server authentication | Production composition creates local repositories only |
| Gmail automation | `performGmailRequest` requires a `LedgerRemoteGmail` repository, which local storage never provides |
| Agent workspace | Hosted ledger automation is outside the local-only product |
| Web push notifications | The local app has no push service |
| Passkey login | Needs a paid Apple Developer team and associated domains |
| S3 storage provider | Not planned; iCloud Drive backups cover the need |

## Known gaps

These are real, verified against the code, and intentionally not presented as
finished:

- The Accounts list has **no keyword search**; it offers only the category
  filter bar. `DESIGN.md` describes a search field with separate expansion
  state, and that design is not implemented yet.
- `DESIGN.md` says accounts have "no category segmented picker". The shipped
  screen has the filter bar described above. `DESIGN.md` needs a decision:
  either the filter bar is the intended design and the sentence is stale, or
  the filter bar is unplanned work.
- Opening a ledger that uses an unlisted plugin or an external path fails with a
  compatibility error and cannot be opened read-only. This is the one item
  `docs/ios-local-first-ledger.md` still calls future work.
- App-host tests (SwiftUI rendering, bundled resources, Keychain) and the UI
  suite run through the Xcode scheme, not in CI. CI runs `swift test` and an
  iOS SDK cross-build only.

## Navigation

- iPhone defaults to Overview, Transactions, Accounts, and More. Up to four
  destinations are user-selectable and reorderable; More stays fixed.
- iPad uses `NavigationSplitView`; the sidebar lists every destination and keeps
  its visibility across selection changes.
- BQL, Currencies, Imports, Categories, and Search live in iPhone More and in
  the iPad sidebar.
- Financial writes keep the shared preview, canonical workspace validation,
  confirmation, and rollback boundaries. Nothing writes a ledger without
  canonical validation of the whole workspace.
