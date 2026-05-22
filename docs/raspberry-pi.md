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
    ├── current -> releases/<sha>/   # contains examples/preview-ledger
    ├── runtime/
    └── systemd.env

/home/pi/beancount-ledger/              # private ledger repo for production
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
WEB_PUSH_VAPID_PRIVATE_KEY=
WEB_PUSH_SUBJECT=mailto:you@example.com

BEAN_CHECK_BIN=/home/pi/.local/bin/bean-check
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```

Preview uses the sanitized ledger packaged with the application artifact:

```bash
RUNTIME_DIR=/home/pi/beancount-ledger-web-deploy/preview/runtime
```

The deploy script forces preview to use `current/examples/preview-ledger`,
initializes that directory as a local Git repository, disables remote Git sync,
and writes tool paths such as `DOUBLE_ENTRY_GENERATOR_BIN` into `systemd.env`.

## GitHub Secrets

In the new application repository, configure Actions secrets:

```text
RASPI_DEPLOY_BASE=/home/pi/beancount-ledger-web-deploy
RASPI_PROD_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/prod.env
RASPI_PREVIEW_ENV_FILE=/home/pi/beancount-ledger-web-deploy/env/preview.env
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
- Production runtime reads/writes are directed by `LEDGER_ROOT` and `RUNTIME_DIR` from the Pi-side env file.
- Preview runtime uses `examples/preview-ledger` from the deployed release, so test data follows this repository's Git history and is reset on each preview deployment.
- Git sync APIs and scheduler operate on `LEDGER_ROOT`.
