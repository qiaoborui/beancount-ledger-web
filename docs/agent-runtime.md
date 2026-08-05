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
Local bub chat -----> Bub CLI Channel -> remote capability
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

Write tools use the same capability and execution path as read tools. Safety is
enforced as a conversational protocol plus the existing Go write boundary:

1. The model may use read, draft, and validation tools to prepare the exact
   change.
2. The model shows the complete proposed modification in its reply and ends
   the turn without calling a write tool.
3. The user explicitly confirms that exact proposal in the next relevant turn.
4. The model calls the ordinary write tool; there is no runtime approval event,
   confirmation token, approval card, or paused tool call.
5. Go validates the schema and source revision, performs the write, runs
   `bean-check`, commits, and rolls back on failure.

The public API does not contain a legacy Go Agent loop or runtime fallback.
Rollback is performed by deploying an earlier Git revision.

## Channels and capabilities

- The browser is a regular Bub `Interface` named `web`. The Agent service
  exposes it at `POST /v1/channels/web/messages` and projects Bub stream events
  into the product timeline over SSE.
- Telegram uses Bub's native long-polling Channel. The project plugin adds the
  ledger prompt, tools, and exact next-message confirmation policy. A
  confirmation is simply a new model turn; the Agent process does not need to
  remain resident between the draft and confirmation turns.
- Local `bub chat` uses Bub's native CLI Channel. It exchanges a revocable
  `blw_agent_...` credential for a 15-minute capability containing the full
  allowed tool catalog. Revoking or expiring the parent Token immediately
  invalidates capabilities that were already issued from it.

The hosted gateway uses `AGENT_SERVICE_TOKEN` and can receive the complete Go
tool catalog. Web, Telegram, and local CLI all follow the same cross-turn write
protocol. Telegram accepts one of these exact replies:
`确认写入`, `确认入账`, or `confirm write`. Short acknowledgements such as `好`,
`OK`, and `👍` never approve a write. In group chats, the prompt also requires
the confirming message's Telegram `sender_id` to match the user who requested
and received the draft.

Ordinary Web, onboarding, and Telegram messages are passed to Bub as model
prompts. Web, Telegram, and the native CLI Channel preserve Bub's
comma-prefixed command mode; those strings reach Bub's command runner without
being rewritten as model input.

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
enabled. Multiple instances would poll the same bot token and compete for
updates. This is a Telegram polling constraint, not a requirement to keep an
Agent alive while waiting for write confirmation.

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

### Local write access

Every valid `blw_agent_...` token bootstrap returns the complete allowed tool
catalog, including `append_transactions`, `update_transaction`,
`delete_transaction`, `reverse_transaction`, `apply_account_operations`, and
`upsert_memory`. There is no local-write configuration switch and no separate
approval surface. The system prompt requires the Agent to show the complete
pending Beancount change, end its reply, and wait for explicit confirmation in
the next user turn before calling a write tool. The write itself still goes
through schema validation, source revision checks, the server writer,
`bean-check`, commit, and rollback.
