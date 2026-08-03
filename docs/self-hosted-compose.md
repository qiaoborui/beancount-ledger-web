# Complete self-hosted Compose deployment

This deployment keeps the browser service, Postgres data, credentials, and
indexer on your Docker host. The ledger remains a private GitHub repository:
the API uses GitHub's Contents API for every read and write, and only the
indexer receives a local checkout to publish the Postgres read model. It uses
no public endpoint and no GitHub Action.

## Requirements

- Docker Compose v2
- A private GitHub Beancount repository with `main.bean`
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
APP_PASSWORD=<your login password>
LEDGER_UID=<$(id -u)>
LEDGER_GID=<$(id -g)>
LEDGER_GITHUB_OWNER=<owner>
LEDGER_GITHUB_REPO=<private-ledger-repo>
LEDGER_GITHUB_TOKEN=<contents-read-write-token>
LEDGER_GITHUB_INDEX_TOKEN=<contents-read-only-token>
LEDGER_GIT_REMOTE_URL=https://github.com/<owner>/<private-ledger-repo>.git
```

Use `openssl rand -hex 32` for `POSTGRES_PASSWORD`. It is both high-entropy and
safe in Compose and PostgreSQL environment variables. `SELFHOST_IMAGE_TAG`
defaults to `latest`; pin it to a published commit tag for a repeatable update.

Start every required service with one command:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

Open `http://localhost:8080`. Docker keeps Postgres, runtime state, and Caddy
state in named volumes. GitHub is the ledger source of truth. On its first
pass, the indexer clones `LEDGER_GIT_REMOTE_URL` into
`LEDGER_CHECKOUT_HOST_PATH`; subsequent passes fetch and fast-forward it.

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

The indexer runs inside Compose. It must complete one successful pass before
the API is considered healthy. A GitHub commit becomes visible after the next
indexing interval. Application writes and imports keep the existing GitHub API
transaction, preview, `bean-check` validation, and commit-conflict protection;
the API never edits a local checkout.

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
PUBLIC_ORIGIN=https://ledger.home.example
WEBAUTHN_PUBLIC_ORIGIN=https://ledger.home.example
WEBAUTHN_RP_ID=ledger.home.example
```

`tls internal` requires installing Caddy's local CA certificate on each client.
Use a DNS name and Caddy's normal public-certificate flow instead when that is
appropriate. Do not bind port 80 to a LAN interface.

### HTTP-only LAN compatibility mode

If HTTPS is genuinely unavailable, the app can run as a password-only,
same-origin HTTP service. This is an explicit deployment choice, not a
fallback: set `LEDGER_AUTH_TRANSPORT=http` and bind the HTTP port to the LAN.
The server then uses non-`Secure` session cookies so standard browsers can log
in over HTTP.

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

`docker compose ... ps` shows `indexer` healthy only after the first successful
index. Inspect `http://127.0.0.1:3001/health` from inside the indexer container
for `lastError`, `lastSuccess`, `lastAttempt`, and retry count:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec indexer \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:3001/health').read().decode())"
```
