# Complete self-hosted Compose deployment

This deployment keeps the browser service, Postgres data, credentials, and
indexer on your Docker host. The ledger remains a private GitHub repository:
the API uses GitHub's Contents API for every read and write, and only the
indexer receives a local checkout to publish the Postgres read model. The
runtime itself needs no public endpoint. Operators may build it locally, or use
the digest-pinned GitHub-hosted deployment described in
[headscale-local-cicd.md](headscale-local-cicd.md).

## Requirements

- Docker Compose v2
- A private GitHub repository with a default branch (initialize it with a
  README). It may omit `main.bean`; the onboarding Agent can create the initial
  Beancount files after installation.
- Two fine-grained GitHub tokens: API `Contents` read/write, indexer `Contents`
  read-only
- A host directory with persistent storage for Docker volumes

## Start

From the application repository:

```bash
cp .env.selfhost.example .env.selfhost
```

Set these values in `.env.selfhost`:

```text
LEDGER_CHECKOUT_HOST_PATH=/absolute/path/to/ledger-checkout
POSTGRES_PASSWORD=<long random value>
AUTH_SECRET=<openssl rand -base64 32>
INDEXER_IDENTITY_TOKEN=<openssl rand -base64 32>
AGENT_SERVICE_TOKEN=<openssl rand -base64 32>
LEDGER_UID=<$(id -u)>
LEDGER_GID=<$(id -g)>
```

To enable Bub's Telegram Channel, also set the BotFather token and restrict it
to known numeric user or chat IDs:

```text
BUB_TELEGRAM_TOKEN=<telegram bot token>
BUB_TELEGRAM_ALLOW_USERS=123456789
BUB_TELEGRAM_ALLOW_CHATS=123456789
```

Leave `BUB_TELEGRAM_TOKEN` empty to disable the Channel. Compose runs exactly
one `agent` container because Telegram permits only one long poller for a bot
token. Write confirmation is ordinary multi-turn conversation state and does
not require a paused tool call or resident Agent turn.

Compose keeps `BUB_TELEGRAM_MODE=polling` by default. Webhook mode is intended
for the hosted Cloud Run deployment where the public Go API receives Telegram's
webhook; a LAN self-hosted instance should keep polling.

Gmail bill import also defaults to outbound polling in this Compose deployment.
Set the optional `GMAIL_*` values in `.env.selfhost` (including
`GMAIL_CLIENT_ID`, `GMAIL_CLIENT_SECRET`, `GMAIL_OAUTH_REDIRECT_URL`,
`GMAIL_ALLOWED_SENDERS`, and `GMAIL_TOKEN_ENCRYPTION_KEY`), then connect Gmail
from `/import`. The Compose stack checks Gmail every two minutes by default;
set `GMAIL_POLL_INTERVAL` explicitly to override it. Keep
`GMAIL_DELIVERY_MODE=poll` for Tailnet/LAN deployments:
the server does not need a public Pub/Sub webhook or Cloud Scheduler. See
[gmail-import-automation.md](gmail-import-automation.md) for OAuth callback,
interval, and migration details.

Use `openssl rand -hex 32` for `POSTGRES_PASSWORD`. It is both high-entropy and
safe in Compose and PostgreSQL environment variables.

Start every required service with one command:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml config --quiet
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

The API now fails before opening its listener when filesystem/indexer-only
variables such as `LEDGER_ROOT`, `RUNTIME_DIR`, `BEAN_CHECK_BIN`, or
`INDEXER_CONFIG_URL` are accidentally assigned to it. The indexer separately
requires an existing absolute `LEDGER_ROOT`, its internal config URL, and its
identity token. This keeps each service's credential and filesystem boundary
explicit.

Local operator starts build from the checked-out source. The automated mibook
deployment instead publishes host-specific `linux/amd64` server and indexer
images with `LEDGER_UID=1000` and `LEDGER_GID=1000`, then deploys all four
application images by registry digest. Hosts with different IDs must keep using
the local build path or create a separately reviewed image profile.
`LEDGER_MAINTENANCE_MODE` and `LEDGER_INDEXER_STANDBY` are deployer-owned
transaction controls; do not set them in `.env.selfhost` or the production
operator runtime environment.

Read the one-time installation code, then open `http://localhost:8080`:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml logs server
```

If the log line has rotated away while installation is still incomplete, run
the recovery command from the Docker host:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec server \
  /app/ledger-selfhost recover-install-code
```

