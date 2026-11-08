# 20261109-agent-live-timeline

- Status: completed-pending-review. Local commits on `codex/agent-live-timeline`,
  not pushed, no PR.
- Last updated: 2026-11-09 01:55 UTC+8.
- Branch: `codex/agent-live-timeline`, based on `codex/agent-conversation-list`
  at `9dbf9025`. This note covers the `feat(agent)` and `feat(ios)` commits
  listed under Changed files.
- Track "live-timeline" of the five-PR stack that brings the on-device ledger
  assistant (账本助手) to desktop-assistant parity. Swift only. No Go file is
  touched; the Go events come from `codex/agent-core-events`.
- Release: no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` change. PR body
  should say `需要发版：账本助手流式回答、思考与工具时间线`.

## Goal

Show a running turn the way a desktop assistant does:

1. Stream the reply as it is written.
2. Show reasoning as a collapsible "正在思考… / 思考了 N 秒" block.
3. Show tool calls as timeline rows with running/done/failed state, duration,
   arguments and a result preview.
4. Keep the same timeline on saved answers.
5. Stop keeps the partial reply as an "已停止" answer, and the next question
   continues from the transcript the native loop returned.
6. Show a context ring with how full the model's context is.

Ledger writes are unchanged: draft, change card, 写入账本, validation. Nothing
writes automatically.

## Decisions

- **One handler type.** Live events travel as a new `.live` kind on the
  existing `LedgerAgentStep`, not as a second callback, so
  `LocalLedgerRepository.runAgentTurn` and the observer stay as they are.
  `LedgerAgentConversation.advance` sends `.live` steps to `receive()` and
  returns early. They never fire `turnStepped` and never change the step count,
  so the Live Activity and the background run see the same steps as before.
- **`streamEvents`** is sent only when a step handler is attached
  (`onStep != nil`). Turns without an observer keep the old event stream.
- **Throttle.** Text and thinking deltas are collected in a draft and published
  at most every 80 ms (`liveInterval`). Tool, usage, thinking-end and
  compaction events publish at once. A test checks that 40 deltas publish fewer
  than 10 times.
- **Step records.** `LedgerAgentStepRecord` decodes both the native flat step
  (`kind`, `callId`, `name`, `arguments`, ...) and the saved nested form
  (`call`), and always saves the nested form. Unknown step kinds are dropped
  without failing the response. `text` in a saved message stays the final
  answer, because the Go history reader reads only role and text.
- **Live turn rules.** A thinking end with no open block adds a redacted
  thinking step. Tools are matched by `callId`. A duplicate start is ignored,
  and an end with no start adds a finished row. An end fills in arguments that
  the start lacked.
- **Answer placement.** Live, the last text step is the streaming answer only
  when it is the final step. Text written between tools is drawn inline in the
  timeline. Saved answers draw every step except the answer, then the answer.
- **Stop.**
  - The stop button appends the live partial right away as a stopped assistant
    message (steps, usage, duration) when there is text.
  - When the native loop's cancelled response arrives, it replaces that
    message's text, steps and usage. If nothing had streamed yet, a stopped
    message is inserted right after its question. If the response has no reply,
    nothing is added.
  - A non-empty returned transcript is adopted. An omitted transcript keeps the
    previous one.
  - The next question waits up to 3 s (`stopSettleTimeout`) for that response,
    so it does not start on a stale transcript. The view now reads
    `conversation.transcript` inside the turn closure, after that wait, rather
    than when the question is sent.
  - A stopped turn skips the draft review (`editor.review`). The existing
    unreviewed-draft flag makes the next turn review it.
  - Stopped answers are not announced to VoiceOver as finished answers.
- **Repository cancel path (deviation from a plain rethrow).** When the task is
  cancelled, `runAgentTurn` now returns a decoded response whose
  `cancelled == true`, instead of always throwing `CancellationError`. Any
  other response, or a decode failure, still throws as before.
- **Usage and meter.**
  - Conversation usage updates only when its fraction is known
    (`contextTokens` and `contextWindow` both > 0).
  - The ring shows only then. It turns the expense color at 80 %.
  - A tap opens a popover with "上下文已用 X% · N / M tokens".
  - Each message saves its usage, and a restored conversation shows the last
    known usage.
- **Compaction.** "正在压缩较早的对话…" shows while compacting live. A saved
  answer with `compacted` shows "已压缩较早的对话，以便继续". The events are only
  decoded here; `codex/agent-auto-compaction` emits them.
- **Display details.**
  - Durations under 1 s show in 毫秒, longer ones as seconds with one decimal.
  - Live tool groups start expanded; saved ones start collapsed under the
    summary line the answer already used.
  - A streaming code fence that has not closed renders as prose until it
    closes.
- **Tool titles (deviation).** Most tool names in the spec already had titles.
  Only `edit_memory` (更新记忆) and `write_memory` (整理记忆) were added.
- **Accessibility and motion.** All new motion goes through
  `withLedgerAnimation` / `.ledgerAnimation`, which drop it under Reduce Motion.
  Thinking and tool headers and rows expose their expanded state; each row's
  label combines title, state and duration. The running footer keeps the
  `ledger-agent-running` identifier and the "正在回答" label.
- **No Go changes.** The core-events branch already provides everything this
  track needs.

## Changed files

Commits on `codex/agent-live-timeline`:

- `feat(agent): decode streamed events, steps and usage; keep stopped replies`
  - `App/LedgerMobile/Sources/LedgerAgent.swift`: tool-call fields, step
    records, usage, live events, live turn, timeline items, request and
    response fields, `.live` step kind, conversation live state, throttle, stop
    settling, saved fields, streaming segmentation.
  - `App/LedgerMobile/Sources/LedgerAgentSessions.swift`: optional `steps`,
    `stopped`, `usage`, `compacted` on saved messages.
  - `App/LedgerMobile/Sources/LocalLedgerRepository.swift`: `streamEvents`,
    cancelled responses returned.
  - New `App/LedgerMobile/Tests/LedgerAgentTimelineTests.swift` (14 tests).
- `feat(ios): live thinking and tool timeline, stopped caption and context meter`
  - New `App/LedgerMobile/Sources/LedgerAgentTimelineView.swift`.
  - `App/LedgerMobile/Sources/LedgerAgentView.swift`: live timeline while
    running, step timeline, 已停止 and compaction captions on answers, context
    meter, scroll follow, transcript read at turn start.
  - `App/LedgerMobile/Package.swift`: excludes the new SwiftUI file from the
    portable package.
  - `App/LedgerMobile/FEATURE_PARITY.md`: 账本助手 row.
- `docs(handoffs): record the agent live timeline track` (this note).

## Validation

Run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Base branch, before changes: `cd App/LedgerMobile && swift test --filter
  LedgerAgent`: 89 tests, 0 failures.
- Final state: `cd App/LedgerMobile && swift test --filter LedgerAgent`: 103
  tests, 0 failures. `--filter "LedgerAgentTimelineTests|LedgerAgentTests"`
  passed 6 runs in a row while developing.
- `bash scripts/build-ledgercore-xcframework.sh`: pass.
- `cd App/LedgerMobile && xcodegen generate && xcodebuild test -project
  LedgerMobile.xcodeproj -scheme LedgerMobile -destination 'platform=iOS
  Simulator,id=<simulator UDID>' CODE_SIGNING_ALLOWED=NO`:
  - The run first needs `@MainActor` on `testInterruptionNotificationNamesTheCause`
    in `Tests/LedgerAgentTests.swift`; the base branch has the same problem. The
    attribute was added for the run and reverted, and it is not committed.
  - The agent test classes (`LedgerAgentTests`, `LedgerAgentTimelineTests`,
    `LedgerAgentConversationListTests`, `LedgerAgentAssistTests`,
    `LedgerAgentAttachmentsTests`): 102 tests, 0 failures, TEST SUCCEEDED.
  - The whole `LedgerMobileTests` target: 940 tests, 7 skipped, 3 failures. The
    failures are the known unsigned-Keychain tests:
    `BookkeepingPipelineTests.testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey`,
    `ImportClassificationTests.testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences`,
    and
    `LocalGitBackgroundCredentialTests.testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken`.
    The app target builds as part of this run, and the new files raise no
    warnings.
