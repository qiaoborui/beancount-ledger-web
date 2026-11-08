# 20261109-agent-core-events

- Status: completed. Review findings are fixed. Local commits on
  `codex/agent-core-events`, not pushed, no PR.
- Last updated: 2026-11-09 00:50 UTC+8.
- Branch: `codex/agent-core-events`, based on `main` at `8f0abb3b`. Code covered
  by this note is the three `feat(agent)` and two `fix(agent)` commits listed
  under Changed files.
- Track "core-events" of the five-PR stack that brings the on-device ledger
  assistant (账本助手) to desktop-assistant parity. Go only; no Swift file is
  touched, and the current Swift build keeps working unchanged.
- Release: no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` change. PR body
  should say `需要发版：账本助手流式事件` (ships with the Swift bucket).

## Goal

Give the Swift shell what it needs for a streaming, interruptible assistant:

1. A richer observer event stream (text and reasoning deltas, tool start/end,
   usage) that never drops a non-delta event and never blocks the loop.
2. Response additions: ordered `steps`, `usage`, richer `toolCalls`,
   `stopReason`, reserved `compacted` / `compactedTurns`.
3. Stop keeps the partial reply and returns a transcript the next turn accepts.
4. `TruncateTranscriptJSON` for regenerate / edit-and-resend.

Ledger writes are not touched (still draft, change card, 写入账本, validation).

## Decisions

- **Opt-in streaming kinds (deviation).** The spec asked for new kinds to be
  emitted always, but also for `observer_test.go` to pass unchanged, and that
  test asserts the exact list `model, tool, model`. The new kinds are therefore
  sent only when the request sets `"streamEvents": true`
  (`turnRequestV1.StreamEvents`). Without it the observer sees exactly the old
  `model` / `tool` stream. The Swift bucket must send `streamEvents: true`.
  `steps`, `usage` and the new tool-call fields are always in the response.
- **Event order.** PiG emits `tool_execution_start` before it runs the
  before-tool hooks, so `tool_start` is sent from our before-tool hook right
  after the existing `tool` event, as the spec orders it. A call refused before
  running (blocked or invalid) gets its `tool_start` just before its
  `tool_end`, so every `tool_end` has a `tool_start`.
- **Usage per message (deviation in the acceptance list only).** `usage` is
  sent after every assistant message, as spec item 1 says. The real order is
  `model, thinking_delta+, thinking_end, text_delta+, usage, tool, tool_start,
  tool_end, model, text_delta+, usage`. The acceptance list left out the first
  `usage`. Each `usage` event carries the turn's running totals, so the last
  one equals `response.usage`.
- **Feed.** A mutex-guarded queue plus a 1-slot wake channel. Non-delta events
  are never dropped. Consecutive deltas of one kind are joined and flushed
  every 50 ms or 512 bytes. If the observer has not taken the last queued
  delta yet, the next ones are merged into it. A flush that is not forced
  holds back a trailing incomplete UTF-8 sequence, so every delta is valid
  text. `close()` drains everything before the response returns.
- **Previews.** `preview` is exactly the first 300 runes of the tool result
  text, with no ellipsis. `errorText` (spec left the size open) is the trimmed
  result text capped at 1000 runes.
- **thinking_end.** `durationMs` is measured from PiG `thinking_start` to
  `thinking_end`. `redacted` is read from the partial message's
  `ThinkingContent.Redacted`. Redacted thinking appears in steps as
  `{kind: thinking, redacted: true}` with no text.
- **`attempt`** is a reserved event field. Nothing sets it, because the spec
  required the existing `model` event to stay exactly as it is.
  `compaction_start` / `compaction_end` and `summarizedTurns` are documented
  and reserved for `codex/agent-auto-compaction`.
- **`stopReason`** is set only to `"aborted"` on a cancelled turn. Normal turns
  omit it.
- **Stop reply.** `reply` is the trimmed text of the last assistant message
  that survives sanitizing. PiG leaves an empty `aborted` assistant message
  when the stop lands between tools and the next request, and that message
  is not counted. A completed tool-call message's text (for example
  "我查一下。") can therefore be the reply. Trailing U+FFFD and invalid bytes
  from a stream cut inside a character are stripped.
- **Stop transcript.**
  - The message the stop cut off keeps only its text, as a clean
    `stopReason: stop` assistant message, or is dropped when it has no text.
    Its half-streamed tool calls never ran, so they go.
  - A completed tool-call message whose text is already in the transcript is
    not duplicated.
  - Each tool call with no result gets an `isError` result
    "用户停止了这一轮，工具没有执行完".
  - Trailing user messages of this turn that nothing answered (the question,
    or a nudge) are dropped, so the next question never follows another one.
  - If nothing from this turn survives, `transcript` is omitted and the shell
    keeps the previous one, as after a failure today. This avoids two user
    turns in a row and avoids replacing a History-only conversation with a
    system-only transcript. PiG adds a system message in front of a History
    replay, and the turn-start index accounts for that.
- **Truncate.**
  - The request names the cut by exactly one of `keepUserTurns` (first N
    stay) and `dropUserTurns` (last N go). Both count the transcript's own
    user turns. These are not always the visible questions: a long transcript
    loses its oldest turns, and a question that failed, or was stopped before
    anything came back, is never recorded. The shell should send
    `dropUserTurns` = the number of recorded questions from the target to the
    last one, because trimming the front does not move that count (review
    fix).
  - A cut past the recorded turns (`keepUserTurns` > total or
    `dropUserTurns` > total) returns `ok: false` with `userTurns` and an
    error, instead of the transcript unchanged. `keepUserTurns` == total and
    `dropUserTurns` 0 return it unchanged. This deviates from the spec's
    "keepUserTurns >= total returns unchanged" (review fix).
  - `userTurns` in the response is the number of real user turns in the
    *input* transcript, also in the out-of-range error.
  - A real user turn is a user message whose trimmed text is not one of the
    two nudge constants. The shell's `（系统提示：` note prefix stays part of
    its question.
  - A negative count, both or neither field, a wrong version, unknown fields
    and malformed JSON or transcripts return `ok: false` with an error.
- **Context tokens after a stop (review fix).** A model message that ends with
  all-zero usage (stopped or failed before the provider reported usage) still
  adds to the totals but does not overwrite `contextTokens`, which keeps what
  the last measured message held. An aborted message that did report usage
  still updates it, since its input is the context actually sent.
- **Refused calls' arguments (review fix).** The turn record remembers the
  arguments from PiG's `ToolExecutionStartEvent`, which is emitted for every
  call before the hooks run. A call that never reached the before-tool hook
  (an unknown tool) now has its arguments in its step, its `tool_start` and its
  `toolCalls` entry. Calls the hook saw keep the hook's arguments in
  `toolCalls`.
- **Feed timer (review fix).** `deliver` reads the clock once per pass for both
  the flush check and the wait, and clamps the wait at zero. A delta that
  came due between two readings could otherwise wait with no timer.
- **Cancelled responses stay compatible.** The Swift shell's cancelled branch
  ignores `reply` / `transcript` today (`ok` is false), so the new cancelled
  fields change nothing until the Swift bucket reads them.

## Changed files

Commits on `codex/agent-core-events`:

- `feat(agent): truncate transcripts to whole user turns`. Adds
  `server/mobileagent/truncate.go` and `truncate_test.go`.
- `feat(agent): stream reply, reasoning and tool events; report steps and
  usage`.
  - `server/mobileagent/observer.go`: event fields, kinds doc, new feed.
  - New `server/mobileagent/events.go`: `turnRecord` subscription, `stepV1`,
    `usageV1`.
  - `server/mobileagent/mobileagent.go`: `streamEvents`, `turnOutcome`
    refactor, response fields, tool-call fields.
  - New `server/mobileagent/events_test.go`.
- `feat(agent): keep a stopped turn's partial reply and transcript`.
  - `server/mobileagent/transcript.go`: `stoppedTurn`, `sanitizeAfterAbort`,
    `partialText`.
  - `server/mobileagent/mobileagent.go`: cancel path.
  - New `server/mobileagent/stop_test.go`.
