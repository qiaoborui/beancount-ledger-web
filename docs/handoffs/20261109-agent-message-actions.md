# 20261109-agent-message-actions

- Status: completed-pending-review. Local commits on
  `codex/agent-message-actions`, not pushed, no PR.
- Last updated: 2026-11-09 02:45 UTC+8.
- Branch: `codex/agent-message-actions`, based on `codex/agent-live-timeline`
  at `a64115b6`. This note covers the `feat(agent)` and `feat(ios)` commits
  listed under Changed files.
- Track "message-actions" of the stack that brings the on-device ledger
  assistant (账本助手) to desktop-assistant parity. Swift only. No Go file is
  touched; the truncation bridge `MobileagentTruncateTranscriptJSON` comes from
  `codex/agent-core-events`.
- Release: no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` change. PR body
  should say `需要发版：账本助手复制/重新生成/编辑重发与分支`.

## Goal

Desktop-assistant message actions:

1. Copy, regenerate and share under finished answers. Context menus on answers
   and questions.
2. Edit a question and resend it.
3. Keep every version as a branch with a `‹ N/M ›` switch.
4. Persist versions and per-version transcripts.

Ledger writes stay manual-first: draft, change card, 写入账本, validation.
Nothing writes automatically.

## Decisions

- **Stable ids.** `LedgerAgentMessage.id` is a `var` and is saved
  (`Message.id`, optional). Records without ids get a name-based UUID derived
  from the conversation id and the message index (`LedgerAgentMessageID`).
  Branch messages without ids use index `messages.count + i`.
- **Thread.** `LedgerAgentThread` (new `LedgerAgentBranches.swift`, in
  `Package.swift`) holds nodes, ordered children and `activeLeaf`.
  `conversation.messages` stays the active path. Its `didSet` calls
  `thread.adopt`, which adds or reparents messages and never removes any, so
  the existing code that edits `messages` keeps working unchanged.
- **Saved format v2.** Adds optional `branches` (each with parent, sibling
  index and message) and `activeLeaf`. A v1 save decodes as one branch.
  `saved()` now writes `version: 2`. The Go history reader reads only
  role/text from `<id>.json`.
- **Per-leaf transcripts.**
  - Saved as `runtime/agent-history/<id>.<leaf>.transcript` through new
    Storage methods: `saveBranchTranscript`, `loadBranchTranscript` and
    `pruneBranchTranscripts`.
  - `<id>.transcript` stays the active leaf's transcript.
  - Deleting a conversation removes them all.
  - When a switch lands on a version with no transcript, the stored active
    transcript is cleared so a stale one is not restored.
- **Deviation: cut by dropped questions.** The spec suggested
  `keepUserTurns` / `userTurnIndex`. The cut instead uses `dropUserTurns`,
  counting only the questions the transcript actually records:
  - A new per-message `outsideTranscript` flag, saved as optional, marks
    questions that are running, failed, or stopped without a returned
    transcript.
  - This matches the core-events review fix, which keeps cuts correct on
    front-trimmed or compacted transcripts.
  - The runner's `truncate: (String, Int)` takes that drop count.
  - The conversation also keeps a `truncate` property so tests can inject a
    fake.
- **Fallback.** With no transcript, or when the cut fails, the next turn runs
  with no transcript and replays the visible history
  (`LedgerAgentHistory.entries`).
- **Guards.** `canBranch` is false while:
  - a turn runs,
  - a write or undo is in flight,
  - a version is loading (`switching`),
  - a change card is pending.

  The view also waits for another conversation's turn and for files being
  attached.
- **Confirmation.**
  - Replacing answers whose write was not undone asks with the spec text, and
    the verb follows the action (重新生成 / 编辑后重新发送 / 切换版本). Buttons
    are 继续 / 取消.
  - An unreviewed draft left by a stop asks too; continuing discards it
    through the existing `discard()`.
  - The model gets a short system note that written changes stayed, or that
    the user switched versions.
- **Beyond spec.**
  - `showLatestAnswer` and a 回到之前的回答 button after a regenerate that
    failed or stopped before replying.
  - Retrying a failed question with the same text keeps it in place. Different
    text on a failed question that already has answers forks it.
  - Recap, next suggestion and restored notice are cleared on a version
    change.
  - `discard()` resets `draftUnreviewed`.
- **Attachments on regenerate.** The turn builder (`turnReporting()`, shared
  by send, regenerate and edit) now reads the attachment payloads when the turn
  starts, not when it is asked. The cut runs first and re-marks the question's
  files as new, so they are sent again.
- **UI.**
  - The action row uses icon buttons with VoiceOver labels. Share is a
    `ShareLink`, hidden while amounts are masked.
  - The `‹ N/M ›` switch has buttons labelled 上一个版本 / 下一个版本, each
    with the value "N / M".
  - The question being edited gets a thin outline.
  - Copy, in the row, the context menus and code blocks, plays
    `.sensoryFeedback(.success)`.

## Changed files

- `feat(agent)` commit:
  - `App/LedgerMobile/Sources/LedgerAgentBranches.swift` (new)
  - `App/LedgerMobile/Sources/LedgerAgent.swift`
  - `App/LedgerMobile/Sources/LedgerAgentSessions.swift`
  - `App/LedgerMobile/Sources/LocalLedgerWorkspace.swift`
  - `App/LedgerMobile/Package.swift`
  - `App/LedgerMobile/Tests/LedgerAgentBranchesTests.swift` (new, 15 tests)
- `feat(ios)` commit:
  - `App/LedgerMobile/Sources/LedgerAgentView.swift`
  - `App/LedgerMobile/FEATURE_PARITY.md`

All committed locally; nothing pushed.

## Validation

All run on the branch HEAD before this note.

- `cd App/LedgerMobile && swift test --filter LedgerAgent`: 120 tests, 0
  failures (baseline 105 plus 15 new).
- `cd App/LedgerMobile && xcodegen generate`, then `xcodebuild build -project
  LedgerMobile.xcodeproj -scheme LedgerMobile -destination 'id=<booted iPhone
  17 Pro>' CODE_SIGNING_ALLOWED=NO`: BUILD SUCCEEDED.
- `xcodebuild test ... -only-testing:LedgerMobileTests`: 957 tests, 7 skipped,
  3 failures.
  - The failures are the known unsigned-Keychain ones:
    - `BookkeepingPipelineTests.testSemanticCredentialsStayLocal...`
    - `ImportClassificationTests.testConsentIsPerLedger...`
    - `LocalGitBackgroundCredentialTests.testDeviceOnlyCredentialMigrates...`
  - The run needed the usual temporary `@MainActor` on
    `LedgerAgentTests.testInterruptionNotificationNamesTheCause`, reverted
    before committing.
- Go: not run. No Go change.

## Not tested

- Nothing was run in the simulator: no API key or model was configured. The
  action row, context menus, edit banner, version switch, confirmation alert
  and code-block copy are compile-checked only.
- A long press on answer and question text, which uses `textSelection`, may
  compete with the context menu. Check on a device.
- The real `MobileagentTruncateTranscriptJSON` call on a device. Tests use a
  fake truncator. The bridge request shape follows the Go handler.
- VoiceOver and Reduce Motion behaviour, by hand.

## Next

1. Review the two commits; check the long-press and context-menu feel on a
   device.
2. Run one regenerate and one edit against a real model, then switch versions
   and continue, to confirm the cut transcript is accepted.
3. Open the PR in stack order after `codex/agent-live-timeline`, with the
   release line above.
