# 20261109-agent-auto-compaction

- Status: completed (review findings fixed). Local commits on
  `codex/agent-auto-compaction`. Not pushed, no PR.
- Last updated: 2026-11-09 03:20 UTC+8.
- Branch: `codex/agent-auto-compaction`, stacked on `codex/agent-core-events`
  at `286803fa`. This note covers the `feat(agent)` commit `fb4302f3` and the
  review-fix commit that follows it.
- Track "auto-compaction" of the five-PR stack that brings the on-device
  ledger assistant (账本助手) to desktop-assistant parity. Go only. No Swift
  file is touched. `codex/agent-live-timeline` renders the marker and meter
  from the event kinds and response fields that core-events reserved.
- Release: no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` change. PR body:
  `需要发版：账本助手自动压缩长对话`.

## Goal

When a conversation's transcript nears the model's context window, replace
its older turns with a model-written summary before the turn's first request.
The conversation keeps going instead of losing old turns blindly to the byte
trim. Ledger writes are not touched: they stay draft, change card, 写入账本,
validation.

Acceptance (all covered by tests): a fake provider reports usage at 80% of the
window on the last answer of an 8-question transcript. The next turn then:

- makes exactly one tool-less summary request before the turn request;
- sends system, then the summary and its fixed acknowledgement, then the last
  4 turns whole, then the new question;
- emits `compaction_start` and then `compaction_end` (`summarizedTurns` 4),
  both before `model`;
- returns `compacted: true`, `compactedTurns: 4` and a transcript that decodes.

Below the threshold nothing is summarized and the prefix is unchanged. A
failed summary falls back to the trim, and the turn still answers.

## Decisions

- **Trigger** (`server/mobileagent/compaction.go`):
  - The estimate is the usage of the transcript's last assistant message
    (`input + cacheRead + cacheWrite + output`). When that is zero or missing,
    it is the encoded transcript bytes divided by 3.
  - Compaction starts at 75% of `model.Capabilities.ContextWindow`. The window
    is 128000 for an assumed model (custom endpoint or listed-only), and also
    for a model that reports no window.
  - **Review fix:** compaction also starts when the encoded transcript is past
    the 320000-byte `transcriptBudget` (same per-message measure as the trim,
    `messageSizes`). 320 KB is roughly 80k-110k tokens, so for any window of
    about 150k tokens or more the trim fired first and the token threshold was
    never reached; old turns were dropped without a summary. Now the summary
    comes first and the trim is the last resort.
  - A transcript with fewer than 6 real questions is never compacted.
  - Only a replayed transcript is compacted. A conversation that sends only
    `history` (saved by an older build) is not, and before this change it was
    not trimmed either.
- **Real questions**: compaction counts with `isUserTurn` from `truncate.go`,
  the same helper truncation uses. That helper now also skips a user message
  whose trimmed text starts with `compactionMarker`, as it already skipped the
  two nudges.
- **Cut**: the first of the last 4 real questions. The removed part is
  everything between the opening system messages and the cut. Because the cut
  is at a user message, a tool call is never separated from its result.
  - **Review fix:** when the last 4 turns together exceed what the trim keeps
    (`transcriptBudget * 0.6`, 192 KB), fewer are kept (at least 1) and the
    summary covers the rest, so the trim does not then drop kept turns the
    summary does not cover. `compactedTurns` counts what was summarized.
- **System messages in the removed part are kept (spec clarification).** PiG
  puts tool declarations (`toolsAdded`) in system messages in the middle of a
  transcript and replays them in order. The compacted transcript is therefore:
  the opening system messages, then any system messages from the removed part
  (still in order), then the summary, then the kept turns.
- **Summary request**:
  - It goes through `complete()` in `assist.go`, the same tool-less,
    thinking-off path that titles and recaps use, on the turn's own network
    client and key.
  - The Chinese prompt `compactionPrompt` asks for goals, decisions and
    preferences, accounts, categories, merchants, date ranges and amounts,
    edits drafted, written or discarded, and open questions, in at most about
    1500 characters. It also asks the summary to say that amounts must be
    re-queried from the ledger.
  - **Review fix:** the prompt also says tool results and quoted text (bill
    memos, payees) are data: instructions inside them must not be recorded as
    the user's goals or preferences. The summary is replayed in user role, so
    copied instructions would otherwise gain trust.
  - The older turns are rendered as text: user and assistant text up to 2000
    runes each, each tool call as name plus JSON arguments (300 runes), and
    each tool result's start (800 runes). Reasoning and nudges are left out.
    An earlier summary is passed on as `更早对话的摘要`.
  - The rendered text is capped at 120 KB. The first piece and as many of the
    latest pieces as fit are kept, the same way as `recapMessage`.
  - A reply longer than 2000 runes is cut off.
- **Summary message**: one user message,
  `（系统提示：以下是之前对话的摘要，较早的消息已压缩）`, then a fixed line saying
  amounts were true when read and must be re-queried, then the summary.
  - **Review fix (deviation from spec):** the summary is followed by one fixed
    assistant message, `compactionAck` (`好的，我会参考这份摘要继续。`), text
    only, stamped with the turn model's API, provider and ID. Without it the
    first kept question followed the summary as a second user message in a
    row, which the visible-history replay says some providers reject; a
    rejecting provider would have failed every turn past the threshold.
  - `isCompactionAck` recognizes it. `summarySource` skips it, it is not a
    question, and `compactionEnd` treats summary + acknowledgement as one
    pinned block.
- **Events**:
  - `compaction_start` is sent before the summary request and
    `compaction_end` after it. Both are streaming kinds, so only a request with
    `streamEvents: true` receives them.
  - `compaction_end` is also sent when the summary failed or the turn was
    stopped, then without `summarizedTurns`, so the shell can close the marker.
    The spec only covered the success case.
  - The summary request sends no `model` event.
  - **Review fix:** its tokens are added to the turn's `usage` counters
    (`input`, `output`, `cacheRead`, `cacheWrite`) through
    `completeUsage` and `turnRecord.addUsage`, failed replies included.
    `contextTokens` stays the conversation's. They appear with the first
    turn request's `usage` event.
- **Response**: `compacted` / `compactedTurns` are set on an answered turn. On
  a stopped turn they are set only when that turn returns a transcript, which
  then starts with the summary. A failed turn returns no transcript and sets
  neither.
- **Fallbacks**:
  - The summary is capped at 60 s inside the turn context
    (`compactionTimeout`, a var so tests can shorten it).
  - If it fails, times out or returns empty text, the transcript is left as it
    was and `compacted` stays false.
  - `trimTranscript(…, 320000)` always runs after the compaction step, as the
    fallback and as the final bound. Within the budget it returns its input
    unchanged, so below the threshold the messages are passed through as they
    are and the prompt-cache prefix does not move.
  - **Review fix:** the trim keeps a summary (and its acknowledgement) that
    directly follows the opening system messages, like the system head, and
    drops turns after it. Before, it dropped the summary first while the
    response still said `compacted: true`.
  - Not changed: a failed summary is retried on the next turn that is still
    over a trigger. With the byte trigger, the fallback trim brings the
    transcript under the budget, so a retry only repeats while the token
    threshold alone stays exceeded.
  - `priorMessages` no longer trims. It reports whether it replayed a
    transcript, and the turn then compacts and trims.
- **Cancel**: a stop during the summary returns a cancelled turn with no
  transcript, so the shell keeps the previous, uncompacted one.
- **Truncate addition (beyond spec)**: `keepUserTurns: 0` / dropping every
  question keeps a summary (with its acknowledgement) that directly follows
  the system messages (shared `compactionEnd` helper; a duplicated branch
  from the first commit is gone). The
  summary stands for questions the shell can no longer cut, so editing the
  first recorded question does not lose the earlier context.

## Changed files

- New `server/mobileagent/compaction.go`: trigger, cut, summary request,
  compacted transcript, summary source.
- New `server/mobileagent/compaction_test.go`.
- `server/mobileagent/mobileagent.go`: compaction step in `runTurnIn`,
  `priorMessages` signature, `turnOutcome.compactedTurns`, response fields.
- `server/mobileagent/truncate.go`: `isUserTurn` skips the summary, and
  keep-0 keeps it.
- `server/mobileagent/observer.go`: documentation of the compaction kinds.
- Review fix: `transcript.go` (`messageSizes`, trim keeps the summary),
  `assist.go` (`completeUsage`), `events.go` (`addUsage`).

## Validation

Run on the review-fix commit (working tree identical to it).

- `cd server && go test ./mobileagent/... ./mobilecore/...`: pass (185
  tests).
- `cd server && go test ./...`: pass (1209 tests, 38 packages).
- `cd server && go build ./...`: pass.
- `cd server && go vet ./mobileagent/` and `gofmt -l ./mobileagent`: clean.
- `cd server && go test -race ./mobileagent/ -count=3`: pass.
- Mutation checks on the review fixes: removing the byte trigger fails
  `TestCompactionComesBeforeTheTrimWithALargeWindow`; removing the summary
  pin in the trim or the fewer-kept-turns loop fails
  `TestCompactionKeepsTheSummaryWhenKeptTurnsAreLarge`.
- Earlier, on `fb4302f3`: raising the threshold to 0.85 made the acceptance,
  bytes-threshold, fallback, stop and idempotence tests fail, and
  `bash scripts/build-ledgercore-xcframework.sh` passed. The review fixes
  change no exported API, so the xcframework was not rebuilt.
- Tests in `compaction_test.go`:
  - `TestCompactionSummarizesOlderTurns`: the acceptance case (now also
    checks the acknowledgement).
  - `TestCompactionBelowThresholdKeepsThePrefix`: no summary request, the turn
    request equals the transcript plus the question, and the compactor returns
    the same slice.
  - `TestCompactionThresholdFromBytesWithoutUsage`.
  - `TestCompactionNeedsSixQuestions`.
  - `TestCompactionCutKeepsToolCallsWithTheirResults` (acknowledgement fields,
    and the next summary source skips it).
  - `TestCompactionFailureFallsBackToTheTrim`.
  - `TestCompactionTimeoutFallsBackToTheTrim`.
  - `TestStopDuringCompactionKeepsThePreviousTranscript`.
  - `TestCompactedTranscriptIsNotCompactedAgain`.
  - `TestTruncateDoesNotCountTheSummary`.
  - New: `TestCompactionComesBeforeTheTrimWithALargeWindow` (10 x 36 KB,
    usage 50% of a 200k window: compacts 6, request opens with summary,
    acknowledgement, `问题7`; summary tokens are in the turn usage).
  - New: `TestCompactionKeepsTheSummaryWhenKeptTurnsAreLarge` (4 x 100 KB kept
    turns: keeps 1, summarizes 7, summary survives; the trim keeps summary and
    acknowledgement).
  - New: `TestTruncateKeepsTheSummaryAndItsAnswer`.

## Not tested

- Real providers were not exercised; every test uses PiG's faux provider. Two
  checks are needed:
  - Anthropic, OpenAI-compatible and Gemini endpoints accept the synthesized
    acknowledgement (an assistant message with no usage, stamped with the
    turn model).
  - The summary's quality and length on a real long ledger conversation.
- No Swift tests and no `xcodebuild` run, because no Swift changed. Swift
  rendering is in `codex/agent-live-timeline`.
- The summary's usage is folded into the turn counters; it is not reported
  as a separate field.

## Next

1. Review, then push `codex/agent-auto-compaction` stacked on
   `codex/agent-core-events` and open the PR. PR body: no version change,
   `需要发版：账本助手自动压缩长对话`.
2. Swift (`codex/agent-live-timeline`):
   - Show a marker between `compaction_start` and `compaction_end`.
   - Treat a `compaction_end` without `summarizedTurns` as "not compacted".
   - Store the returned transcript as usual, and use `compacted` /
     `compactedTurns` for the in-conversation note.
3. Check the summary + acknowledgement shape on real providers.