It prints a fresh one-time code, invalidates the previous code atomically, and
records `regenerate_install_code` with actor `operator_cli` in
`runtime_config_audit`. It refuses to run after setup is complete. There is no
HTTP reset endpoint, so installation authentication still requires control of
the self-hosted runtime and database credentials.

The installer asks for the administrator password, GitHub owner/repository/
branch, a Contents read/write Token for the API, a separate Contents read-only
Token for the indexer, and the Agent provider/base URL/model/API key. These
values are stored in Postgres. Passwords are bcrypt hashes; Tokens and AI keys
are encrypted with a key derived from `AUTH_SECRET` and are never returned by
the API. Later edits live under Settings -> Instance runtime.

Docker keeps Postgres, runtime configuration, and Caddy state in named volumes.
GitHub is the ledger source of truth. The indexer retrieves only its read-only
configuration from the API over the internal Compose network, clones the repo
into `LEDGER_CHECKOUT_HOST_PATH`, then fetches and fast-forwards it.

The indexer is a non-root process. `LEDGER_UID` and `LEDGER_GID` must match the
owner of its checkout directory. The API has no ledger bind mount and cannot
write host files. Keep the checkout dedicated to the indexer: it refuses a
dirty worktree rather than overwriting local edits.

## Services

| Service | Role | Data location |
| --- | --- | --- |
| `database` | Postgres read model and runtime state | `postgres_data` volume |
| `server` | API; GitHub API reads/writes, preview validation, commits | Postgres runtime state only |
| `agent` | Private Bub runtime and PostgreSQL conversation tapes; calls the Go MCP and model proxy | Postgres only; no ledger mount |
| `indexer` | Clones/fetches the ledger, validates and atomically publishes the read model every 60 seconds | dedicated local Git checkout + Postgres |
| `frontend` | Static React application | container image |
| `caddy` | Same-origin browser entrypoint; does not expose the Agent service | Caddy volumes |

The indexer runs inside Compose. `/api/health` stays healthy during installation
and index catch-up, while `/api/ready` becomes ready only after configuration
and the first successful index. Application writes and imports write a durable
Postgres index request and wake the local indexer through PostgreSQL
`LISTEN`/`NOTIFY`, so their GitHub commits are usually indexed immediately.
The configured interval remains a fallback for missed notifications and GitHub
commits made outside the application. The indexer runs `bean-check` before it
publishes a revision; a failed GitHub commit stays out of the active Postgres
read model. Application writes and imports keep their existing GitHub API
transaction, preview, and commit-conflict protection; the API never edits a
local checkout.

`/api/setup/status` reports the actual readiness phase: `setup_required`,
`indexing`, `indexer_error`, `indexer_unavailable`, `database_error`, or
`ready`. The browser never treats a failed status request as ready. The install
gate offers a retry and the public `/api/health` diagnostic, while Settings ->
Instance runtime shows the indexer's latest attempt, first-index state, and
sanitized error. Indexing problems do not block signing in because an empty
ledger on an initialized default branch may need the onboarding Agent to create
its first `main.bean` revision.

The browser connects to Bub through Go's Web Channel gateway. Telegram connects
directly to Bub's native Channel; both use the same stateless MCP ledger tools
and Go model proxy. For a laptop or workstation, create a revocable
Agent Token in Settings -> 本地 Agent 访问 and follow
`docs/agent-runtime.md`; no Postgres or GitHub credential is copied locally.

## LAN and HTTPS

The default binds HTTP on `127.0.0.1:8080`. The 443 container port is also
mapped to loopback (`127.0.0.1:8443`) for an explicit TLS setup, but Caddy does
not serve TLS until `CADDY_SITE_ADDRESS` and its TLS policy are configured. It
never exposes a plaintext login endpoint to the LAN.

For LAN use, keep `SELFHOST_HTTP_BIND_ADDRESS=127.0.0.1`, set only
`SELFHOST_HTTPS_BIND_ADDRESS=0.0.0.0` and `SELFHOST_HTTPS_PORT=443`, then give
Caddy an explicit HTTPS site address and TLS policy, for example:

```text
CADDY_SITE_ADDRESS=ledger.home.example
CADDY_TLS_DIRECTIVE=tls internal
LEDGER_AUTH_TRANSPORT=https
PUBLIC_ORIGIN=https://ledger.home.example
WEBAUTHN_PUBLIC_ORIGIN=https://ledger.home.example
WEBAUTHN_RP_ID=ledger.home.example
TRUST_PROXY_HEADERS=false
```

