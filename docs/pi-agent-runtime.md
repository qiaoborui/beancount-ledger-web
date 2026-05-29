# Pi Ledger Agent Runtime

Beancount Ledger Web can expose a small, token-protected tool surface for a Pi
agent without giving the agent direct file or shell access to `LEDGER_ROOT`.

The intended shape is:

```text
Pi agent
  -> ledger MCP server under agent/
    -> Go internal tool endpoints under /internal/agent/*
      -> LedgerCache / validation helpers
```

The Go service remains the authority for parsing, validation, writing, rollback,
and Git operations. The Pi agent is a reasoning layer only.

## Tool Boundary

The internal tool API is disabled unless `LEDGER_AGENT_TOOL_TOKEN` is set.
Requests must include the same token as `Authorization: Bearer <token>` or
`X-Ledger-Agent-Token`.

When `LEDGER_AI_RUNTIME=pi` and `LEDGER_AGENT_TOOL_TOKEN` is empty, the Go
service generates an in-memory token at startup and passes it to the configured
Pi wrapper process. Use an explicit token when running an external long-lived
MCP sidecar that is not launched by the Go process.

Available tools:

- `GET /internal/agent/accounts`
- `POST /internal/agent/transactions/query`
- `POST /internal/agent/expenses/summary`
- `POST /internal/agent/entries/validate`

The validate endpoint returns Beancount text previews but does not write files.
User-confirmed writes should continue to go through the existing web append
endpoints and `LedgerWriter`.

## MCP Server

Install the MCP server dependencies:

```bash
npm install --prefix agent
```

Run it with the same token as the Go service:

```bash
export LEDGER_AGENT_TOOL_BASE_URL=http://127.0.0.1:3000
export LEDGER_AGENT_TOOL_TOKEN="$(openssl rand -base64 32)"
node agent/ledger-mcp-server.mjs
```

For a Pi MCP proxy, adapt `agent/mcp.config.example.json` to your Pi MCP
extension or MCP bridge. The server name should be `ledger` so the project
permission policy can allow `ledger:*` while denying everything else.

## Pi Provider and Model Configuration

The Go service does not choose the Pi provider or model. It only exposes the
ledger tool boundary. Configure provider credentials and model selection in the
Pi process or sidecar.

Start from:

```text
agent/pi-runtime.env.example
```

Typical setup:

```bash
cp agent/pi-runtime.env.example agent/pi-runtime.env
nano agent/pi-runtime.env
set -a
. agent/pi-runtime.env
set +a
```

Then configure Pi with its normal provider/plugin flow. There are two practical
ways to pin the model:

1. Use Pi's interactive or CLI model selection for the session, then run the
   project `ledger-assistant` agent. This keeps repo config provider-neutral.
2. Add a static `model:` and optional `thinking:` field to
   `.pi/agent/agents/ledger-assistant.md` for the deployment.

Example frontmatter values depend on the provider plugin names installed in
your Pi runtime:

```yaml
---
name: ledger-assistant
model: openai/gpt-5.4-mini
thinking: low
---
```

or, for a Codex-oriented Pi provider:

```yaml
---
name: ledger-assistant
model: openai-codex/gpt-5.3-codex-spark
thinking: low
---
```

Keep the committed agent file model-free unless this repository should mandate
one provider. A model-free project agent inherits the current Pi session model,
which is easier to run on OpenAI, DeepSeek-compatible, local, or other Pi
providers.

## Runtime Wiring

Run Pi as a sidecar or wrapper rather than from the browser:

```text
Go /api/ai/chat
  -> configured Pi command/RPC wrapper
    -> ledger MCP server
      -> Go /internal/agent/* tools
```

Set:

```bash
LEDGER_AI_RUNTIME=pi
LEDGER_PI_COMMAND=/absolute/path/to/pi-ledger-wrapper
LEDGER_PI_ARGS=
LEDGER_PI_TIMEOUT_SECONDS=120
LEDGER_PI_PROVIDER=deepseek
LEDGER_PI_MODEL=deepseek-v4-flash
LEDGER_PI_THINKING=low
```

The Go service sends `PiAgentInput` JSON on stdin:

```json
{
  "message": "查看过去一周的消费",
  "messages": [],
  "draftEntries": [],
  "today": "2026-05-29"
}
```

The wrapper must write only `ChatResult` JSON to stdout:

```json
{
  "message": "中文回复",
  "plan": null,
  "sources": [],
  "entries": []
}
```

Read-only queries return `entries: []`. Draft bookkeeping returns entries for
the existing user-confirmation flow.

For streamed UI updates, the wrapper may also write progress lines to stderr.
Each progress line must be prefixed with `LEDGER_PI_EVENT ` and contain one
JSON object:

```text
LEDGER_PI_EVENT {"type":"status","text":"Pi Agent 正在思考"}
LEDGER_PI_EVENT {"type":"message","text":"查到了 3 条记录。"}
LEDGER_PI_EVENT {"type":"tool","tool":{"id":"ledger-query","name":"ledger.query_transactions","title":"Ledger MCP","status":"running"}}
```

The Go service forwards these progress lines as SSE status, message, and tool
events. Other stderr output is treated as diagnostic logging and is only used in
error messages.

`agent/run-pi-ledger-agent.example.sh` is a starting wrapper for the Pi CLI. It
uses Pi JSON mode, streams safe progress events through stderr, and keeps stdout
reserved for the final `ChatResult`.

## Pi Policy

This repo includes a restrictive project policy at:

```text
.pi/agent/pi-permissions.jsonc
.pi/agent/agents/ledger-assistant.md
.pi/agents/ledger-assistant.md
```

The agent file is intentionally present in both project-agent locations used by
common Pi extensions. Keep them synchronized when editing the prompt.

The policy denies file tools, bash, skills, and external-directory access, and
only allows the `ledger` MCP tool namespace. Install and enable
the Pi permission-system extension that matches your Pi install before using Pi
in this mode. For example:

```bash
pi install npm:pi-permission-system
```

Some Pi distributions use scoped packages such as
`@gotgenes/pi-permission-system`; use the package documented by your Pi runtime.

The agent file tells Pi to query ledger tools before answering questions about
existing records and to use `validate_entries` for drafts.

## Safety Notes

- Do not run Pi with `cwd=$LEDGER_ROOT` in production.
- Do not mount the private ledger into a Pi container unless it is read-only.
- Prefer a temporary working directory and expose ledger data only through the
  MCP tools above.
- Do not add direct write, edit, shell, commit, or push tools to this agent.
- Keep `LEDGER_AGENT_TOOL_TOKEN` out of logs, browser code, and committed files.
