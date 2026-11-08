# 20261109-agent-conversation-list

- Status: completed-pending-review — local commits on
  `codex/agent-conversation-list`, not pushed, no PR.
- Last updated: 2026-11-09 01:40 UTC+8.
- Branch: `codex/agent-conversation-list`, based on `main` at `8f0abb3b`. The
  code covered by this note ends at `18aaf067` (review fixes); this note
  update lands in the docs commit after it.
- Track "conversation-list" of the 5-PR stack bringing the iOS 账本助手 to
  Claude Desktop parity. Swift only; no Go changes.
- PR body must say: `需要发版：账本助手对话列表重命名/置顶`.

## Goal

Make the 账本助手 history and chat screen behave like a desktop chat client:
rename, pin, share and search conversations; show the conversation's name in
the header; send with Return; don't yank the view down while the user reads
back; announce finished answers to VoiceOver; fix copy that still said the
assistant is read-only.

Acceptance: rename persists across relaunch; pinned conversations come first
and survive pruning; search finds a conversation by its AI or custom title;
Return on the software keyboard sends while a multi-line paste does not;
scrolling up during a turn is not pulled back, and a jump button appears; old
v1 records decode.

## Decisions

- `LedgerAgentSavedConversation` gains optional `customTitle` and `pinnedAt`.
  `version` stays 1, and older records decode with both nil. Title order is
  `customTitle`, then `generatedTitle`, then the first question.
  `matches(_:)` also searches the title.
- **Deviation:** the spec said to update `current`/`background` on rename and
  pin. `LedgerAgent.swift` was off limits and `LedgerAgentConversation` has no
  name field, so the name and the pin live only on the saved record.
  `LedgerAgentSessions.save` copies both over from the previous record on
  every save. Renaming a live conversation that was never saved (its first
  turn still running) saves a record for it first. The header reads the name
  through `LedgerAgentSessions.title(of:)`.
- Model naming: precedence plus the carry-over keep a custom name in place.
  The view's `nameSession()` sits outside the allowed edit regions and was
  left alone, so the model may still be asked for a name that is never shown.
  That only happens when the user renames during the first turn.
- Rename alert (review fix): it still opens prefilled with the name on screen
  so a small edit is easy. `LedgerAgentRenameTarget` keeps that `shown` name,
  and saving goes through `LedgerAgentSessions.rename(_:to:shown:)`. When the
  trimmed text equals `shown` and the record has no custom title yet, nothing
  is stored, so the first question or the model's name stays automatic and a
  later model name still replaces it. An edited name, or a custom name saved
  again, is stored as before. Chosen over a placeholder-only field so users
  can tweak the AI name without retyping it.
- Rename and pin leave `updatedAt` alone, so the conversation doesn't move in
  the time sections.
- Pruning (limit 200) skips pinned and live conversations. It removes the
  oldest unpinned ones until the count is back at the limit.
- Unsent composer text: an in-memory `[UUID: String]` on `LedgerAgentSessions`.
  The composer writes it on every edit and restores it when it appears. The
  map is cleared when its conversation is deleted, on delete-all, and when
  another ledger is bound.
- History sections come from a new portable `LedgerAgentHistoryGroup.grouping`:
  置顶 (newest pin first), 今天, 昨天, 过去 7 天 (within 7 days of the start of
  today), 本月, 更早.
- 分享 uses `LedgerSession.amountsVisible` (the app-wide amount-masking toggle).
  It is passed into `LedgerAgentHistoryView(sharesText:)`, and 分享 is hidden
  when amounts are masked. The export is
  `LedgerAgentSavedConversation.plainTextExport()`: the title, then `问：…`
  (with `附件：a、b`) / `答：…` blocks, without tool calls.
- Header: the title is drawn by the shared `TerminalPageChrome`, which only had
  a plain `Text`. **Deviation:** I added an optional
  `titleAction: TerminalTitleAction?` (hint and closure) to
  `terminalPageChrome`. When it is set, the compact bar's title becomes a
  button. Every other page passes nothing and is unchanged. On iPad (regular
  width) the system navigation title is shown and is not tappable; the
  history context menu still renames there. Two one-line call-site edits in
  `LedgerAgentView.swift` fall outside the listed regions: the
  `.terminalPageChrome(...)` call and the history sheet's initializer.
- Composer: `LedgerAgentComposer.submission(old:new:)` treats exactly one
  newline appended at the end as Return. A pasted block or a newline in the
  middle stays in the field. Return in an empty field returns `submit: true`,
  and the screen's existing `canSend` / ghost / attachment rules decide what
  happens. Review fix: the newline is only removed and read as Return when the
  composer can send (no turn running, `canSend` true for the text without
  that newline). Otherwise it stays in the field, so a multi-line next
  question can be drafted while a turn runs or an attachment is processed.
  `canSend` and `ghost` now take the text as a parameter for this check. Hardware keyboards: `.onKeyPress(.return)` sends. Shift-Return is
  ignored by the handler, so the text system inserts the newline, and a flag
  stops that newline from being read as Return.