- The new tests cover:
  - decoding of every event kind and unknown kinds;
  - deltas and thinking duration;
  - tool upsert, a duplicate start and an end with no start;
  - timeline grouping;
  - responses with and without the new fields;
  - `streamEvents` in the request;
  - the usage fraction;
  - live events not counted as Live Activity steps;
  - the delta throttle;
  - a stop that keeps the partial, after which the next turn uses the returned
    transcript, with exactly one stopped message;
  - a stop before any text;
  - a stop with nothing returned keeping the old transcript;
  - the saved round trip and decoding older saved messages;
  - streaming fence segmentation.

## Not tested

- No real provider. The live UI was never seen against a real model stream.
- No manual run on a device or simulator UI, no VoiceOver pass, no Reduce
  Motion pass, and no Live Activity check.
- The intermediate `feat(agent)` commit was not built on its own. It touches
  only portable sources that the views need, and the package excludes
  SwiftUI views.
- The 3 s stop-settle wait is covered by unit tests with a fake runner, not
  against the native loop's real cancel timing.

## Next

1. Review this branch. Then push it and open the PR on top of
   `codex/agent-conversation-list`. PR body: no version change,
   `需要发版：账本助手流式回答、思考与工具时间线`.
2. After `codex/agent-core-events` and `codex/agent-conversation-list` merge,
   rebase onto `main`.
3. The remaining tracks build on this:
   - Regenerate and edit-and-resend with `MobileagentTruncateTranscriptJSON`.
   - `codex/agent-auto-compaction`, which emits the compaction events this
     branch already shows.
4. Fix the missing `@MainActor` on `testInterruptionNotificationNamesTheCause`
   on `main`, in its own change.
