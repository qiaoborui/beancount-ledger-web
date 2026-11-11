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
| Overview | Balance sheet, retention, period cashflow, monthly spending trend (6/12 months, average of ended months, month-end estimate, jump to a month), period stats (daily spending, transaction count, spending and income month-over-month, largest expense, net worth vs. last month-end), category spending | Read | `OverviewView.swift` |
| Transactions | List with infinite scroll, keyword/type/account/tag filters, detail, fast and advanced editing, duplicate, confirmed deletion, bulk tagging, selection share/export | Read and validated write | `TransactionViews.swift`, `LedgerSession` mutations |
| Accounts | Period closing net worth with a whole-ledger trend line and 1月 / 3月 / 6月 / 今年 / 1年 / 全部 windows, grouped balance cards with a category filter bar (全部/资金/信用/理财/应收), account detail with running history and trend, per-account reconciliation | Read and validated write | `AccountsView.swift` |
| Reconciliation | Balance review across accounts, per-account actual-balance entry, difference adjustment written as a validated transaction | Write with preview | `ReconciliationView.swift` |
| Ledger files | Browse `.bean` files under the ledger root, edit in a plain editor, validate the whole ledger, export a snapshot folder | Write with validation | `LocalLedgerFilesView`, `LocalLedgerFileEditor` |
| Settings and privacy | Face ID/Touch ID/passcode, lock interval, app language, compact tab customization, device-local storage settings | Device/auth | `SettingsView.swift`, `LocalLedgerAuthentication.swift` |
| Home Screen widgets | Weekly/monthly/yearly overview, expense calendar, 30-day trend, 12-week heatmap, configurable account balance, import recency, Lock Screen families, 快捷入口, 记一笔 quick record (two entry forms and today's spending); Balanced styling with tinted and clear Home Screen rendering | Read-only snapshot | `WidgetExtension/`, `LedgerWidgetSnapshot.swift` |
| Live Activity | Import index progress in two stages (written, indexed), with the same disc and hue as the in-app notice | Read-only | `ImportIndexLiveActivity.swift` |
| Save and import notice | In-app Dynamic Island card that grows from the camera after a save or a bill import: one entry shows payee, category and signed amount in the expense/income hue; several entries, a pasted `.bean` file or an import show a count. It then settles into a compact pill with the category symbol and a short amount, and retracts. VoiceOver announces it; Reduce Motion crossfades | Read-only feedback | `LedgerIslandEntryView.swift`, `LedgerIslandMotion.swift`, `BookkeepingPreviewView.swift` |
| Assets, income statement, investments | Net worth history and trend, hierarchical income/expense statements, holdings with market value, cost, and return | Read | `AnalysisViews.swift` |
| Currencies | Current, inverse, and CNY-cross rate cards with sparklines, missing-rate warnings, valuation currency per server origin | Read | `CurrencyAnalysisView.swift` |
| BQL | Multi-statement editor, examples, table/bar/pie/line results, device-local history | Read plus runtime history | `BQLQueryView.swift` |
| Global search | Search across transactions, accounts, tags, and files with filters | Read | `GlobalSearchView.swift` |
| Imports | File picker for CSV/XLSX/PDF/ZIP (including encrypted) and EML/HTML, shared-inbox files from the Share Extension, provider detection, duplicate review, per-entry and bulk tagging, confirmation, commit result, channel coverage, archive history. Parsing starts as soon as a file is picked; the review page opens on the entries that need a decision, and an unfinished review is kept as a per-ledger draft | Preview-confirmed write | `NativeImportFlowView.swift`, `ImportHistoryView.swift`, `ImportReviewQueue.swift` |
| Import classification (Jev) | Optional two-question account classification with a user-supplied TypeSafe key; suggestions require explicit acceptance | Network opt-in | `ImportClassification*.swift` |
| Natural-language bookkeeping | One-sentence drafts, edited and confirmed before writing. On-device Chinese rules read amounts (Chinese numerals, 块/毛, thousands separators), currencies, relative dates, several transactions per message, splits, transfers, refunds, income and debts, and match accounts by scored concepts against the ledger's own names; an OpenAI-compatible endpoint the user configures takes over when set, grounded by those readings, with the rules as fallback | Local; network opt-in for the endpoint | `NaturalLanguageBookkeepingView.swift`, `BookkeepingSettings.swift`, `LocalBookkeepingParser.swift`, `BookkeepingAccountMatcher.swift`, `BookkeepingTextAnalysis.swift` |
| Ledger assistant (账本助手) | Chat over the local ledger with a model and API key the user picks (Anthropic, OpenAI, Gemini, DeepSeek and others, or a custom compatible endpoint), run on device by the PiG agent loop in LedgerCore. It queries with BQL, search, summary and account tools, and edits through list/read/edit/write/move/delete file tools (any non-hidden file in the ledger folder; binary files can be moved or deleted, not edited) plus bean_check on a private draft copy; a change card shows the per-file diff and validation result, and only 写入账本 commits it through the shared prepare/validate/commit path. Statements can be attached to a conversation (CSV, Excel .xlsx/.xls, PDF, photos and screenshots), picked from Files, picked from the photo library, or dragged into the conversation from Photos, Files or another window: files are copied into runtime/agent-attachments, PDFs are read with PDFKit and scanned pages and images with on-device Vision OCR, the core parses tables, and reconcile_attachment matches statement rows against an account's postings to report missing, extra and amount-mismatched entries; save_attachment copies an attachment's original file into the ledger (for example documents/statements/); fixes and saved files still go through the draft and change card, which shows binary files by size. A conversation is named by the model after its first answer, through the same small no-tools request as suggestions and recaps; with that toggle off, the first question names it. Earlier conversations are readable: list_saved_conversations and read_saved_conversation cover the records in runtime/agent-history (current conversation excluded), so a question can refer back to what was decided before, while balances and entries are still re-read from the ledger. The history list puts pinned conversations first (pins survive the 200-conversation pruning), then groups the rest by today, yesterday, the past 7 days, this month and earlier; a conversation can be renamed (from the list or by tapping its title in the header; the user's name wins over the model's), pinned, shared as plain question/answer text (hidden while amounts are masked), deleted, and found by search over titles, questions and answers. Return on the software keyboard sends (a multi-line paste does not), Shift-Return adds a line on a hardware keyboard, unsent text stays with its conversation while the app runs, the view follows new content down until the reader scrolls up or opens a tool group or reasoning block (content growing past the bottom does not stop it; leaving the page at the bottom, 回到底部 or a new question resumes it), and VoiceOver announces a finished answer. A running turn streams: the reply appears as it is written (an unclosed code fence reads as prose until it closes), reasoning shows live and collapses to 思考了 N 秒, and tool calls sit under a collapsed summary line (the call still running shows beneath it) that opens to a row per call going from running to done or failed with its duration, each expanding to its arguments and the start of its result; the same timeline is saved with the answer and redrawn when the conversation is reopened (older saves show their tool list as before). Stop keeps the partial reply marked 已停止, and the next question continues from a transcript that includes it. A small ring beside the model chips shows how full the model's context is, with the token counts on tap. Each finished answer has 复制 (Markdown kept), 重新生成 and 分享 (hidden while amounts are masked) under it, and a long press on 复制 offers 复制为纯文本; answer and question text stays selectable; a code block has its own copy button. A pencil under a question is 编辑后重新发送, which puts the question in the composer under a 正在编辑第 N 个问题 banner. Regenerating or editing cuts the native transcript back to before the question (TruncateTranscriptJSON; the visible history is replayed when there is no transcript) and keeps the earlier answer or question as a version: a ‹ 2/3 › switch under the question or answer moves between versions, each with its own saved transcript, and the next question continues from the version shown. These wait while a turn runs or a change is on the card or being written; replacing answers that wrote to the ledger, or a stopped turn's unreviewed draft, asks first, and the draft is discarded, never written. Can be a compact tab | Read; preview-confirmed write; network to the chosen model | `LedgerAgent.swift`, `LedgerAgentAttachments.swift`, `LedgerAgentView.swift`, `LedgerAgentTimelineView.swift`, `LedgerAgentHistoryView.swift`, `LedgerAgentSessions.swift`, `LedgerAgentBranches.swift`, `LedgerAgentSettings.swift`, `server/mobileagent/` |
| Backup and restore | iCloud Drive (or any folder) snapshots with hash verification, restore into the current ledger or as a new one, daily automatic backup | Local read/write | `LocalLedgerBackup*.swift` |
| Git synchronization | HTTPS remote, branch, Keychain credentials, pull/validate/push, conflict review and resolution, automatic sync | Network | `GitLocalStorage.swift`, `LocalLedgerAutoSyncCoordinator.swift` |
| iCloud Drive folder sync | Third storage provider beside device-only and Git: a picked folder holds immutable content-addressed snapshots plus one head file per device; peers merge three-way and reuse the conflict review; no push, so peers are picked up on save, foreground, periodic or background sync, or 立即同步 | Local read/write over iCloud Drive | `FolderLocalStorage.swift`, `LocalLedgerStorageView.swift` |
| App Intents and URL routes | Open a page, search, `ledger://` deep links | Read | `LedgerAppIntents.swift`, `LedgerExternalRoute.swift` |

## Deliberately out of scope

| Area | Why |
| --- | --- |
| Remote server authentication | Production composition creates local repositories only |
| Gmail automation | `performGmailRequest` requires a `LedgerRemoteGmail` repository, which local storage never provides |
| Agent workspace | Hosted ledger automation is outside the local-only product; the on-device 账本助手 covers asking and editing within one ledger |
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
- BQL, Currencies, Imports, and Categories live in iPhone More and in the iPad
  sidebar.
- Whole-ledger search is a tab of its own, not a 更多 row. On iOS 26 it uses the
  tab bar's search role, which the system detaches into a floating button with
  the field at the bottom; earlier versions get a trailing 搜索 tab item.
- Financial writes keep the shared preview, canonical workspace validation,
  confirmation, and rollback boundaries. Nothing writes a ledger without
  canonical validation of the whole workspace.
