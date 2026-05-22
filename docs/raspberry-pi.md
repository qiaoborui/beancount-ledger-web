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
RASPI_FRONTEND_RELOAD_COMMAND=sudo systemctl reload nginx
```

`RASPI_FRONTEND_RELOAD_COMMAND` is optional. It is useful when your reverse proxy
needs a reload after the frontend symlink changes.

## GitHub variables

Configure Actions variables:

```text
PRODUCTION_URL=https://your-production-domain.example
PREVIEW_URL=https://your-preview-domain.example
RASPI_PROD_BACKEND_PORT=3101
RASPI_PREVIEW_BACKEND_PORT=3102
```

If the backend port variables are omitted, production uses `3101` and preview
uses `3102`. The older `RASPI_PROD_PORT` and `RASPI_PREVIEW_PORT` variables are
intentionally ignored by the split deployment because those ports may still be
used by the legacy combined service or frontend preview.

## Backend systemd services

The backend deploy script writes and restarts these services automatically:

```text
beancount-ledger-api-prod.service
beancount-ledger-api-preview.service
```

The generated service runs the Go binary with `SERVE_STATIC=false`, so it only
serves API responses. Static HTML/CSS/JS comes from the frontend release through
your reverse proxy.

## Reverse proxy

Use Nginx, Caddy, or another HTTPS reverse proxy. Route `/api/` to the local Go
backend and everything else to the frontend release.

Example Nginx production server:

```nginx
server {
  listen 443 ssl http2;
  server_name ledger.example.com;

  root /home/pi/beancount-ledger-web-deploy/prod/frontend/current/dist;

  location /api/ {
    proxy_pass http://127.0.0.1:3101;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location / {
    try_files $uri $uri/ /index.html;
  }
}
```

Preview should use the preview frontend path and preview backend port.

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
