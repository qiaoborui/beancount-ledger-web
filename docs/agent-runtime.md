# Bub Agent runtime

The conversational Agent runs as a separate Python service built on
`bubbuild/bub` 0.4.1. Go and the React client depend only on the repository's
HTTP/SSE protocol, so the Agent implementation can be replaced without moving
ledger parsing or write safety out of the Go server.

```text
Browser -> Go API -> private Bub service -> Bub model client -> Go model proxy
                    |                 |
                    |                 +-> bub-tapestore-sqlalchemy -> Postgres
                    +-> signed capability -> Go ledger tools
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

Required Agent environment:

```text
DATABASE_URL=postgresql://...
LEDGER_API_URL=http://server:3000
AGENT_SERVICE_TOKEN=<shared internal secret>
BUB_MODEL=openai:ledger-agent
BUB_API_BASE=http://server:3000/api/internal/agent/model
BUB_API_KEY=<same shared internal secret>
```

`AGENT_SERVICE_URL` and `AGENT_SERVICE_TOKEN` configure the Go gateway. Hosted
deployments also set `AGENT_SERVICE_AUDIENCE` so Go obtains a Cloud Run OIDC
token. The Agent service is private and is not routed through Caddy.