- Scrolling: `isAtBottom` follows the 1-pt anchor's `onAppear`/`onDisappear`
  and starts false, so a long reopened conversation shows the jump button.
  Content changes follow only when at the bottom. A new user message or a turn
  starting always scrolls. The jump button (glass on iOS 26, a bordered disc
  earlier, label 回到底部) sits bottom-trailing above the composer. Motion goes
  through the shared `withLedgerAnimation` / `.ledgerAnimation`, which drop
  the animation under Reduce Motion.
- VoiceOver: a new assistant message posts
  `AccessibilityNotification.Announcement("回答好了")` while the screen is on
  screen and the app is active.
- Copy: the intro no longer says 只读. It says changes go to a draft, show as a
  change card, and are written only after 写入账本 and validation; the API key
  and cost note stays. Three new ability rows: 改账（草稿确认后写入）, 附件对账,
  记忆. The settings section is now 可用工具 and lists the read tools,
  ask_user, the draft file tools, memory, attachments and saved conversations,
  matching `server/mobileagent/mobileagent.go`. Its footer explains the draft
  and auto-write behaviour.
- The Go history tools (`list_saved_conversations`) still show the first
  question, not the custom title. Left for later, since this track is Swift only.
- No version numbers changed. No new dependencies. Ledger writes are still
  manual-first. The temporary `@MainActor` on
  `testInterruptionNotificationNamesTheCause`, needed for the Xcode test
  target to compile, was reverted and is not committed.

## Changed files

- `App/LedgerMobile/Sources/LedgerAgentSessions.swift`: record fields,
  title/export, `LedgerAgentHistoryGroup`, rename/pin/unsent, save carry-over,
  pin-safe pruning.
- `App/LedgerMobile/Sources/LedgerAgentComposer.swift` (new, portable).
- `App/LedgerMobile/Sources/LedgerAgentHistoryView.swift` (new, moved out of
  `LedgerAgentView.swift` and now internal): sections, context menu, swipe
  pin, shared rename alert.
- `App/LedgerMobile/Sources/LedgerAgentView.swift`: header title and rename,
  scroll follow and jump button, composer Return and unsent text,
  announcement, intro and settings copy. The old private history view is
  deleted.
- `App/LedgerMobile/Sources/TerminalDesignSystem.swift`: optional title action.
- `App/LedgerMobile/Package.swift`: composer added to `sources:`; history view
  added to the app-only excludes.
- `App/LedgerMobile/Tests/LedgerAgentConversationListTests.swift` (new, 12
  tests).
- `App/LedgerMobile/FEATURE_PARITY.md`: ledger assistant row.

## Validation

Review fixes, all at `18aaf067`. iOS Simulator: iPhone 17, Xcode at
`/Applications/Xcode.app`.

- `cd App/LedgerMobile && swift test --filter LedgerAgent`: 89 tests, 0
  failures. This includes the new
  `testSavingTheShownAutomaticNameKeepsItAutomatic` (unchanged save keeps the
  name automatic and the model name then shows; an edited or re-saved custom
  name is kept). `LedgerAgentConversationListTests` now has 12 tests.
- `cd App/LedgerMobile && swift test`: XCTest 911 executed, 25 skipped, 0
  failures; Swift Testing 20 tests in 2 suites passed.
- `xcodegen generate`, then `xcodebuild test ... -only-testing:LedgerMobileTests`
  with the temporary `@MainActor` patch (reverted, not committed). This also
  compiles the app target, including `LedgerAgentView.swift`. 926 executed,
  7 skipped, 4 failures (3 unexpected in XCTest's count):
  - the three known Keychain tests that fail unsigned
    (`BookkeepingPipelineTests.testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey`,
    `ImportClassificationTests.testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences`,
    `LocalGitBackgroundCredentialTests.testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken`);
  - `LocalLedgerAutomaticSyncSessionTests.testRangeChangeAtSameRevisionDoesNotRebuildWidgetSnapshot`.
    This branch does not touch that code. Re-running that class on its own
    twice passed both times (0 unexpected), so the failure is flaky.
- UI tests were not re-run for the review fixes. Earlier run at `8ba890fe`:
  33 UI test failures, none involving the assistant. The identical 33 also
  fail on a clean `origin/main` (`8f0abb3b`).

## Not tested

- The UI by hand: the rename alert (including the unchanged-save path),
  Return while a turn is running, the context menu, swipe pin, the share
  sheet, the jump button, hardware-keyboard Return/Shift-Return, and VoiceOver
  announcements. No UI test covers them.
- Whether `.onKeyPress(.return)` reaches a vertical `TextField` on every iOS
  version. If the text system eats the key, plain Return still sends through
  the newline path, but Shift-Return at the end of the text would send too.
- How precise LazyVStack `onAppear`/`onDisappear` is for the bottom anchor.
  It has a small prefetch margin, so "at bottom" is approximate.

## Next

- Review on a device or simulator, then open the PR from
  `codex/agent-conversation-list` with the release note above. Expect small
  conflicts with `codex/agent-live-timeline` in `LedgerAgentView.swift`
  (header, composer, scroll area).
- Later: show custom titles in the Go `list_saved_conversations` output, and
  skip the model naming request when a custom title already exists.
