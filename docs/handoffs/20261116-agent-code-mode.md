# 20261116-agent-code-mode

- Status: active
- Last updated: 2026-11-16 (UTC+8)
- Branch: `claude/project-thread-w1d29c`

## Goal

"Code mode" for the on-device 账本助手: instead of one tool call per model
turn, the model writes one script in the built-in Linux that calls many tools,
loops/filters/sums, and prints only the result. Research and phased plan are in
the project's Claude Doc "账本助手 Code Mode 调研" (Anthropic programmatic tool
calling, Anthropic code execution with MCP, Cloudflare Code Mode compared).

Approved by the maintainer: phase 1 only (tool bridge inside `bash`).

## Done (phase 1)

- `server/mobileagent/bridge.go`: per-run HTTP bridge on `127.0.0.1:0` with a
  fresh 24-byte token; Go-side allowlist `scriptableTools`; one call at a time;
  at most 200 calls per run; JSON at `/call`, `/tools`, `/tools/<name>` and a
  `ok|error` first-line text form under `/text/` for the shell client.
- `server/mobileagent/guest/ledger.sh` (busybox `wget`) and `ledger.py`
  (stdlib `urllib`), embedded and installed by a command prefix into
  `/usr/local/lib/ledger` when their version hash changes.
- `linux.go`: `bash` starts the bridge when the turn has scriptable tools,
  prefixes the command, stops the bridge after, and reports `tool_calls`.
  Bash description and `linuxToolPrompt` teach when to script.
- `mobileagent.go`: `files.scriptTools = scriptable(tools)` after all tools are
  assembled.
- Tests: `bridge_test.go` (auth, allowlist, limit, stop; end-to-end through host
  `/bin/sh` + GNU wget + python3 against the real tools).

## Not allowed from scripts

`bash` (the C runner holds one command at a time; it would wait for itself),
`ask_user`, memory/skill/app-settings writes, `delete_file`, `save_attachment`,
`archive_statement`, `reconcile_attachment`, `load_skill`.

## Remaining

1. CI green, then device test: `ledger tools`; `time ledger call get_accounts`;
   after `apk add python3`, `python3 -c 'import ledger'` time; a 12-month
   reconciliation with and without scripting (turns, time, tokens); background
   the app mid-run.
2. Unverified on device: guest reaching host `127.0.0.1`; busybox `wget
   --post-file/--header`; iOS reclaiming the listener while suspended.
3. Phase 2 (only if bridge round trip > 200 ms or python cold start > 5 s):
   in-process `run_script` (goja or starlark-go) over the same tool table.
4. Phase 3: progressive disclosure (drop rarely used schemas from the prompt).

## Notes

- Ledger query tools read the committed generation, not the draft.
- The prefix adds about 4.7 KB to each command passed to `sh -c` in the guest.
