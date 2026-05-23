# Raspberry Pi deployment

This repository deploys the Go API and the Vite frontend as separate release
streams on a Raspberry Pi self-hosted GitHub Actions runner. Real ledger data
still lives outside this public application repository and is selected with
`LEDGER_ROOT`.

## Target layout

Recommended layout on the Pi:

```text
/home/pi/beancount-ledger-web-deploy/
├── env/
│   ├── prod.env
│   └── preview.env
├── prod/
│   ├── backend/
│   │   ├── releases/<sha>/
│   │   ├── current -> releases/<sha>/
│   │   └── systemd.env
│   ├── frontend/
│   │   ├── releases/<sha>/
│   │   └── current -> releases/<sha>/
│   └── runtime/
└── preview/
    ├── backend/
    │   ├── releases/<sha>/      # contains examples/preview-ledger
    │   ├── current -> releases/<sha>/
    │   └── systemd.env
    ├── frontend/
    │   ├── releases/<sha>/
    │   └── current -> releases/<sha>/
    └── runtime/

/home/pi/beancount-ledger/          # private production ledger repo
```

The backend release owns the Go binary, `.agents/`, example ledgers, runtime
configuration, and the systemd service. The frontend release owns only the Vite
`dist/` output and can be updated without restarting the API.

## GitHub runner

Install a self-hosted runner on the Raspberry Pi and add the label:

```text
raspberry-pi
```

Backend artifacts are built on GitHub-hosted ARM64 runners so the binary matches
the Pi. Frontend artifacts are static and build on Ubuntu x64.

## Environment files

Create Pi-side env files:

```bash
mkdir -p ~/beancount-ledger-web-deploy/env
nano ~/beancount-ledger-web-deploy/env/prod.env
nano ~/beancount-ledger-web-deploy/env/preview.env
chmod 600 ~/beancount-ledger-web-deploy/env/*.env
```

Example `prod.env`:

```bash
LEDGER_ROOT=/home/pi/beancount-ledger
RUNTIME_DIR=/home/pi/beancount-ledger-web-deploy/prod/runtime
AUTH_SECRET=replace-with-openssl-rand-base64-32
APP_PASSWORD=replace-with-long-password

LEDGER_AI_PROVIDER=deepseek
DEEPSEEK_API_KEY=
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-chat

WEB_PUSH_VAPID_PUBLIC_KEY=
WEB_PUSH_VAPID_PRIVATE_KEY=
WEB_PUSH_SUBJECT=mailto:you@example.com

BEAN_CHECK_BIN=/home/pi/.local/bin/bean-check
LEDGER_GIT_AUTHOR_NAME=Your Name
LEDGER_GIT_AUTHOR_EMAIL=you@example.com
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```

Preview uses the sanitized ledger packaged with the backend artifact. The
backend deploy script forces preview to `backend/current/examples/preview-ledger`,
initializes it as a local Git repository, disables remote sync, and enables
`LEDGER_AUTH_DISABLED=true`.

## GitHub secrets

Configure these Actions secrets:

```text
RASPI_DEPLOY_BASE=/home/pi/beancount-ledger-web-deploy
RASPI_PROD_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/prod.env
RASPI_PREVIEW_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/preview.env
RASPI_FRONTEND_RELOAD_COMMAND=
```

`RASPI_FRONTEND_RELOAD_COMMAND` is optional. It can stay empty when the Go
service owns the public port and serves the frontend symlink directly.

## GitHub variables

Configure Actions variables:

```text
PRODUCTION_URL=https://your-production-domain.example
PREVIEW_URL=https://your-preview-domain.example
RASPI_PROD_PORT=3001
RASPI_PREVIEW_PORT=3002
```

These ports are the public app ports already routed from the outside world. The
split deployment keeps using them; the backend deploy script stops the legacy
`beancount-web-*` service before starting the new `beancount-ledger-api-*`
service on the same port.

## Backend systemd services

The backend deploy script writes and restarts these services automatically:

```text
beancount-ledger-api-prod.service
beancount-ledger-api-preview.service
```

The generated service runs the Go binary on the existing public app port with
`STATIC_DIR=<deploy-base>/<env>/frontend/current/dist` and `SERVE_STATIC=true`.
The frontend artifact is still deployed independently; the backend reads the
stable frontend symlink at request time.
By default, the service runs as the user executing the deploy script, with
`HOME` set to that user's home directory so Git can read the user's GitHub
credential helper configuration. Override with `SERVICE_USER` and
`SERVICE_GROUP` if your runner uses a different deployment user.

For production ledger commits, configure a Git author either in `prod.env` with
`LEDGER_GIT_AUTHOR_NAME` and `LEDGER_GIT_AUTHOR_EMAIL`, or directly in the
private ledger repository:

```bash
cd /home/pi/beancount-ledger
git config user.name "Your Name"
git config user.email "you@example.com"
```

## Public routing

Keep your existing public routing pointed at `RASPI_PROD_PORT` and
`RASPI_PREVIEW_PORT`. You do not need to expose a new backend-only port.

Example Nginx production server:

```nginx
server {
  listen 443 ssl http2;
  server_name ledger.example.com;

  location / {
    proxy_pass http://127.0.0.1:3001;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

Preview should proxy to the preview app port.

## Workflow behavior

- Push to `main` deploys production.
- Pull requests deploy preview when the PR is not a draft.
- Manual `workflow_dispatch` can deploy production or preview and can choose
  `all`, `backend`, or `frontend`.
- Changes under `server/**`, `examples/**`, `.agents/**`, `docker/**`, or the
  backend deploy script build and deploy only the backend.
- Changes under `web/**` or the frontend deploy script build and deploy only the
  frontend.
- Changes to the deploy workflow deploy both components.
- When both components changed, backend deploy completes before frontend deploy.

Each component keeps the latest five releases for quick manual rollback.
