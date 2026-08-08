# Bub Agent runtime

The conversational Agent runs as a separate Python gateway built on
`bubbuild/bub` 0.4.2. It uses the unmodified `bub-mcp` 0.0.1 plugin for ledger
tool discovery and execution. The repository plugin still owns product Channel
integration and policy, while Bub's `ChannelManager` owns session queues,
streaming, model turns, skills, Telegram, and tape persistence.

```text
Browser -> Go API -> Bub Web Channel -> Bub model client -> Go model proxy
                    |                 |
                    |                 +-> bub-tapestore-sqlalchemy -> Postgres
                    +-> bub-mcp -> POST /mcp -> Go ledger tools

Telegram webhook -> Go API -> Bub Telegram Channel (webhook mode)
Telegram ---------> Bub Telegram Channel (polling mode)
Any MCP client ---------------------> POST /mcp
Local bub chat ---> Bub CLI Channel -> bub-mcp -> POST /mcp
```

The Agent service never receives a ledger checkout, GitHub token, provider API
key, or Beancount writer. At startup it generates a private temporary
`mcp.json` from `LEDGER_API_URL` and `AGENT_SERVICE_TOKEN`; the file is removed
at shutdown. Model provider credentials remain in the Go runtime configuration;
Bub uses the private model proxy.

Conversation tapes and projected UI timelines use the existing
`bub-tapestore-sqlalchemy` plugin. The dependency is pinned in `agent/uv.lock`;
there is no repository-owned TapeStore implementation. Deploy the Agent as one
instance because same-session turns are serialized in-process.

Write tools use the same MCP and Go execution path as read tools. Safety is
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

The current Agent does not use the former bootstrap/capability wrapper. The Go
API temporarily retains those endpoints as a deprecated rolling-deployment
bridge so an older Agent revision can keep working while the Server is promoted
before the new MCP-based Agent. New integrations must use `/mcp`; the bridge can
be removed after every deployed Agent has crossed this migration. Runtime
rollback is still performed by deploying an earlier Git revision.

## Stateless MCP service

The Go server exposes `POST /mcp` using Streamable HTTP in stateless JSON mode.
It supports the MCP `2026-07-28` discovery flow and legacy `initialize` clients.
Every request authenticates independently with one of these Bearer credentials:

- `AGENT_SERVICE_TOKEN` for the private hosted gateway. It can discover all
  ledger tools; Channel-specific `allowed_tools` remains the model boundary.
- A revocable `blw_agent_...` Token for external MCP clients. New Tokens are
  read-only by default. A Token created with write scope can also discover and
  invoke write tools. Existing pre-scope Tokens retain their former read/write
  access until revoked or expired.

Remote tool names use the `ledger_` prefix. Through `bub-mcp`, the model-visible
names use `mcp.ledger_`. Browser-only `open_page` remains a local Bub tool and is
never exposed by the MCP server. `ledger_agent_context` lets runtimes load the
current system instructions programmatically and is not included in the model's
allowed tool list.

Production deploys promote and health-check the Server before deploying the
Agent, because `bub-mcp` verifies `/mcp` during Agent startup. On a first install,
the workflow starts the Server with a temporary Agent URL, deploys the Agent,
then binds the published private Agent URL back to the Server. This avoids a
startup cycle while keeping upgrades available through the deprecated bridge.

## Channels and capabilities

- The browser is a regular Bub `Interface` named `web`. The Agent service
  exposes it at `POST /v1/channels/web/messages` and projects Bub stream events
  into the product timeline over SSE.
- Telegram uses Bub's native Telegram Channel. Normal model output is disabled
  for this channel; after completing its reasoning and ledger tool calls, the
  Agent sends exactly one final response through the restricted `telegram_send`
  or `telegram_send_rich` tool. The tools bind the current chat and source
  message in runtime state, so the model cannot choose another chat or access
  the bot token. Comma-prefixed Bub commands still reply through the Channel
  directly because they bypass the model and skills. A confirmation is simply a
  new model turn; the Agent process does not need to remain resident between
  the draft and confirmation turns.
