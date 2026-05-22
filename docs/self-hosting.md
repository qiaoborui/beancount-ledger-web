# Self-hosting

The recommended production setup runs the Go API and the Vite frontend as
separate deployable components behind an HTTPS reverse proxy.

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
PORT=3101
SERVE_STATIC=false
LEDGER_ROOT=/srv/beancount-ledger
RUNTIME_DIR=/srv/beancount-ledger-runtime
AUTH_SECRET=...
APP_PASSWORD=...
BEAN_CHECK_BIN=/path/to/bean-check
```

`SERVE_STATIC=false` makes the Go server return JSON 404 responses outside
`/api/*`. Keep the default static fallback only for local single-process runs,
Docker, or simple development deployments.

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
PORT=3101 SERVE_STATIC=false /opt/beancount-ledger-web/backend/ledger-web
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

Serve the generated `web/dist` directory with Nginx, Caddy, or another static
file server.

## Reverse proxy

Route API requests to the Go service and all other paths to the frontend SPA:

```nginx
root /opt/beancount-ledger-web/frontend/current/dist;

location /api/ {
  proxy_pass http://127.0.0.1:3101;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location / {
  try_files $uri $uri/ /index.html;
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
