# Self-hosting

## Directory layout

Recommended production layout:

```text
/opt/beancount-ledger-web/          # application deployment
/srv/beancount-ledger/              # private ledger repository
/srv/beancount-ledger-runtime/      # runtime state
```

Environment:

```bash
LEDGER_ROOT=/srv/beancount-ledger
RUNTIME_DIR=/srv/beancount-ledger-runtime
AUTH_SECRET=...
APP_PASSWORD=...
BEAN_CHECK_BIN=/path/to/bean-check
```

## Install Beancount

Install Beancount so `bean-check` is available to the Web service:

```bash
uv tool install beancount
```

If the service cannot find it, set `BEAN_CHECK_BIN` explicitly.

## Run with Node.js

```bash
cd /opt/beancount-ledger-web/web
npm ci
npm run build
npm run start
```

For public access, put the app behind a reverse proxy with HTTPS.

## Ledger Git sync

If `LEDGER_ROOT` is a Git repository, the app can operate on that repository through the Git API and optional scheduler. The application repository is not modified by ledger Git operations.

```bash
LEDGER_GIT_SCHEDULER=true
LEDGER_GIT_PULL_INTERVAL_MINUTES=15
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=60
```