- `BUB_TELEGRAM_MODE=polling` (default) uses Telegram long polling and keeps the
  local/self-hosted behavior. `BUB_TELEGRAM_MODE=webhook` initializes the
  Telegram Application and Bot but never starts `getUpdates`; the Go API
  receives the webhook, verifies the secret token, and forwards the raw update
  to `POST /v1/channels/telegram/updates` with the internal service token. The
  Agent parses the update with python-telegram-bot and processes the whole turn
  synchronously so the request stays open (Cloud Run keeps CPU allocated). The
  Go gateway serializes updates and deduplicates completed `update_id` values;
  a duplicate webhook delivery is acknowledged without a second reply. If the
  Agent finishes a reply but the process crashes before the completion is
  recorded, Telegram may still retry the update once, so the reply can
  theoretically be sent twice; this window cannot be fully eliminated.
- Local `bub chat` uses Bub's native CLI Channel and the installed `bub-mcp`
  plugin. The server filters discovery from the Token's scope on every request,
  so revoking or expiring the Token takes effect immediately.

The hosted gateway uses `AGENT_SERVICE_TOKEN` and can receive the complete MCP
tool catalog. A locked Web turn exposes only local `open_page`; an unlocked Web
turn exposes ledger MCP tools too. Telegram exposes ledger MCP tools plus its
restricted response tools. Web, Telegram, and local CLI all follow the same cross-turn write
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
BUB_TELEGRAM_MODE=polling|webhook
```

Keep the hosted Agent at one maximum instance for both Telegram modes.
Multiple polling instances would compete for updates with the same bot token,
and the in-process session scheduler serializes same-chat turns. Webhook mode
additionally lets the Agent scale to zero between messages: Cloud Run requests
start a cold instance, process the turn, and shut down. Long-polling mode
instead requires one minimum instance with always-allocated CPU to keep the
poll alive.

Webhook mode requires the Go gateway to know the same
`TELEGRAM_WEBHOOK_SECRET` used as the Telegram `secret_token`, and Telegram
must be configured with `setWebhook` pointing at
`<PUBLIC_ORIGIN>/api/integrations/telegram/webhook` with
`allowed_updates=["message"]` and `max_connections=1`. The production workflow
performs that switch after deploying the webhook-capable Agent and the Go
route; the rollback order is `deleteWebhook`, then switch
`BUB_TELEGRAM_MODE=polling` with `--min-instances=1` and CPU throttling
disabled.

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
uv run bub mcp add \
  --transport http \
  --header "Authorization: Bearer ${LEDGER_AGENT_TOKEN}" \
  ledger \
  "${LEDGER_API_URL}/mcp"
uv run bub chat
```

`bub mcp add` stores the MCP definition in Bub's runtime config under
`~/.bub/mcp.json`; protect that file like any other credential-bearing client
configuration. Other MCP-capable agents can use the same URL and Authorization
header without installing the repository's Agent package.

The installed `bub-tapestore-sqlalchemy` plugin defaults to a local SQLite tape
database when `DATABASE_URL` is absent. The local process never receives the
remote Postgres URL or GitHub credentials. It also sends model requests through
`/api/agent/model`, so the actual provider, base URL, model name, and provider
API key remain in the remote instance's **实例运行配置**.
`BUB_MODEL=openai:ledger-agent` is the local alias for that OpenAI-compatible
proxy, not a second provider configuration.

### Local write access

Write tools appear only for a Token created with **允许写入工具**. They include
`ledger_append_transactions`, `ledger_update_transaction`,
`ledger_delete_transaction`, `ledger_reverse_transaction`,
`ledger_apply_account_operations`, and `ledger_upsert_memory`. There is no
separate approval surface. The system prompt requires the Agent to show the complete
pending Beancount change, end its reply, and wait for explicit confirmation in
the next user turn before calling a write tool. The write itself still goes
through schema validation, source revision checks, the server writer,
`bean-check`, commit, and rollback.
