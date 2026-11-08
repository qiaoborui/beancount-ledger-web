# 20261109-agent-auto-compaction

- Status: completed-pending-review. Local commits on
  `codex/agent-auto-compaction`. Not pushed, no PR.
- Last updated: 2026-11-09 01:41 UTC+8.
- Branch: `codex/agent-auto-compaction`, stacked on `codex/agent-core-events`
  at `286803fa`. This note covers the `feat(agent)` commit `fb4302f3`.
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
- sends system, then the summary, then the last 4 turns whole, then the new
  question;
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
  - The first kept question comes right after it, so two user messages sit
    side by side.
  - The spec asked for exactly this shape, and PiG/Pi already produce such
    pairs (PiG merges them for Bedrock).
  - The visible-history replay avoids such pairs, though, because it says some
    providers reject them. Check this against real providers before release
    (see Not tested).
- **Events**:
  - `compaction_start` is sent before the summary request and
    `compaction_end` after it. Both are streaming kinds, so only a request with
    `streamEvents: true` receives them.
  - `compaction_end` is also sent when the summary failed or the turn was
    stopped, then without `summarizedTurns`, so the shell can close the marker.
    The spec only covered the success case.
  - The summary request sends no `model` event, and its tokens are not added to
    the turn's `usage`.
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
  - `priorMessages` no longer trims. It reports whether it replayed a
    transcript, and the turn then compacts and trims.
- **Cancel**: a stop during the summary returns a cancelled turn with no
  transcript, so the shell keeps the previous, uncompacted one.
- **Truncate addition (beyond spec)**: `keepUserTurns: 0` / dropping every
  question keeps a summary that directly follows the system messages. The
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

## Validation

Run on `fb4302f3`.

- `cd server && go test ./mobileagent/... ./mobilecore/...`: pass (182
  tests).
- `cd server && go test ./...`: pass (1206 tests, 38 packages).
- `cd server && go build ./...`: pass.
- `cd server && go vet ./mobileagent/` and `gofmt -l ./mobileagent`: clean.
- `cd server && go test -race ./mobileagent/ -count=3`: pass.
- Mutation check: raising the threshold to 0.85 makes the acceptance,
  bytes-threshold, fallback, stop and idempotence tests fail.
- `bash scripts/build-ledgercore-xcframework.sh`: pass. No exported API
  changed.
- New tests in `compaction_test.go`:
  - `TestCompactionSummarizesOlderTurns`: the acceptance case.
  - `TestCompactionBelowThresholdKeepsThePrefix`: no summary request, the turn
    request equals the transcript plus the question, and the compactor returns
    the same slice.
  - `TestCompactionThresholdFromBytesWithoutUsage`: the estimate comes from
    bytes when usage is zero, the window rules hold, and a window filled to
    80% compacts while one filled to 50% does not.
  - `TestCompactionNeedsSixQuestions`: five questions are not compacted, and
    an earlier summary and nudges are not counted as questions.
  - `TestCompactionCutKeepsToolCallsWithTheirResults`: tool calls on both
    sides of the cut, a mid-transcript tool declaration, and a nudge in the
    removed part.
  - `TestCompactionFailureFallsBackToTheTrim`: an error reply and an empty
    reply each fall back, and a transcript over 320 KB is trimmed.
  - `TestCompactionTimeoutFallsBackToTheTrim`.
  - `TestStopDuringCompactionKeepsThePreviousTranscript`.
  - `TestCompactedTranscriptIsNotCompactedAgain`.
  - `TestTruncateDoesNotCountTheSummary`.

## Not tested

- Real providers were not exercised; every test uses PiG's faux provider. Two
  checks are needed:
  - Anthropic, OpenAI-compatible and Gemini endpoints accept the summary
    followed directly by the next question (two user messages in a row).
  - The summary's quality and length on a real long ledger conversation.
- No Swift tests and no `xcodebuild` run, because no Swift changed. Swift
  rendering is in `codex/agent-live-timeline`.
- The summary request's usage and cost are not reported anywhere.

## Next

1. Review, then push `codex/agent-auto-compaction` stacked on
   `codex/agent-core-events` and open the PR. PR body: no version change,
   `需要发版：账本助手自动压缩长对话`.
2. Swift (`codex/agent-live-timeline`):
   - Show a marker between `compaction_start` and `compaction_end`.
   - Treat a `compaction_end` without `summarizedTurns` as "not compacted".
   - Store the returned transcript as usual, and use `compacted` /
     `compactedTurns` for the in-conversation note.
3. Check two user messages in a row on real providers. If one rejects them,
   follow the summary with a short fixed assistant reply in
   `compactedMessages`.