`tls internal` requires installing Caddy's local CA certificate on each client.
Use a DNS name and Caddy's normal public-certificate flow instead when that is
appropriate. Do not bind port 80 to a LAN interface.

HTTPS mode fails fast unless `PUBLIC_ORIGIN` is one exact external HTTPS origin
without a path, `WEBAUTHN_RP_ID` matches that host or a parent domain, and every
configured WebAuthn origin is HTTPS and belongs to the same RP ID. Caddy
preserves the browser host and sends `X-Forwarded-Proto`; do not enable
`TRUST_PROXY_HEADERS` merely because Caddy is present. Enable it only when a
trusted outer proxy must supply `X-Forwarded-Host`.

### HTTP-only LAN compatibility mode

The loopback default uses password-only, same-origin HTTP. If HTTPS is genuinely
unavailable on a trusted LAN, you may explicitly bind that HTTP port to the LAN
while keeping `LEDGER_AUTH_TRANSPORT=http`. The server then uses non-`Secure`
session cookies so standard browsers can log in over HTTP.

Do not use this mode on an untrusted network. It disables the secure-cookie
guarantee, cannot use passkeys/WebAuthn, and rejects configured cross-origin
cookie access. One hostname must use either HTTP mode or HTTPS mode, never
both, because an HTTP cookie can overwrite a Secure cookie with the same name.

## Backup, restore, and update

Stop the stack before a consistent backup. GitHub is the ledger backup/source
of truth; back up the indexer's disposable checkout only if you need a local
cache. The required recovery set is one logical Postgres dump plus the exact
`.env.selfhost` that was active when the dump was taken. Store that environment
file in an encrypted backup with mode `0600`; it contains `AUTH_SECRET` and
other infrastructure credentials. Do not put it in Git.

`AUTH_SECRET` and the Postgres dump are an inseparable pair. It encrypts the
GitHub and AI credentials held in Postgres, so generating a new value during
restore does not rotate those credentials; it makes them undecryptable.

Create the recovery set with:

```bash
set -a; . ./.env.selfhost; set +a
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d database
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database \
  pg_dump -Fc -U ledger -d ledger > postgres-backup.dump
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
install -m 600 .env.selfhost /path/to/encrypted-backup/.env.selfhost
# Optional disposable checkout cache:
tar -C "$(dirname "$LEDGER_CHECKOUT_HOST_PATH")" -czf ledger-checkout-backup.tgz "$(basename "$LEDGER_CHECKOUT_HOST_PATH")"
```

When `CADDY_TLS_DIRECTIVE=tls internal`, also back up the `caddy_data` volume.
It contains the private local CA whose certificate is trusted by your devices.
Losing it causes Caddy to create a different CA and every client must be
enrolled again. The `caddy_config` volume is rebuildable, but may be archived
with it for a complete edge-proxy snapshot.

To restore, first put the backed-up `.env.selfhost` back in place without
changing `AUTH_SECRET`. Restore the optional checkout archive to
`LEDGER_CHECKOUT_HOST_PATH`, bring up only `database`, then replace the database
before restoring its archive:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d database
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database dropdb -U ledger --if-exists ledger
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database createdb -U ledger ledger
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database pg_restore -U ledger -d ledger --clean --if-exists < postgres-backup.dump
```

Finally start the full stack. The indexer will fetch GitHub and replace the
active read-model snapshot from its checkout.

For a manual update, create the recovery set above and record the currently
checked-out commit. Then update the source, validate the rendered Compose
configuration, rebuild, and inspect both setup status and readiness:

```bash
git rev-parse HEAD
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml config --quiet
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
curl -fsS http://127.0.0.1:8080/api/setup/status
curl -fsS http://127.0.0.1:8080/api/ready
```

Do not generate a new `.env.selfhost` during an upgrade. If the new revision
cannot start, return to the recorded application commit while keeping the same
database and environment file. Restore Postgres only when a migration or data
change requires it; keep the failed-state dump before overwriting anything.

Check service health with:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml ps
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml logs --tail=100 server agent indexer
```

`docker compose ... ps` shows whether the indexer process is alive. Its
`/ready` endpoint requires a successful index and no current retry error.
Inspect `/health` from inside the indexer container for `firstIndexSucceeded`,
`lastError`, `lastSuccess`, `lastAttempt`, and retry count:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec indexer \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:3001/health').read().decode())"
```
