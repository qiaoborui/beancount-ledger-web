# 20261013-ios-balanced-conformance

- Status: completed (merged with PR #506; follow-ups listed under Remaining work stay open)
- Last updated: 2026-10-14 12:10 +0800
- Branch: `codex/ios-balanced-conformance` (from `main` @ `b6ca236`)
- Code revision covered: the branch tip that contains this note (first
  commit on top of `b6ca236`; pushed to origin). Overview, transactions and
  income/expense follow design batch 1; `docs/design/ios-balanced/` (batch 2)
  and batch 1 are committed under `docs/design/ios-balanced/` and
  `docs/design/ios-balanced/batch1/`.
- PR: https://github.com/qiaoborui/beancount-ledger-web/pull/506

## Goal and acceptance

Make every iOS page conform strictly to the Balanced design in
`docs/design/ios-balanced/` (README.md = spec, styles.css = exact values,
index.html = 20 reference frames d01–d20 + dark d21–d23). Fonts, weights,
colours, sizes and layout must match, verified by simulator screenshots
against the rendered frames. Pages without a frame follow the same rules.

Working model: the lead session audits and writes fix lists; Sonnet sub-agents
implement. Keep changes presentation-only unless a fix corrects
UI text/content that misdescribes real behaviour.

## Approved decisions

1. **Bundle IBM Plex** — done. `App/LedgerMobile/Resources/Fonts/` (Plex Sans
   Regular / Text(450) / Medium / SemiBold, Plex Mono Regular / Medium, OFL
   texts), registered via `UIAppFonts` in `project.yml`. PostScript names:
   `IBMPlexSans`, `IBMPlexSans-Text`, `IBMPlexSans-Medm`, `IBMPlexSans-SmBld`,
   `IBMPlexMono`, `IBMPlexMono-Medm`. Helpers `balancedFont(size:weight:)`
   (`.regular/.text/.medium/.semibold`) and `balancedMono(...)` use
   `Font.custom(_:size:relativeTo:)` so Dynamic Type still scales. CJK falls
   back to PingFang. Widget target fonts NOT bundled yet.
2. **Keep native Liquid Glass controls** — native TabView tab bar, system
   sheet toolbar buttons (完成/取消/关闭 capsules) and `.searchable` /
   `.searchScopes` stay native; only tint changed to ink.
3. Keep existing copy where it differs from the mockup (e.g. 新建本地账本,
   本地文件) and keep richer existing structure (AddCategoryView presets +
   advanced path editor). Privacy masking (•••••• in onboarding summary) is
   existing behaviour — keep.
4. Pending inbox keeps title 待整理账单 and 关闭, and the inline payee pencil,
   because existing UI tests assert them.
5. Design docs (batch 2 and batch 1) are committed under
   `docs/design/ios-balanced/` with this PR.
6. **Pushed-page titles stay centred** (user decision, 2026-10-14), even
   though batch 1 draws them left-aligned. Root tab pages keep the left title.

## Foundation (done)

- `BalancedDesignSystem.swift`: palette incl. `ruleStrong`, `edge`;
  `BalancedAmount` (Plex Text 450, tabular, optional `currencyScale` for the
  0.78em ink-3 ¥); `BalancedKeyRow` / `BalancedKeyTotalText` (`.key`,
  `.key--total` 21/500, ¥ 0.62em; sign full size); `BalancedSectionLabel`,
  `BalancedMark`, `BalancedTag`, `BalancedButtonStyle` (outline / primary /
  quiet / risk, 48 min, radius 3, disabled 0.38), `balancedSettle()` and quiet
  variant, `BalancedBand`, `BalancedToggleStyle`, `BalancedEmptyState`.
- `TerminalDesignSystem.swift`: `TerminalPalette` aliases `BalancedPalette`
  (no accent colour); `TerminalAmount` → Plex tabular; `TerminalSectionLabel` →
  12.5/500/ink-3, unnumbered; `TerminalPageChrome` Balanced-only, title 17/500,
  20pt gutter, sync button = icon + state dot.
- `DesignSystem.swift`: card modifiers flattened; `LedgerRadius` → 0
  (legacy call sites; Balanced controls hardcode 3/2).

## Page status

Verified by screenshot (accepted by lead):
- Overview, Transactions list, Accounts, More (P1).
- d01 library, d02–d04 onboarding (+ d21 dark), d07 categories, d08 add
  category, d13 storage, d15 settings, d16 lock, d19 local files.
- d11 reconciliation list, d12 single reconcile (+ d22 dark).
- d05 search initial state, d20-style event tag list (EventTagViews).
- Transaction detail, create/edit + keypad (expense/income/transfer), share.

Correctness fixes made during the work (keep):
- Single reconcile helper text now names the real adjustment account; the
  preview's adjustment account mirrors `server/internal/app/reconciliation.go`
  (`group == "wealth"`). Writes don't consume the preview value.
- Pending 补分类 sheet no longer shows invented "suggested" categories — only
  the current category + 选择其它分类….
- Single reconcile actual-balance field no longer seeds from a stale 0
  (`.id(account-ledgerBalance)` at call sites).
- Library page title was missing (native large title didn't render) → uses
  `terminalPageChrome`.

## Review items 1–8 — closed by the pi task-1 pass

Full per-item evidence is in the task's local report
(`pi-report-1.md`, kept outside the repo). Summary of what is now true:

1. **d09 pending row / pagination — fixed.** The trailing pencil button was
   pushing the amount 44pt off the page edge (measured 336.7pt vs the frame's
   371pt). The pencil now sits inline after the payee, so the amount is flush
   right (payee band 40.7–379.3pt, meta band 41.0–380.7pt). The amount column
   is `minWidth: 78` + `fixedSize(horizontal:)` instead of a hard 78pt, so it
   does not clip at larger Dynamic Type; verified at `extra-large`. Pagination
   was already docked under the list via `safeAreaInset(edge: .bottom)` and
   sits adjacent to 逐条整理.
2. **Stray blue glyph — fixed, root cause identified.** It was the `#if DEBUG`
   simulator overlay in `RootView`, for two reasons: the overlay is applied
   *outside* the `.tint(BalancedPalette.ink)` chain (so the buttons drew in the
   system accent), and its labels had no frame (so they drew outside their own
   hit box and showed through a presented sheet's rounded corner at the 20pt
   gutter). Both buttons now use a clear label inside an explicit 44×44 frame
   with their own ink tint. Pixel scan of all captures: 146 blue pixels → 0.
3. **Dark captures — fixed.** The environment variable must be exported
   *before* `xcodebuild` starts; setting the simulator appearance after launch
   has no effect. Measured dark page `#131211` against `--bg: #121110`, amount
   `#CF7A52` against the dark `--out`. Authoritative dark set is
   the dark capture set (29 files). A later light run reused the same
   `*-dark.png` filenames, so those later files are light — use the dark run's
   own output directory, not the newest one.
4. **d06 search rows — fixed.** Added the `.txn .lede` 34pt `MM-DD` gutter and
   hid the `NavigationLink` chevron. Account, tag and document sections already
   matched.
5. **Centered pushed titles — already correct.** Title-glyph centres measured
   against the frames: d11 197.0/197.0, d12 192.0/192.0, d15 192.0/192.0,
   d19 197.5/197.5 (app/frame). `TerminalPageChrome`'s `!isRoot` ZStack already
   does this; the earlier "left next to the chevron" note was stale.
6. **Filled symbols → outline — fixed.** Keypad category grid confirmed
   outline. Also swept `LedgerAccountPicker` (dropped the tinted icon tile and
   `checkmark.circle.fill`), `NaturalLanguageBookkeepingView` (dropped tinted
   prompt tiles, `arrow.up.forward.circle.fill`, `pencil.circle.fill`,
   `lightbulb.max.fill`, `xmark.circle.fill`, the confirm bar's shield/circle
   fills). Share-receipt flow icons left as-is — they are inside the generated
   share image, not app chrome.
7. **U+2212 — fixed.** `AccountsView` liability prefix, the keypad operator
   label and the keypad hero display text now use `−`; the calculator's own
   expression and the reconciliation source preview keep ASCII `-` because they
   must stay byte-identical to what is parsed/written.
8. **用一句话记账 as `.link` — already correct.** Underlined `secondary` text,
   no border, at both call sites.

## P3 completed in the pi task-1 pass

- `NaturalLanguageBookkeepingView` — full Balanced restyle (band lead, `.field`
  input with an ink primary action, `.row` inspiration list, `.note` AI notice,
  receipt card as `.key`/`.acct`/`.mark`, text 出/入 split legs, hairline
  confirm bar, `.field` sheets).
- `TimeRangePicker` — month/quarter/year grids moved from filled accent blocks
  to the shared 2px `.mark` underline; custom presets to `.seg-inline`.
- `CookieFastTransactionEditorBody` inner date sheet — `.seg-inline` quick-date
  chips, DatePicker panel card removed.
- `TransactionTagEditorSheet` — restyled toward the d20 look (note, batch row,
  typed tags as rows, 新建标签 field, quiet/primary footer). Restyle only: the
  frame's per-tag counts need a data source this sheet does not have.
- `LedgerAccountPicker` — `.row`/`.acct` treatment, `.tag` for 已停用.

`TimeRangePicker`, the editor's inner sheets, `TransactionTagEditorSheet` and
`LedgerAccountPicker` are **build-verified only** — no capture test drives them.

## Validation

### pi task-1 checkpoint

- No commits, pushes, branch switches, stashes, reverts or checkouts. All prior
  Balanced edits remain uncommitted/local-only. Unrelated worktree changes
  preserved.
- Screenshot capture works when `TEST_RUNNER_BALANCED_SCREENSHOT_DIR` is an
  **environment** variable of the `xcodebuild` process. Both `save()` helpers
  also now create the output directory first; without that, a fresh directory
  fails all 13 tests with `NSCocoaErrorDomain Code=4` (a missing directory, not
  an app regression).
- Latest light run: `BalancedScreenshotTests` + `BalancedStreamAScreenshotTests`,
  **14 tests, 0 failures**, 31 PNGs. Dark run: **14 tests, 0 failures**, 29 PNGs
  in the dark set. Light and dark suites both re-run repeatedly during the pass.
- `xcodebuild build -scheme LedgerMobile` on the current worktree: **succeeded**.
  Three pre-existing warnings unrelated to this work: unused `visual` in
  `NaturalLanguageBookkeepingView.swift`, unused result in
  `ReconciliationView.swift`, unused `primaryCategory` in `LedgerModels.swift`.
- Every review item was checked against its frame by opening the PNG, and
  several were additionally measured by pixel scan (title centres, amount
  right edges, the blue-pixel count, dark page colour). Where a claim could not
  be verified visually it is marked as build-verified only above.
- The five known-failing assertion tests were **not** re-run; they fail on
  clean `main` too. No claim is made about them.
- `accessibility-*` Dynamic Type sizes are unverified for the pending row —
  the capture test cannot complete at `accessibility-medium` because the
  editor's posting-amount field scrolls out of reach (fixture limitation).
  `extra-large` is verified and does not clip.
- The capture simulator was left at appearance **light**, content size
  **large**. Device identifier and output directories are in the local
  checkpoint.
- Two device IPAs were built and handed to the user during this task (ad-hoc
  signed, SideStore): one after items 1 + 2, one after items 1 + 2 + 4 + 7.
  Neither includes the P3 restyles. Build details are in the local checkpoint.
- No physical device verification performed.

## Remaining work

- **Not screenshot-verified:** `TimeRangePicker`, the editor's inner
  account/date/split sheets, `TransactionTagEditorSheet`, `LedgerAccountPicker`.
- **P3 not started:** analysis (`AnalysisViews.swift`,
  `TerminalAnalysisViews.swift` — numbered heads, chart series colours), import
  flow + history (`NativeImportFlowView.swift`, `ImportHistoryView.swift`), BQL,
  currency analysis, `AddAccountView`, `InstitutionPickerSheet`,
  `ImportClassificationSettings`, `BookkeepingSettingsView`, CompactTab config.
- **P4:** island pill (`LedgerIslandEntryView.swift`), widget (bundle Plex in
  the widget target), launch/splash vs `splash.html`.
- **Final:** full dark pass (d21–d23), update `App/LedgerMobile/DESIGN.md`
  (it still describes the old cobalt/system-font language), test + build,
  commit, PR. `docs/design/ios-balanced/` still needs the user's decision on
  whether it ships with the PR.
- Known cosmetic difference: d06 tag rows render the system
  `Label(systemImage: "number")` as a separate `#` glyph followed by the tag
  word; the frame shows `#装修` as one run. Changing it would alter the
  accessibility label.

## Lead review of the pi pass (2026-10-13, after pi stopped)

Spot-checked light/dark screenshots of d09, d06, create-transaction and the
natural-language page; the pi report's claims hold for items 1-8. Build
succeeds on the current worktree. Remaining nits found in review:
- Natural-language page: the 快捷灵感示例 rows still show colour emoji
  glyphs - chroma outside in/out direction. Replace with plain text or an
  ink outline glyph.
- d09 pending row text starts at ~x=42 while the day separator and band sit
  on the 20pt column; the empty leading time gutter is still there. Align
  payee/meta to the column when there is no time.
- d06 search: a second rule appears under the last transaction row (row
  rule + section/footer rule). Keep exactly one.

## Design batch 1 found (2026-10-13 evening)

The untracked `docs/design/ios-balanced/` is the batch-2 document (20 frames:
library, search, reconcile, settings, system surfaces). The original batch-1
frames for the main tabs live in commit `cc78ae3` ("feat: new design", branch
`codex/ios-balanced-home`): 概览, 流水, 收支分析, 资产分析, 账户, 更多, 同步详情,
日期选择, 记一笔, 导入复核, empty / validation-failed / missing-price states
(19 frames, light + dark). Main-tab pages must follow batch 1, not the
batch-2 rules inferred earlier.

- 概览 rebuilt to batch 1 and screenshot-verified light + dark: full-bleed
  sunken `.settle` blocks, rows without currency symbol in ink (liabilities
  ink with −), totals 30/500 with a single 1px ink rule above (¥ 0.62em
  ink-3 only on 净值), retention band with square legend keys and small %,
  期初净资产 from the last net-worth history point before the period (row
  omitted when absent), 支出分类 table, 最近流水 grouped by day with
  expense amounts in ink and income in `--in`.
- Next: re-check 账户 / 更多 / 资产分析 / 记一笔 / 导入 / 日期选择 against
  batch 1 (render `docs/design/ios-balanced/batch1/index.html`). Notably
  batch 1 draws expense amounts in ink, not `--out`.
- 流水 rebuilt to batch 1 (b03/b04) and screenshot-verified light (全部) +
  dark (收入筛选): `.seg` tabs now natural-width/left-aligned with a 22px gap
  and 600-weight selection (not stretched full-width); search field is flat
  (no 3px radius — `.search` has none in styles.css); `.daysep` draws the
  date/weekday + per-day kind summary inline with a trailing rule that grows
  to the edge (was a separate rule under the row), and the per-day summary is
  suppressed once a kind filter is active; row amounts (`BalancedLedgerTransactionRow`)
  carry no currency symbol, are 15.5/500, and only income is coloured (expense
  and transfers are ink with the sign carrying meaning — previously expense
  was wrongly coloured `--out`); transfer account paths use Plex Mono 11.5
  ink-3 instead of system mono. Added `BalancedTransactionFilterSettle` (the
  `.settle` filter-result block from b04): shown once `filters.kind != .all`,
  rows grouped by leaf category in ink, a single coloured total matching the
  active kind. Footnote text switches between "本页 N 笔已全部加载…" (全部) and
  "筛选只作用于当前区间，其余账目未被隐藏。" (filtered), matching b03/b04 literally.
  Files: `App/LedgerMobile/Sources/TransactionViews.swift`.
- 收支分析 rebuilt to batch 1 (b05/b06) and screenshot-verified light + dark:
  `TerminalIncomeExpenseReport` in `TerminalAnalysisViews.swift` replaced the
  old numbered-section terminal layout with the `.metrics` 2×2 KPI grid
  (收入/支出/净结余 green/日均支出, with real day-count from `dashboard.start/end`),
  a 月度收支 bar chart (ink income / `--out` expense bars, 万-unit axis, legend
  squares, "按月汇总 · 转账不计收支", a 查看数据 disclosure), a 净结余趋势 line
  chart, `.tbl`-style tables for 支出构成 (with a sunken 合计 row), 支出商户 and
  资金来源, and 异常与提示 using the real flagged-transaction rows from
  `dashboard.anomalies` (not inventing prose like "本月支出低于前三月均值 62%" —
  the API has no backing stat for that sentence, so the row shows the actual
  anomalous transaction + date + amount instead). 收入来源 (income by deposit
  account) is omitted: the API only exposes income by category account
  (`topPaymentAccounts` is expense-funding only, no income equivalent) — flagged
  rather than approximated. Existing functionality not in the b05/b06 mock
  (支出/收入 category toggle, 事件与项目, 账户明细) was kept, reskinned onto the
  same `.sechead`/`.tbl` idiom rather than dropped. Report content breaks out
  of `LedgerAnalysisView`'s 20pt compact-width padding (`.padding(.horizontal,
  horizontalSizeClass == .regular ? 0 : -20)`) so `.sechead`/`.tbl` rules run
  full-bleed edge to edge as batch 1 requires.
  Files: `App/LedgerMobile/Sources/TerminalAnalysisViews.swift`.
- New screenshot coverage: `testCaptureTransactionsIncomeFilter` (b04) and
  `testCaptureIncomeExpenseAnalysis` (b05/b06) in
  `App/LedgerMobile/UITests/BalancedScreenshotTests.swift`.

- 资产分析 rebuilt to batch 1 (b07 light, b08 dark · 金额已隐藏) and
  screenshot-verified both: `.settle` (资产/负债/净值, 净值 always ink — not an
  opposed income/expense pair, so never colored; 负债 also kept ink with a
  sign, following the established 概览 precedent rather than the stray
  `v-out` in the b07 HTML), a `.band` composition bar whose segments are
  real proportions by account group (`LedgerAccount.group`: wealth/cash/
  receivable, folded "credit"+"liability" into one 信用 bucket for the
  账户组变动 table), a 净值走势 line chart, and an 账户组变动 3-column table
  (期末/变动, from `AccountBalance.periodValuationChange`). Masked state
  (b08) follows the HTML literally — composition bar and chart line/points
  stay visible in shape (recoloured to ink-3, axis labels dropped) while
  every number becomes `••••••`; the b08 copy ("走势保留形状，刻度和末值一并
  隐藏…") is shown verbatim. 收入来源-equivalent 月末/每日 toggle (existing
  feature, no b07/b08 equivalent) kept inline in the 净值走势 sechead.
  File: `App/LedgerMobile/Sources/TerminalAnalysisViews.swift`
  (`TerminalAssetsReport`).
- 账单导入复核 review step rebuilt to batch 1 (b15 light · 部分条目勾选, b16
  dark · 无勾选) and screenshot-verified both. `ImportEntryReviewRow` → `.imp`
  (flat 18×18 checkbox box, not a filled circle; who/meta/cat stacked left,
  amount right, no currency symbol; excluded rows dim to ink-3 instead of a
  status colour; a missing category/funding account reads as plain ink-3
  prose — "未选择账户" — instead of the old risk-red flag, since batch 1 has
  no status colours). `previewSummary` → the `.settle` block (已勾选 N/M,
  勾选金额合计, 重复或被排除, 将写入), with the existing channel/range,
  AI-classification-status and warnings detail kept below it, reskinned to
  ink tones (no more cobalt-accent card). `commitBar` → `.sheet-actions`:
  left `.btn` reads 全部勾选 when nothing is checked yet or 全部展开 once
  something is (matching b16 vs b15 — `expanded` was lifted from each row's
  local `@State` to a parent `Set<String>` so "expand all" has something to
  drive), right `.btn.primary` is the write action. Deliberate deviation:
  the write button disables only while committing, not while the selection
  is empty — b16 shows `aria-disabled` at 0 selected, but the app's real
  write path treats 0-selected as a valid action ("仅归档原始账单", archive
  the file with no transactions), so mirroring the mock's disabled state
  would break existing functionality the task said to keep.
  File: `App/LedgerMobile/Sources/NativeImportFlowView.swift`.
  **Not done** (time-boxed out of this pass): `ImportHistoryView`'s entry/
  history list and the first-step file-picker screen in
  `NativeImportFlowView.swift` are still the old `LedgerPalette`/system-List
  styling — the task asked for these to be reskinned too ("no frame — apply
  batch-1 rules") but only the graded b15/b16 review step was reached.
- New screenshot coverage: `testCaptureAssetsAnalysis` (b07/b08) and
  `testCaptureImportReview` (b15/b16) in
  `App/LedgerMobile/UITests/BalancedScreenshotTests.swift`.

- NativeImportFlowView first step (file picker) and ImportHistoryView entry/
  history list restyled to batch 1 (no design frame — applied the rules
  directly): full-bleed `.field-row`/`.row` idiom, `TerminalSectionLabel`
  section heads, `BalancedToggleStyle`, `.balanced(.primary)` buttons, flat
  dot-leader `FormatBadge` instead of filled pill chips, plain ink rows for
  channel coverage and archive history (the one exception: the channel
  freshness dot keeps colour, same documented exception as the sync
  indicator's dot — never a filled pill behind it, just a dot + ink label).
  Screenshot-verified light + dark (dark captured with `simctl ui … dark`
  set *before* launch, per the earlier b08/b16 mistake — those two are now
  correctly dark, not light-with-masked-amounts).
  Files: `App/LedgerMobile/Sources/NativeImportFlowView.swift`
  (`preparationView`), `App/LedgerMobile/Sources/ImportHistoryView.swift`.
- **Flagged, not changed**: asked to drop the b15 row's pencil glyph "if the
  row itself already opens the editor." Checked — it doesn't: the row tap
  toggles inline expand (reveals category/funding/postings/tags), a
  *separate* pencil opens the real edit sheet. Three existing UI tests
  (`LedgerMobileUITests.swift`: `testImportPreviewFinalRowStaysAboveCommitSurface`,
  `testNativeImportPreviewSelectionAndCommitFlow`,
  `testImportClassification…`) tap `import-entry-edit-<id>` directly without
  expanding first, and a fourth taps the row to reveal
  `import-entry-tag-toggle-<id>` inside the expanded state — so the two
  actions are load-bearing and distinct, and merging/dropping the pencil
  would break those tests, conflicting with "keep accessibility ids and the
  write path unchanged." Left the row as-is pending clarification.

## Next concrete action

Continue P3 in the handoff order: analysis views first (`AnalysisViews.swift`,
`TerminalAnalysisViews.swift`), then import flow + history, then BQL and
currency analysis, then the remaining settings views. Screenshot-verify each by
adding a capture test (no existing test drives those screens). Keep changes
presentation-only, and re-run both screenshot suites plus `xcodebuild build`
before the next handoff.

## Final pass before merge (2026-10-14)

- Import entry (file picker) and ImportHistoryView restyled to batch-1 rules;
  dark b08/b16 recaptured with the simulator actually in dark appearance.
- Import review keeps the per-row pencil: row tap toggles inline expand, the
  pencil opens the editor, and existing UI tests depend on both.
- Pushed-page bar now uses a collision-aware layout: the title stays centred
  but never sits under the back button or trailing controls (fixes the account
  detail title overlapping the date range button). Debug-only launch argument
  `--open-account-detail` opens that page for screenshots.
