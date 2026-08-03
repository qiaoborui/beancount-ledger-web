# Complete self-hosted Compose deployment

This deployment keeps the ledger files, Postgres data, credentials, indexing,
and browser-facing service inside your own Docker host. It uses no public
endpoint and no GitHub Action.

## Requirements

- Docker Compose v2
- An existing Beancount ledger directory with `main.bean`
- A host directory with persistent storage for Docker volumes

## Start

From the application repository:

```bash
cp .env.selfhost.example .env.selfhost
```

Set these values in `.env.selfhost`:

```text
LEDGER_HOST_PATH=/absolute/path/to/your/ledger
POSTGRES_PASSWORD=<long random value>
AUTH_SECRET=<openssl rand -base64 32>
APP_PASSWORD=<your login password>
LEDGER_UID=<$(id -u)>
LEDGER_GID=<$(id -g)>
```

Start every required service with one command:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

Open `http://localhost:8080`. Docker keeps Postgres, runtime state, and Caddy
state in named volumes. The ledger stays in `LEDGER_HOST_PATH` and remains the
source of truth.

The server and indexer are non-root processes. `LEDGER_UID` and `LEDGER_GID`
must match the owner of the host ledger directory; this allows application
writes without making the bind mount world-writable. The API creates an empty
`.ledger-web.lock` advisory lock alongside `main.bean`. It serializes API
writes (including `bean-check` and rollback) with indexer reads; do not delete
it while the stack is running.

## Services

| Service | Role | Data location |
| --- | --- | --- |
| `database` | Postgres read model and runtime state | `postgres_data` volume |
| `server` | API, local ledger writes, `bean-check` rollback | mounted ledger + Postgres runtime state |
| `indexer` | Parses and atomically publishes the read model every 60 seconds | read-only ledger mount |
| `frontend` | Static React application | container image |
| `caddy` | Same-origin browser entrypoint | Caddy volumes |

The indexer runs inside Compose. It must complete one successful pass before
the API is considered healthy. A local ledger edit becomes visible after the
next indexing interval. Ledger writes from the application validate through
`bean-check` before they persist, and restore their exact file snapshots on a
validation failure.

## LAN and HTTPS

The default binds both mapped ports to `127.0.0.1`: HTTP on `8080` and HTTPS on
`8443`. It never exposes a plaintext login endpoint to the LAN.

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

## Backup and update

Stop the stack before a consistent backup. Back up the ledger directory and a
logical Postgres dump (not a raw copy of a live volume):

```bash
set -a; . ./.env.selfhost; set +a
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
tar -C "$(dirname "$LEDGER_HOST_PATH")" -czf ledger-backup.tgz "$(basename "$LEDGER_HOST_PATH")"
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d database
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec -T database \
  pg_dump -U ledger -d ledger > postgres-backup.sql
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml down
```

To restore, keep a copy of the failed ledger and SQL dump, restore the ledger
archive to `LEDGER_HOST_PATH`, bring up only `database`, then restore with
`psql -U ledger -d ledger < postgres-backup.sql`; finally start the full stack.
The indexer will replace the active read-model snapshot from the restored
ledger. A ledger Git remote remains a useful independent copy.

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
