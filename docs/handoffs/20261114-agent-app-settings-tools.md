# 20261114-agent-app-settings-tools

- Status: active (draft PR open, waiting for CI `Gate`)
- Last updated: 2026-11-14 (+08:00)
- Branch: `codex/agent-app-settings-tools`, based on `main` at `8ef3888b`
- Task B of the AI-native assistant batch (see
  `00-common.md` and `B-app-settings-tools.md` in the coordinator's local
  `agent-handoffs/20261114-ai-native/` directory)

## Goal

Let the on-device 账本助手 read and change the app's own settings, which live
in `UserDefaults` and not in the ledger, so the file tools cannot reach them:
首页分区与顺序, 底部标签, 估值币种, 记账与导入提醒, 周报 / 月报. The result of a
change must be exactly what the settings screens produce, including their side
effects, and must be undoable from the chat.

## Decisions

- **Wire format is the contract.** The shell sends one snapshot per ordinary
  turn in `appSettings`; the native side validates partial updates and returns
  the snapshot after the turn plus `changedSections`. Values are the raw ids the
  app stores (`retention`, `spendingCategories`, `weekdays`, …), so a renamed
  title never breaks a saved conversation. Both halves must be edited together:
  `App/LedgerMobile/Sources/LedgerAgentAppSettings.swift` and
  `server/mobileagent/app_settings.go`. Each side has a test holding the same
  literal JSON.
- **Domains covered**: `overview`, `tabs`, `valuation`, `reminders`, `reports`.
  Deliberately left out, and documented in the tool description and prompt:
  credentials and API keys (Keychain), the privacy lock and lock interval, the
  assistant's own model choice (task A rewrites that page), and 导入分类 —
  enabling it needs a key and a consent sheet ("同意并启用") before anything is
  sent to a third-party classifier, so the assistant must not flip it. There is
  no 一句话记账 switch in the app to include.
- **Partial updates, whole-snapshot validation.** Every section and field of an
  update is optional; the update is merged into the snapshot and the resulting
  snapshot is validated, so a value that only makes sense together with another
  (a monthly reminder without a day) cannot slip in. Unknown sections and
  unknown fields are refused with a Chinese message naming what is allowed.
- **Derived values are normalized before comparing**, so a no-op update reports
  "设置没有变化" and returns no change: `days` follows `repeat` unless it is
  `custom` (then it is sorted), and an unchanged report section list is equal to
  the snapshot's.
- **`day: -1` means the month's last day** in both the import reminder and the
  monthly report, matching `LedgerReminderMonthDay.last`; days 1–28 are the only
  fixed ones, which every month has.
- **Report sections must be listed in full** (all six, in display order, with
  `visible`), because the app stores them as an ordered preference list and a
  partial list would silently reorder the report.
- **A snapshot this build cannot read does not fail the turn**: the settings
  tools and their prompt are simply left out, so a schema drift costs the
  ability to change settings for that turn, not the answer.
- **Only an answered turn applies.** The response carries `appSettings` only on
  success, so a failed or stopped turn changes nothing. Applied sections are
  recorded on the answer message (`LedgerAgentMessage.settings`) with the
  snapshot from before the turn; 撤销 writes those sections back. A section that
  does not fit is reported to the model with the next question through the
  existing `note` mechanism, and any sections that did apply stay undoable.
- **Writes go through the existing setters**, so side effects happen exactly as
  when the user changes the same value by hand:
  `LedgerSession.setOverviewSections`, `setCompactTabDestinations`,
  `setValuationCurrency` (async: it re-reads the ledger in the new currency),
  `LedgerLocalReminders.shared.update` (notification permission + reschedule),
  and `LedgerReportSettings.save` + `LedgerReportReminders.settingsChanged`.
- **Valuation is verified after the await** (`session.ledger?.valuationCurrency`)
  because the setter returns silently when the session is busy or the load
  fails; a mismatch is reported instead of being recorded as applied.
- `LedgerSession`'s `overview-sections` and `compact-tabs` keys now come from
  `LedgerAgentAppSettings.Keys`, so there is one definition.
