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
```

Start every required service with one command:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

Open `http://localhost:8080`. Docker keeps Postgres, runtime state, and Caddy
state in named volumes. The ledger stays in `LEDGER_HOST_PATH` and remains the
source of truth.

## Services

| Service | Role | Data location |
| --- | --- | --- |
| `database` | Postgres read model and runtime state | `postgres_data` volume |
| `server` | API, local ledger writes, `bean-check` rollback | mounted ledger + Postgres runtime state |
| `indexer` | Parses and publishes the read model every 60 seconds | read-only ledger mount |
| `frontend` | Static React application | container image |
| `caddy` | Same-origin browser entrypoint | Caddy volumes |

The indexer runs inside Compose. A local ledger edit becomes visible after the
next indexing interval. Ledger writes from the application validate through
`bean-check` before they persist.

## LAN and HTTPS

The default binds HTTP to the Docker host on port 8080. A home LAN can use a
stable hostname with an existing reverse proxy. Set `PUBLIC_ORIGIN`,
`WEBAUTHN_PUBLIC_ORIGIN`, and `WEBAUTHN_RP_ID` when enabling passkeys on that
hostname. Caddy can also manage a public certificate when the host has a domain
and ports 80 and 443 available.

## Backup and update

Back up `LEDGER_HOST_PATH` and the `postgres_data` volume. A ledger Git remote
provides an additional user-controlled copy. Upgrade with the same command
after pulling a newer application revision; Compose recreates services while
preserving named volumes.

Check service health with:

```bash
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml ps
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml logs --tail=100 server indexer
```
