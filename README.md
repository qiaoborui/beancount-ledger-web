# Beancount Ledger Web

A self-hosted Web UI for a personal [Beancount](https://beancount.github.io/) ledger, with transaction browsing, summaries, budget views, AI-assisted bookkeeping drafts, passkey unlock, web push notifications, and optional Git sync for your private ledger repository.

## Demo

<p align="center">
  <img src="docs/assets/demo/demo-01.png" alt="Demo screenshot 1" width="260" />
  <img src="docs/assets/demo/demo-02.png" alt="Demo screenshot 2" width="260" />
  <img src="docs/assets/demo/demo-03.png" alt="Demo screenshot 3" width="260" />
</p>
<p align="center">
  <img src="docs/assets/demo/demo-04.png" alt="Demo screenshot 4" width="260" />
  <img src="docs/assets/demo/demo-05.png" alt="Demo screenshot 5" width="260" />
  <img src="docs/assets/demo/demo-06.png" alt="Demo screenshot 6" width="260" />
</p>
<p align="center">
  <img src="docs/assets/demo/demo-07.png" alt="Demo screenshot 7" width="260" />
  <img src="docs/assets/demo/demo-08.png" alt="Demo screenshot 8" width="260" />
  <img src="docs/assets/demo/demo-09.png" alt="Demo screenshot 9" width="260" />
</p>

## Repository model

This project is designed for a **two-repository setup**:

1. **Application repository** — this public repo. It contains the Web app, generic scripts, examples, Docker/deployment files, and documentation.
2. **Ledger repository** — your private repo. It contains `main.bean`, `accounts.bean`, `transactions/`, budgets, prices, imports, and your real financial data.

```mermaid
graph LR
    A[Public app repo] --> B[Go API + Vite Web App]
    B -->|LEDGER_ROOT| C[Private Beancount ledger repo]
    B -->|RUNTIME_DIR| D[Runtime state]
    D --> E[passkeys]
    D --> F[notifications]
    D --> G[web push subscriptions]
```

The app never needs your ledger data to be committed to this repository.

## Features

- Beancount transaction list and account views
- Monthly income/expense summaries
- Budget reports from `custom "budget"` directives
- AI natural-language transaction parsing with preview-before-write
- Safe writes with `bean-check` validation and rollback
- Optional ledger Git status, pull, commit, and push
- Password login plus optional passkey / Face ID / Touch ID unlock
- Optional Web Push notifications
- Statement import previews for Alipay, WeChat Pay, CMB credit cards, CMB checking accounts, and CCB credit cards

## Quick start

```bash
git clone <this-repo-url> beancount-ledger-web
cd beancount-ledger-web/web
pnpm install
cp .env.example .env.local
pnpm run dev
```

By default, local development uses:

```text
../examples/minimal-ledger
```

Open:

```text
http://localhost:3000
```

## Use your private ledger

Clone or create your private ledger somewhere outside this app repository, for example:

```text
~/data/my-beancount-ledger/
├── main.bean
├── accounts.bean
├── commodities.bean
├── budgets.bean
├── prices.bean
└── transactions/
```

Then configure the Web app:

```bash
cd web
cat > .env.local <<'EOF'
LEDGER_ROOT=/absolute/path/to/my-beancount-ledger
RUNTIME_DIR=/absolute/path/to/beancount-ledger-runtime
AUTH_SECRET=replace-with-openssl-rand-base64-32
APP_PASSWORD=replace-with-a-long-password
PUBLIC_ORIGIN=http://localhost:3000
LEDGER_AI_PROVIDER=deepseek
DEEPSEEK_API_KEY=
LEDGER_GIT_AUTHOR_NAME=Your Name
LEDGER_GIT_AUTHOR_EMAIL=you@example.com
LEDGER_GIT_SCHEDULER=false
EOF
pnpm run dev
```

## Deployment

- [Self-hosting](docs/self-hosting.md)
- [Ubuntu server GitHub Actions deployment](docs/raspberry-pi.md)
- [Docker Compose example](docker/docker-compose.example.yml)

## Environment variables

See [web/.env.example](web/.env.example) for the complete list.

Important variables:

- `LEDGER_ROOT` — path to your private Beancount ledger repository. Defaults to `../examples/minimal-ledger` for local development.
- `RUNTIME_DIR` — path for runtime-only state such as passkeys, web push subscriptions, notifications, write locks, and import preview files when filesystem runtime stores are used. Defaults to `$LEDGER_ROOT/.runtime`.
- `APP_PASSWORD` — single-user login password.
- `AUTH_SECRET` — random secret for auth cookies.
- `PUBLIC_ORIGIN` / `WEBAUTHN_RP_ID` — public browser origin and passkey RP ID when served behind a proxy or custom domain.
- `BEAN_CHECK_BIN` — optional path to `bean-check` if it is not on `PATH`.
- `LEDGER_GIT_AUTHOR_NAME` / `LEDGER_GIT_AUTHOR_EMAIL` — optional Git commit identity for app-created ledger commits.
- `LEDGER_GIT_SCHEDULER` — set to `true` to periodically pull/commit/push the private ledger repo.
- `LEDGER_STORAGE=remote_git` — experimental stateless-host mode. The server clones `LEDGER_GIT_REMOTE` into `LEDGER_GIT_WORKDIR/repo`, runs `bean-check` in that temporary checkout, and commits/pushes every successful ledger write to `LEDGER_GIT_BRANCH`.
- `RUNTIME_STORE=postgres` / `DATABASE_URL` — optional runtime state backend for stateless hosts. Persists passkeys, web push subscriptions, notifications, remote-git write locks, and import preview metadata/files in Postgres instead of `RUNTIME_DIR`.
- `RUNTIME_FILE_STORE=filesystem|postgres` — optional override for runtime files such as import uploads and generated previews. Defaults to `RUNTIME_STORE`.

## Ledger layout

A compatible ledger should include at least:

```text
main.bean
accounts.bean
commodities.bean
budgets.bean
prices.bean
transactions/
```

`main.bean` should include the other files, for example:

```beancount
option "title" "My Beancount Ledger"
option "operating_currency" "CNY"

include "commodities.bean"
include "accounts.bean"
include "budgets.bean"
include "prices.bean"
include "transactions/2026.bean"
```

## Statement imports

The import flow keeps provider logic behind a small engine abstraction:

- DEG providers use `deg-module`: Alipay, WeChat Pay, and CMB credit card statements load the same YAML config files used by double-entry-generator.
- CMB checking-account CSV/PDF statements use the Web PDF adapter plus DEG's `cmb` provider through the `cmb-checking` import source.
- Native providers use the same Web preview, dedup, and commit flow with DEG-style YAML config: `ccb-credit` for CCB credit card email/HTML/CSV statements.

Ledger-side import files live under `$LEDGER_ROOT/imports/`. CMB checking import expects `imports/cmb-checking-config.yaml`; see [examples/preview-ledger/imports/cmb-checking-config.yaml](examples/preview-ledger/imports/cmb-checking-config.yaml) for the DEG `cmb` config shape. CCB credit card import expects `imports/ccb-credit-card-config.yaml` and accepts `.eml`, `.html`, `.htm`, or normalized `.csv` files. The `ccbCredit.paymentSourceHandledExternally` config controls prefixes such as `支付宝-`, `财付通-`, and `微信支付-` that should be filtered before generation to avoid duplicate platform-payment imports.

## Examples

- [examples/minimal-ledger](examples/minimal-ledger) — small English example for quick start and CI.
- [examples/chinese-personal-ledger](examples/chinese-personal-ledger) — anonymized Chinese personal finance template.

## Privacy and security

- Keep your real ledger in a private repository.
- Do not commit `.env`, runtime files, API keys, or passkey stores.
- Deploy behind HTTPS if using passkeys or exposing the app outside localhost.
- AI providers receive the text you ask them to parse plus account names needed for validation. Do not send sensitive text to an AI provider you do not trust.
- Writes are previewed first and validated with `bean-check` before being kept.

## Scripts

Generic helper scripts live in [scripts](scripts). They read the ledger path from `LEDGER_ROOT` or `BUB_LEDGER_ROOT`.

Examples:

```bash
LEDGER_ROOT=/path/to/private-ledger python3 scripts/bub_query.py summary 2026-01
LEDGER_ROOT=/path/to/private-ledger python3 scripts/budget_report.py 2026-01 --ledger /path/to/private-ledger/main.bean
```

## Development

```bash
cd web
pnpm install
pnpm run typecheck
pnpm run build
```

## License

Add your chosen open-source license in [LICENSE](LICENSE) before publishing.
