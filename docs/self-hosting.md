# Self-hosting

The recommended deployment uses Docker, either locally with Docker Compose or
on Vercel with the root `Dockerfile.vercel`. The Go service serves `/api/*` and
the built frontend from the same container port.

## Docker Compose (local)

The quickest local deployment uses the provided Docker Compose example:

```bash
cp docker/docker-compose.example.yml docker-compose.yml
# edit docker-compose.yml to set AUTH_SECRET, APP_PASSWORD, and volume paths
docker compose up -d
```

Your private ledger is mounted as a volume at `/ledger`, and runtime state
lives under `/runtime`. See [docker/docker-compose.example.yml](../docker/docker-compose.example.yml)
for the full configuration.

### Environment variables for Docker

```bash
LEDGER_ROOT=/ledger
RUNTIME_DIR=/runtime
AUTH_SECRET=...
APP_PASSWORD=...
PUBLIC_ORIGIN=https://ledger.example.com
WEBAUTHN_RP_ID=ledger.example.com
```

## Vercel

Vercel builds the app from the root `Dockerfile.vercel`. Because the runtime
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

Connect the Vercel project to GitHub and let Vercel create production
deployments from `main` and preview deployments for pull requests. GitHub
Actions runs CI only; Vercel is the deployment source of truth.

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

## Build and run from source

For development only, you can build and run directly without Docker:

```bash
cd web && pnpm install --frozen-lockfile && pnpm run build
cd ../server && go build -o ../ledger-web ./cmd/ledger-web
LEDGER_ROOT=../examples/minimal-ledger ./ledger-web
```
