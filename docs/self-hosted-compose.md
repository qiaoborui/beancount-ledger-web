# Complete self-hosted Compose deployment

This deployment keeps the browser service, Postgres data, credentials, and
indexer on your Docker host. The ledger remains a private GitHub repository:
the API uses GitHub's Contents API for every read and write, and only the
indexer receives a local checkout to publish the Postgres read model. It uses
no public endpoint and no GitHub Action.

## Requirements

- Docker Compose v2
- A private GitHub repository. It may be empty; the onboarding Agent can create
  the initial Beancount files after installation.
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
LEDGER_UID=<$(id -u)>
LEDGER_GID=<$(id -g)>
```

Use `openssl rand -hex 32` for `POSTGRES_PASSWORD`. It is both high-entropy and
safe in Compose and PostgreSQL environment variables. `SELFHOST_IMAGE_TAG`
defaults to `latest`; pin it to a published commit tag for a repeatable update.

Start every required service with one command:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

Read the one-time installation code, then open `http://localhost:8080`:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml logs server
```

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
| `indexer` | Clones/fetches the ledger, validates and atomically publishes the read model every 60 seconds | dedicated local Git checkout + Postgres |
| `frontend` | Static React application | container image |
| `caddy` | Same-origin browser entrypoint | Caddy volumes |

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
```

`tls internal` requires installing Caddy's local CA certificate on each client.
Use a DNS name and Caddy's normal public-certificate flow instead when that is
appropriate. Do not bind port 80 to a LAN interface.

### HTTP-only LAN compatibility mode

The loopback default uses password-only, same-origin HTTP. If HTTPS is genuinely
unavailable on a trusted LAN, you may explicitly bind that HTTP port to the LAN
while keeping `LEDGER_AUTH_TRANSPORT=http`. The server then uses non-`Secure`
session cookies so standard browsers can log in over HTTP.

Do not use this mode on an untrusted network. It disables the secure-cookie
guarantee, cannot use passkeys/WebAuthn, and rejects configured cross-origin
cookie access. One hostname must use either HTTP mode or HTTPS mode, never
both, because an HTTP cookie can overwrite a Secure cookie with the same name.

## Backup and update

Stop the stack before a consistent backup. GitHub is the ledger backup/source
of truth; back up the indexer's disposable checkout only if you need a local
cache, and take a logical Postgres dump (not a raw copy of a live volume):

```bash
set -a; . ./.env.selfhost; set +a
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
tar -C "$(dirname "$LEDGER_CHECKOUT_HOST_PATH")" -czf ledger-checkout-backup.tgz "$(basename "$LEDGER_CHECKOUT_HOST_PATH")"
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d database
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database \
  pg_dump -Fc -U ledger -d ledger > postgres-backup.dump
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
```

Keep the exact `AUTH_SECRET` with the backup. Restored encrypted GitHub and AI
credentials cannot be decrypted with a different value.

To restore, keep a copy of the failed database dump, restore the optional
checkout archive to `LEDGER_CHECKOUT_HOST_PATH`, bring up only `database`, then
replace the database before restoring its archive:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database dropdb -U ledger --if-exists ledger
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database createdb -U ledger ledger
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database pg_restore -U ledger -d ledger --clean --if-exists < postgres-backup.dump
```

Finally start the full stack. The indexer will fetch GitHub and replace the
active read-model snapshot from its checkout.

Check service health with:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml ps
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml logs --tail=100 server indexer
```

`docker compose ... ps` shows whether the indexer process is alive. Its
`/ready` endpoint requires a successful index and no current retry error.
Inspect `/health` from inside the indexer container for `firstIndexSucceeded`,
`lastError`, `lastSuccess`, `lastAttempt`, and retry count:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec indexer \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:3001/health').read().decode())"
```
