# Self-hosting

The recommended production setup builds the Go API and the Vite frontend as
separate deployable artifacts while keeping one public app port. The Go service
serves `/api/*` and the latest frontend `dist/` symlink from the same port.

## Directory layout

Recommended production layout:

```text
/opt/beancount-ledger-web/backend/     # Go API releases
/opt/beancount-ledger-web/frontend/    # static frontend releases
/srv/beancount-ledger/                 # private ledger repository
/srv/beancount-ledger-runtime/         # runtime state
```

Environment for the backend service:

```bash
PORT=3001
STATIC_DIR=/opt/beancount-ledger-web/frontend/current/dist
SERVE_STATIC=true
LEDGER_ROOT=/srv/beancount-ledger
RUNTIME_DIR=/srv/beancount-ledger-runtime
AUTH_SECRET=...
APP_PASSWORD=...
BEAN_CHECK_BIN=/path/to/bean-check
```

Use the same port your public reverse proxy or router already exposes. The
frontend can still be deployed independently by updating `frontend/current`; the
Go process reads that stable symlink when serving static files.

## Install Beancount

Install Beancount so `bean-check` is available to the API service:

```bash
uv tool install beancount
```

If the service cannot find it, set `BEAN_CHECK_BIN` explicitly.

## Build and run the backend

```bash
cd /opt/beancount-ledger-web/source/server
go test ./...
go build -o /opt/beancount-ledger-web/backend/ledger-web ./cmd/ledger-web
PORT=3001 STATIC_DIR=/opt/beancount-ledger-web/frontend/current/dist SERVE_STATIC=true /opt/beancount-ledger-web/backend/ledger-web
```

For systemd, point `ExecStart` to the built binary and put the environment above
in an `EnvironmentFile`.

## Build and serve the frontend

```bash
cd /opt/beancount-ledger-web/source/web
npm ci
npm run typecheck
npm run test
npm run build
```

Publish the generated `web/dist` directory to the stable frontend release path,
for example `/opt/beancount-ledger-web/frontend/current/dist`.

## Public routing

Route public traffic to the Go service on the existing app port:

```nginx
location / {
  proxy_pass http://127.0.0.1:3001;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## Single-process compatibility

The Go binary can still serve `STATIC_DIR` when `SERVE_STATIC` is unset or true.
That mode is useful for Docker and small local deployments:

```bash
cd /opt/beancount-ledger-web/source/web && npm ci && npm run build
cd /opt/beancount-ledger-web/source/server
STATIC_DIR=../web/dist PORT=3000 go run ./cmd/ledger-web
```

## Ledger Git sync

If `LEDGER_ROOT` is a Git repository, the app can operate on that repository
through the Git API and optional scheduler. The application repository is not
modified by ledger Git operations.

```bash
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```