- `fix(agent): let truncate count turns from the end and fail out of range`.
  Changes `truncate.go` and `truncate_test.go`.
- `fix(agent): keep a stopped turn's context size and refused calls'
  arguments`. Changes `events.go`, `observer.go`, `mobileagent.go` and
  `events_test.go`.

## Validation

All run on the final branch state unless noted.

- `cd server && go test ./mobileagent/... ./mobilecore/...`: pass.
- `cd server && go test ./...`: pass (1194 tests, 38 packages).
- `cd server && go build ./...`: pass.
- `cd server && go vet ./mobileagent/`: clean.
- `cd server && go test -race ./mobileagent/ -count=3`: pass, after the
  review fixes. Before them, the new tests also passed `-race -count=8`.
- Each intermediate `feat` commit was checked out in a throwaway worktree, and
  `go vet ./mobileagent/ && go test ./mobileagent/` passed on both.
- `bash scripts/build-ledgercore-xcframework.sh`: pass. The generated header
  exports `MobileagentTruncateTranscriptJSON`.
- `cd App/LedgerMobile && xcodegen generate && xcodebuild build -project
  LedgerMobile.xcodeproj -scheme LedgerMobile -destination 'platform=iOS
  Simulator,id=<iPhone 17 Pro Max UDID>' CODE_SIGNING_ALLOWED=NO` against the
  rebuilt LedgerCore: BUILD SUCCEEDED. The destination name did not resolve, so
  the run used the simulator's UDID.
