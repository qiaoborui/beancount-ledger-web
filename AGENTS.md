# Agent Instructions

This repository is the public application repository for Beancount Ledger Web,
a self-hosted personal finance app built from a Go API/static server and a Vite
/ React 19 web client. It contains application code, safe example ledgers,
documentation, deployment assets, helper scripts, and project agent skills.
Real financial data belongs in a separate private ledger repository configured
through `LEDGER_ROOT`.

## Repository Model

- This repo is public application code: `web/`, `server/`, `examples/`,
  `docs/`, `docker/`, `scripts/`, `.github/`, and `.agents/`.
- A private ledger repo stores `main.bean`, account files, transaction files,
  imports, prices, budgets, and any real financial data.
- The server reads the private ledger through `LEDGER_ROOT`.
- Runtime-only state belongs under `RUNTIME_DIR` and must not be committed.
  This includes passkey stores, notification state, web push subscriptions, and
  write locks.
- Local and CI-safe ledgers live under `examples/`; use them for development,
  tests, docs, and previews.

## Project Shape

- `web/` is the Vite / React 19 app. Scripts are defined in
  `web/package.json`: `npm run typecheck`, `npm run test`, and
  `npm run build`.
- `web/src/components/ledger/` contains the main product UI: pages, mobile
  sheets, modals, notification center, transaction list, command palette,
  import/reconcile flows, and shared ledger UI.
- `web/src/components/ledger/hooks/` contains client-side ledger data,
  mutations, auth, git status, privacy, network, route memory,
  pull-to-refresh, swipe, theme, toast, and web push hooks.
- `web/src/lib/` contains browser/client helpers such as schemas, money,
  time ranges, routing, fetch, and IndexedDB cache.
- `server/` is the Go API and static-file server. The module path and Go
  version live in `server/go.mod`.
- `server/cmd/ledger-web/` builds the server binary.
- `server/internal/app/` contains ledger APIs, auth, WebAuthn/passkey, web
  push, AI parse/chat, imports, notifications, Git operations, cache,
  scheduler, Beancount parsing, and safe ledger writing helpers.
- `examples/minimal-ledger/`, `examples/chinese-personal-ledger/`, and
  `examples/preview-ledger/` are safe sample ledgers.
- `scripts/` contains generic ledger helper scripts and deployment/install
  scripts. They must read external ledger paths from environment/config rather
  than assuming real data lives in this repo.
- `docs/` contains privacy, ledger layout, self-hosting, backend architecture,
  and Raspberry Pi deployment documentation.
- `docker/` contains container/deployment examples.
- `.github/workflows/ci.yml` runs selective backend and frontend checks.
- `.github/workflows/deploy-raspberry-pi.yml` builds deploy artifacts and PR
  preview environments.
- `.agents/` contains Agent4MD config, durable rules, project knowledge, and
  domain skills.

## Development Workflow

- For new feature development, create a focused branch first and open a pull
  request. Use the `codex/` branch prefix by default unless the user asks for a
  different naming convention.
- Keep PRs small and focused. Include validation results in the PR body when
  creating or updating a PR.
- Pull requests trigger the Raspberry Pi preview deployment workflow when the
  PR is not a draft.
- When several dependent features must land serially, use Graphite stacked PRs
  instead of mixing the work into one large branch.
- Avoid starting the local dev server by default. Prefer static checks, tests,
  builds, or PR preview deployment unless the user explicitly asks for local
  runtime testing.
- Preserve unrelated worktree changes. Never reset, checkout, or revert user
  changes unless explicitly requested.

## Safety Rules

- Do not commit private ledger data, `.env*` secrets, runtime state, passkey
  stores, web push subscription stores, notification stores, imported bill
  files, or generated private-ledger artifacts.
- Keep private-ledger paths outside this repo. Root-level `main.bean`,
  `accounts.bean`, `budgets.bean`, `commodities.bean`, `prices.bean`,
  `transactions/`, `imports/`, and `ledgers/` are ignored for this reason.
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

Run the smallest useful checks for the change. For frontend changes, run from
`web/`:

```bash
npm run typecheck
npm run test
```

For build, dependency, deployment, or broad UI changes, also run from `web/`:

```bash
npm run build
```

For backend changes, run from `server/`:

```bash
go test ./...
go build ./cmd/ledger-web
```

CI uses Node.js 24 for the frontend job and the Go version declared in
`server/go.mod` for the backend job. The CI workflow selectively runs backend
checks for `server/`, `examples/`, `docker/`, and CI changes, and frontend
checks for `web/`, `docker/`, and CI changes.

## Agent4MD Memory and Skills

The project-level Agent4MD entrypoint is this file. Supporting memory lives
under `.agents/`:

- `.agents/config.yaml` declares this entrypoint, validation commands,
  knowledge files, rule files, and the skills directory.
- `.agents/rules/project.md` contains durable project rules.
- `.agents/knowledge/project.md` contains project context that agents can load
  as needed.
- `.agents/skills/alipay-bill-import/` supports Alipay CSV bill imports.
- `.agents/skills/wechat-bill-import/` supports WeChat Pay XLSX bill imports.
- `.agents/skills/beancount-bookkeeping/` supports manual-first bookkeeping
  drafts and appends.
- `.agents/skills/beancount-insights/` supports read-only ledger analysis.
- `.agents/skills/telegram-ledger-agent/` supports Telegram-facing ledger
  flows.

When a task matches one of these skills, read that skill's `SKILL.md` and use
its workflow. Keep context small by loading only the referenced files needed for
the current task.
