# Raspberry Pi deployment

This repository includes a GitHub Actions workflow for deploying the application to a Raspberry Pi self-hosted runner while keeping your real ledger in a separate private repository on the Pi.

## Target layout

Recommended layout on the Pi:

```text
/home/pi/beancount-ledger-web-deploy/
├── prod/
│   ├── releases/
│   ├── current -> releases/<sha>/
│   ├── runtime/
│   └── systemd.env
└── preview/
    ├── releases/
    ├── current -> releases/<sha>/
    ├── runtime/
    └── systemd.env

/home/pi/beancount-ledger/              # private ledger repo for production
/home/pi/beancount-ledger-preview/      # optional private/copy ledger repo for preview
```

## GitHub runner

Install a self-hosted runner on the Raspberry Pi and add the label:

```text
raspberry-pi
```

The workflow builds on GitHub-hosted ARM64 and deploys the built artifact on the Pi.

## Environment files on the Pi

Create env files on the Pi, for example:

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
NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY=
WEB_PUSH_VAPID_PRIVATE_KEY=
WEB_PUSH_SUBJECT=mailto:you@example.com

BEAN_CHECK_BIN=/home/pi/.local/bin/bean-check
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```

Preview should use a separate ledger repo/copy to avoid writing test data into production:

```bash
LEDGER_ROOT=/home/pi/beancount-ledger-preview
RUNTIME_DIR=/home/pi/beancount-ledger-web-deploy/preview/runtime
```

## GitHub Secrets

In the new application repository, configure Actions secrets:

```text
RASPI_DEPLOY_BASE=/home/pi/beancount-ledger-web-deploy
RASPI_PROD_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/prod.env
RASPI_PREVIEW_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/preview.env
NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY=<your public VAPID key, optional>
```

## GitHub Variables

Configure Actions variables:

```text
PRODUCTION_URL=https://your-production-domain.example
PREVIEW_URL=https://your-preview-domain.example
RASPI_PROD_PORT=3001
RASPI_PREVIEW_PORT=3002
```

Ports default to `3001` and `3002` if omitted.

## systemd units

Create production service:

```ini
# /etc/systemd/system/beancount-web-prod.service
[Unit]
Description=Beancount Ledger Web production
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/beancount-ledger-web-deploy/prod/current
EnvironmentFile=/home/pi/beancount-ledger-web-deploy/prod/systemd.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Create preview service:

```ini
# /etc/systemd/system/beancount-web-preview.service
[Unit]
Description=Beancount Ledger Web preview
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/beancount-ledger-web-deploy/preview/current
EnvironmentFile=/home/pi/beancount-ledger-web-deploy/preview/systemd.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Enable them once after first deployment directories exist:

```bash
sudo systemctl daemon-reload
sudo systemctl enable beancount-web-prod
sudo systemctl enable beancount-web-preview
```

The deployment script restarts these services after each artifact deploy.

## Workflow behavior

- Push to `main` deploys production.
- Manual `workflow_dispatch` can deploy production or preview.
- The app artifact is built from this public application repo.
- Runtime reads/writes are directed by `LEDGER_ROOT` and `RUNTIME_DIR` from the Pi-side env file.
- Git sync APIs and scheduler operate on `LEDGER_ROOT`, not on the application repo.