- `LedgerReportReminders.swift` was added to the portable target's sources (it is
  already `#if os(iOS)`), so the live host can ask for the report reschedule.
- `ToolCatalogJSON` now lists `ask_user` and the two settings tools after the
  ledger tools (it was ledger-only); its test was renamed and updated. D/E will
  extend the same list.
- `LedgerAgentSettingsView` is untouched; task B needs no settings page of its
  own. The chat row lives in a new app-only file so the settings rewrite in task
  A does not conflict with it.

## Progress

Done:

- `server/mobileagent/app_settings.go`: snapshot/update types, normalization,
  validation (every section, every enum, clock format, weekday, month day,
  report-section set), `get_app_settings` / `update_app_settings` with nested
  schemas and an allowed-values guide, the `appSettingsPrompt`, and the change
  bookkeeping returned as `appSettings: {snapshot, changedSections}`.
- `server/mobileagent/mobileagent.go`: `appSettings` request field, response
  field and outcome plumbing, tools and prompt registered last (after the
  history tools, before the memory prompt), never in onboarding mode.
- `server/mobileagent/app_settings_test.go` + updated `mobileagent_test.go`,
  `tool_schema_test.go`.
- `App/LedgerMobile/Sources/LedgerAgentAppSettings.swift`: Codable snapshot,
  section enum and titles, change record, update decoding, `load`, per-section
  `plan` validation, `LedgerAgentAppSettingsHost` (snapshot/apply) and its live
  iOS implementation.
- `App/LedgerMobile/Sources/LedgerAgentSettingsChangeView.swift`: the
  「已更改设置：…」 row with 撤销.
- `LedgerAgent.swift`: request/response fields, `LedgerAgentMessage.settings`,
  conversation `appSettings` host, apply-on-success, next-turn note, undo, and
  reset. `LedgerAgentSessions.swift` / `LedgerAgentBranches.swift`: the change
  is saved and restored with the conversation.
- `LocalLedgerRepository.runAgentTurn` sends the snapshot; `LedgerAgentView`
  builds it at turn start, sets the host and draws the row.
- `Tests/LedgerAgentAppSettingsTests.swift` and the `FEATURE_PARITY.md` row.

Remaining:

1. Watch CI until `Gate` is green; the Swift side was written without a local
   toolchain (Linux), so the iOS core/app jobs are its first compile.
2. Coordinator: review, then merge in the batch order and wire the two tool
   names into task A's 能力 › 可用工具 list if desired.

## Validation

- `server/`: `gofmt`, `go vet ./mobileagent`, `go test ./mobileagent` and
  `go build ./cmd/ledger-web` pass. `go test ./...` passes except two
  pre-existing failures on this machine that also fail on `origin/main` at
  `8ef3888b`: `mobileagent.TestFeedNeverCutsACharacter` (timing: the delivery
  goroutine does not run between byte-by-byte sends, so all deltas merge into
  one event) and `internal/app.TestGitHubWriteValidationLargeLedgerPerformance`
  (19s against a threshold). Both pass on CI's Backend job for `main`.
- Swift: no toolchain on this machine. Not yet compiled or run; CI's iOS core,
  iOS app and iOS widgets jobs are the check. Tests added but unverified:
  snapshot/wire-format equality with the Go literal, snapshot reading the
  values the screens write, custom weekdays and foreign currency round trip,
  update decoding (unknown sections dropped, broken block dropped), request
  encoding, applying every section, bad values refused per section without
  writing, no-op apply, undo of a section, and conversation-level apply /
  save / undo / failed turn / partial failure note.
- Not tested: a live model conversation (no key here), a real device, the
  notification permission prompt path after the assistant turns a reminder on.

## Open questions

- If the coordinator prefers the tool catalogue to list every assistant tool
  (files, memory, skills, MCP), that belongs to a follow-up once D and E land;
  this branch adds only its own two.
- Undo restores whole sections, not single fields: changing one reminder field
  and tapping 撤销 puts back the whole 提醒 area from before the turn. That
  matches the brief's "把这几个 section 恢复成改之前的快照".
