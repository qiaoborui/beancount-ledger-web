# Bub Agent runtime

The conversational Agent runs as a separate Python gateway built on
`bubbuild/bub` 0.4.1. The service does not contain a second Agent loop: it loads
the repository's Bub plugin and lets Bub's `ChannelManager` own session queues,
streaming, model turns, tools, skills, Telegram, and tape persistence. Go and
the React client depend only on the Channel HTTP/SSE boundary, so another Agent
can replace Bub without moving ledger parsing or write safety out of Go.

```text
Browser -> Go API -> Bub Web Channel -> Bub model client -> Go model proxy
                    |                 |
                    |                 +-> bub-tapestore-sqlalchemy -> Postgres
                    +-> signed capability -> Go ledger tools

Telegram ----------> Bub Telegram Channel
Local bub chat -----> Bub CLI Channel -> remote read-only capability
```

The Agent service never receives a ledger checkout, GitHub token, provider API
key, or Beancount writer. It receives short-lived, ledger-bound capability
tokens and can call only the tool catalog exposed by Go. Model provider
credentials remain in the Go runtime configuration; Bub uses the private model
proxy.

Conversation tapes and projected UI timelines use the existing
`bub-tapestore-sqlalchemy` plugin. The dependency is pinned in `agent/uv.lock`;
there is no repository-owned TapeStore implementation. Deploy the Agent as one
instance because same-session turns are serialized in-process.

Write tools keep the existing boundary:

1. Go validates arguments and builds a preview artifact.
2. Bub pauses the tool call and emits `approval_required` on the open SSE turn.
3. The browser resolves the interaction through Go.
4. Bub supplies the preview-bound confirmation token and calls Go's execute
   endpoint.
5. Go runs the existing writer, `bean-check`, commit, and rollback path.

The public API does not contain a legacy Go Agent loop or runtime fallback.
Rollback is performed by deploying an earlier Git revision.

## Channels and capabilities

- The browser is a regular Bub `Interface` named `web`. The Agent service
  exposes it at `POST /v1/channels/web/messages` and projects Bub stream events
  into the product timeline over SSE.
- Telegram uses Bub's native long-polling Channel. The project plugin adds the
  ledger prompt, tools, preview, and exact next-message confirmation policy.
  Pending writes are serialized per chat and bound to the Telegram user who
  initiated them, so another allowed member of a group cannot approve or
  cancel that write.
- Local `bub chat` uses Bub's native CLI Channel. It exchanges a revocable
  `blw_agent_...` credential for a 15-minute capability containing only tools
  marked read-only.

The hosted gateway uses `AGENT_SERVICE_TOKEN` and can receive the complete Go
tool catalog. Browser write tools still use the capability minted for that Web
turn. Telegram write tools require preview and one of these exact replies:
`确认写入`, `确认入账`, or `confirm write`. Short acknowledgements such as `好`,
`OK`, and `👍` never approve a write.

Web, onboarding, and Telegram messages are passed to Bub as model prompts, not
as CLI command strings. Bub's comma-prefixed local command mode remains
available only to the operator running the native CLI Channel.

Required Agent environment:

```text
DATABASE_URL=postgresql://...
LEDGER_API_URL=http://server:3000
AGENT_SERVICE_TOKEN=<shared internal secret>
BUB_MODEL=openai:ledger-agent
BUB_API_BASE=http://server:3000/api/internal/agent/model
BUB_API_KEY=<same shared internal secret>
```

Optional Telegram environment:

```text
BUB_TELEGRAM_TOKEN=<BotFather token>
BUB_TELEGRAM_ALLOW_USERS=<comma-separated Telegram user IDs>
BUB_TELEGRAM_ALLOW_CHATS=<comma-separated Telegram chat IDs>
```

Keep the hosted Agent at one maximum instance while Telegram long polling is
enabled. Multiple instances would poll the same bot token and split in-process
approval/session state.

`AGENT_SERVICE_URL` and `AGENT_SERVICE_TOKEN` configure the Go gateway. Hosted
deployments also set `AGENT_SERVICE_AUDIENCE` so Go obtains a Cloud Run OIDC
token. The Agent service is private and is not routed through Caddy.

## Run Bub locally against a remote ledger

Open Settings, then create a Token under **本地 Agent 访问**. The plaintext is
shown once. From this repository:

```bash
cd agent
export LEDGER_API_URL=https://your-ledger.example
export LEDGER_AGENT_TOKEN=blw_agent_...
uv sync
uv run bub chat
```

The installed `bub-tapestore-sqlalchemy` plugin defaults to a local SQLite tape
database when `DATABASE_URL` is absent. The local process never receives the
remote Postgres URL or GitHub credentials. It also sends model requests through
`/api/agent/model`, so the actual provider, base URL, model name, and provider
API key remain in the remote instance's **实例运行配置**.
`BUB_MODEL=openai:ledger-agent` is the local alias for that OpenAI-compatible
proxy, not a second provider configuration.

### Local write access (opt-in)

By default a local `bub chat` session is read-only: the server mints a
15-minute capability containing only read-only tools, and write tools are never
downloaded. To let the local operator also write to the ledger, enable the
**允许本地 Agent 写入账本** toggle under Settings → 实例运行配置. The setting is
stored in the database `runtime_config` (no environment variable, no restart
needed).

With this enabled, every `blw_agent_...` token bootstrap returns the complete
tool catalog (including `append_transactions`, `update_transaction`,
`delete_transaction`, `reverse_transaction`, `apply_account_operations`, and
`upsert_memory`). The CLI channel has no interactive approval surface (it is a
synchronous REPL), so the system prompt instructs the agent to explain the
pending Beancount changes and ask for explicit confirmation in the conversation
before calling a write tool; it must never write without that confirmation. The
write itself still goes through the server's normal writer, `bean-check`,
commit, and rollback path — only the per-call approval handshake is skipped,
replaced by the in-dialog confirmation.

Instances without a configured database (filesystem-only) default to read-only
and cannot expose local write tools.

This is an all-or-nothing switch: it applies to every local access token. Keep
it off unless you specifically want write capability from a local CLI. Web and
Telegram write tools are unaffected — they keep their existing confirmation
flows regardless of this flag.
