# Agent Instructions

This repository is the public application repository for a self-hosted
Beancount Ledger Web app. It contains the Next.js web app, safe example
ledgers, docs, deployment scripts, and project agent skills. Real financial
data belongs in a separate private ledger repository configured with
`LEDGER_ROOT`.

## Repository Model

- This repo is public application code: Web UI, API routes, examples, docs,
  Docker/deployment assets, helper scripts, and `.agents/` memory.
- A private ledger repo stores `main.bean`, account files, transaction files,
  imports, prices, budgets, runtime state, and any real financial data.
- The app reads the private ledger through `LEDGER_ROOT`.
- Runtime-only state belongs under `RUNTIME_DIR` and must not be committed.
  This includes passkey stores, notification state, web push subscriptions, and
  write locks.
- Local and CI-safe ledgers live under `examples/`.

## Project Shape

- `web/` is the Next.js 15 / React 19 application.
- `web/src/app/(ledger)/` contains the ledger pages: home, transactions,
  accounts, account detail, budgets, imports, income statement, net worth,
  reconcile, and settings.
- `web/src/app/api/ledger/` contains ledger-facing APIs for summaries,
  transactions, balances, accounts, append and append-batch writes, imports,
  budgets, insights, notifications, reconciliation, and version data.
- `web/src/app/api/auth/`, `web/src/app/api/passkey/`, and
  `web/src/app/api/push/` contain password auth, WebAuthn/passkey, and web push
  endpoints.
- `web/src/app/api/ai/` contains AI parse/chat endpoints for bookkeeping
  assistance.
- `web/src/app/api/git/` contains optional private-ledger Git status, pull, and
  commit routes.
- `web/src/components/ledger/` contains the main product UI, mobile sheets,
  pages, modals, notification center, transaction list, and shared ledger UI.
- `web/src/components/ledger/hooks/` contains client-side ledger data,
  mutation, auth, git status, privacy, network, route memory, pull-to-refresh,
  swipe, theme, toast, and web push hooks.
- `web/src/lib/` contains Beancount parsing, ledger writing, analytics, imports,
  auth, passkeys, git operations, cache, scheduler, notifications, AI provider,
  schemas, money, and path/runtime helpers.
- `scripts/` contains generic ledger helper scripts and deployment/install
  scripts.
- `docs/` contains privacy, ledger layout, self-hosting, and Raspberry Pi
  deployment documentation.
- `.github/workflows/ci.yml` runs typecheck, tests, audit, and build.
- `.github/workflows/deploy-raspberry-pi.yml` builds standalone artifacts and
  deploys production or PR preview environments.
- `.agents/` contains Agent4MD config, durable rules, project knowledge, and
  domain skills.

## Development Workflow

- For new feature development, create a focused branch first and open a pull
  request. Pull requests trigger the Raspberry Pi preview deployment workflow
  when the PR is not a draft.
- Use the `codex/` branch prefix by default unless the user asks for another
  naming convention.
- Keep PRs small and focused. Include validation results in the PR body when
  creating or updating a PR.
- When several dependent features must land serially, use Graphite stacked PRs
  to manage the chain instead of mixing the work into one large branch.
- Avoid starting the local dev server by default. Prefer the PR preview
  deployment path for UI validation unless the user explicitly asks for local
  runtime testing.
- Preserve unrelated worktree changes. Never reset, checkout, or revert user
  changes unless explicitly requested.

## Safety Rules

- Do not commit private ledger data, `.env*` secrets, runtime state, passkey
  stores, web push subscription stores, notification stores, imported bill
  files, or generated private-ledger artifacts.
- Keep financial writes manual-first: preview, validate, then append.
- Use existing Beancount parsers, ledger writers, analytics helpers, caches,
  schemas, and path helpers before introducing new parsing or write logic.
- Use `bean-check` validation paths where ledger writes are involved, and keep
  rollback behavior intact.
- Sensitive values must remain hidden until password or passkey unlock paths
  allow access.
- For UI work, follow the existing mobile-first product patterns in
  `web/src/components/ledger/` before adding new abstractions.
- Keep changes narrowly scoped to the requested behavior.

## Validation

Run the smallest useful checks for the change from `web/`:

```bash
npm run typecheck
npm run test
```

For build, deployment, Next.js config, dependency, or workflow-sensitive changes,
also run:

```bash
npm run build
```

CI uses Node.js 22, installs with `npm ci`, then runs typecheck, tests,
`npm audit --audit-level=high`, and build with `LEDGER_ROOT` pointed at
`examples/minimal-ledger`.

## Agent4MD Memory and Skills

The project-level Agent4MD entrypoint is this file. Supporting memory lives under
`.agents/`:

- `.agents/config.yaml` declares the entrypoint, validation commands, knowledge,
  rules, and skills directory.
- `.agents/rules/project.md` contains durable project rules.
- `.agents/knowledge/project.md` contains project context that agents can load
  as needed.
- `.agents/skills/alipay-bill-import/` supports Alipay CSV bill imports.
- `.agents/skills/wechat-bill-import/` supports WeChat Pay XLSX bill imports.
- `.agents/skills/beancount-bookkeeping/` supports manual-first bookkeeping
  drafts and appends.
- `.agents/skills/beancount-insights/` supports read-only ledger analysis.
- `.agents/skills/telegram-ledger-agent/` supports Telegram-facing ledger flows.