- Existing `observer_test.go` and `mobileagent_test.go` pass unchanged.
- New tests:
  - `events_test.go`: event order, the steps interleaving (thinking, text,
    tool, text), joining 100 one-char deltas into fewer events with exact
    text, never cutting a character, a slow observer (20 ms per event) still
    getting every `tool_start` / `tool_end` and the full text, usage summing,
    and a non-zero context window for a built-in model.
  - `stop_test.go`: a stop mid-reply keeps the partial reply and a transcript
    that decodes and starts a follow-up turn; a stop during tools answers
    every call and the follow-up works; a stop before any reply omits the
    transcript; a unit test for `sanitizeAfterAbort`.
  - `truncate_test.go`: nudges are not counted (including a real nudge read
    back from a returned transcript), tool calls and results are never
    split, out-of-range cuts fail with `userTurns`, `dropUserTurns` cuts at
    the right question in a front-trimmed transcript, and bad input fails
    (including both or neither field).
  - Review fixes in `events_test.go`: `TestRefusedCallKeepsItsArguments` and
    `TestStoppedMessageKeepsTheContextTokens`.

## Not tested

- The feed timer race has no deterministic test, because the window is
  nanoseconds wide. The existing feed tests pass on the new code.
- No Swift unit or UI tests (`swift test`, `xcodebuild test`) were run, because
  no Swift changed. Only the app build above was run.
- The mid-tool stop test cancels on the first `tool_start` from the async
  observer. It usually lands inside the tool batch, which the synthetic
  result in its output confirms, but it may land in the following model
  stream. The test asserts the invariant that every call is answered either
  way, and `TestSanitizeAfterAbortClosesTheTurn` covers the missing-result
  path deterministically.
- Real providers (Anthropic, OpenAI, Gemini) were not exercised. All turn tests
  use PiG's faux provider. A real-provider check is needed that a stopped
  transcript ending on a tool result, followed by a new question, is
  accepted.

## Next

1. Review, then push `codex/agent-core-events` and open the PR (stack base for
   the Swift bucket). PR body: no version change, `需要发版：账本助手流式事件`.
2. Swift bucket:
   - Send `streamEvents: true`.
   - Decode the new event kinds and response fields (`steps`, `usage`,
     `stopReason`, tool-call `callId` / `durationMs` / `preview` /
     `errorText`).
   - On a cancelled response, show `reply` as a stopped message and store a
     non-empty `transcript`.
   - Call `MobileagentTruncateTranscriptJSON` for regenerate and edit, with
     `dropUserTurns` counted over the questions recorded in the transcript.
     On `ok: false`, do not resend with the stale context.
3. `codex/agent-auto-compaction` emits `compaction_start` / `compaction_end`
   and sets `compacted` / `compactedTurns`.
