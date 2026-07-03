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
PUBLIC_ORIGIN=https://ledger.example.com
WEBAUTHN_RP_ID=ledger.example.com
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
pnpm install --frozen-lockfile
pnpm run typecheck
pnpm run test
pnpm run build
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
cd /opt/beancount-ledger-web/source/web && pnpm install --frozen-lockfile && pnpm run build
cd /opt/beancount-ledger-web/source/server
STATIC_DIR=../web/dist PORT=3000 go run ./cmd/ledger-web
```

## Ledger Git sync

If `LEDGER_ROOT` is a Git repository, the app can operate on that repository
through the Git API and optional scheduler. The application repository is not
modified by ledger Git operations.

```bash
LEDGER_GIT_AUTHOR_NAME=Your Name
LEDGER_GIT_AUTHOR_EMAIL=you@example.com
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```

Alternatively, set `user.name` and `user.email` in the private ledger
repository itself with `git config user.name "Your Name"` and
`git config user.email "you@example.com"`.

### Remote Git storage

For stateless container hosts, set `LEDGER_STORAGE=remote_git` instead of
mounting a persistent `LEDGER_ROOT`. The server clones the private ledger repo
into `LEDGER_GIT_WORKDIR/repo`, resets that checkout to the configured branch
before each write, runs `bean-check`, then commits and pushes successful writes.

```bash
LEDGER_STORAGE=remote_git
LEDGER_GIT_REMOTE=https://x-access-token:${LEDGER_GIT_TOKEN}@github.com/OWNER/private-ledger.git
LEDGER_GIT_BRANCH=main
LEDGER_GIT_WORKDIR=/tmp/beancount-ledger-web/ledger
LEDGER_GIT_AUTHOR_NAME=Ledger Bot
LEDGER_GIT_AUTHOR_EMAIL=ledger-bot@example.com
```

`RUNTIME_DIR` is separate from the ledger checkout. On stateless hosts, keep in
mind that passkeys, web push subscriptions, notifications, write locks, and
import preview files need persistent runtime-state handling.

### Postgres runtime store

Set `RUNTIME_STORE=postgres` to persist small runtime state in Postgres instead
of local JSON files under `RUNTIME_DIR`. This covers passkeys, web push
subscriptions, notifications, and the advisory lock used to serialize remote Git
ledger writes. Import preview metadata and uploaded/generated import files also
use Postgres by default when `RUNTIME_STORE=postgres`.

```bash
RUNTIME_STORE=postgres
DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require
```

The app creates its `runtime_json` and `runtime_files` tables automatically. To
store runtime JSON in one backend and runtime files in another, set
`RUNTIME_FILE_STORE=filesystem` or `RUNTIME_FILE_STORE=postgres` explicitly.

### Vercel Docker deployment

Vercel can build the app from the root `Dockerfile.vercel`. Because the runtime
container is stateless, use remote Git ledger storage and Postgres-backed
runtime stores:

```bash
LEDGER_STORAGE=remote_git
LEDGER_GIT_REMOTE=https://x-access-token:${LEDGER_GIT_TOKEN}@github.com/OWNER/private-ledger.git
LEDGER_GIT_BRANCH=main
RUNTIME_STORE=postgres
RUNTIME_FILE_STORE=postgres
DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require
AUTH_SECRET=...
APP_PASSWORD=...
PUBLIC_ORIGIN=https://your-app.vercel.app
WEBAUTHN_RP_ID=your-app.vercel.app
LEDGER_GIT_SCHEDULER=false
```

When moving from a Vercel preview/production domain to a custom domain, passkeys
created under the old relying party ID cannot automatically become credentials
for an unrelated custom-domain relying party ID. To keep using the old RP ID
during migration, keep `WEBAUTHN_RP_ID` set to the original domain and list both
origins:

```bash
PUBLIC_ORIGIN=https://your-app.vercel.app
WEBAUTHN_RP_ID=your-app.vercel.app
WEBAUTHN_RP_ORIGINS=https://your-app.vercel.app,https://ledger.example.com
```

The app serves `/.well-known/webauthn` for WebAuthn related-origin requests so
supporting browsers can allow the custom domain to use that stable RP ID. For a
permanent custom-domain RP ID, sign in with the password and register a new
passkey after switching `PUBLIC_ORIGIN` and `WEBAUTHN_RP_ID` to the custom
domain.

Connect the Vercel project to GitHub and let Vercel create production
deployments from `main` and preview deployments for pull requests. GitHub
Actions only runs CI; Vercel should remain the deployment source of truth.
