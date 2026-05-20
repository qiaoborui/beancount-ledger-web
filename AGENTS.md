# Agent Instructions

This repository is a self-hosted Beancount Ledger Web app. It contains the public
application code, examples, docs, deployment scripts, and project agent skills.
Real ledger data should live in a separate private ledger repository configured
with `LEDGER_ROOT`.

## Project Shape

- `web/` is the Next.js application.
- `web/src/app/api/ledger/` contains ledger-facing API routes.
- `web/src/components/ledger/` contains the main product UI.
- `web/src/lib/` contains Beancount parsing, analytics, auth, git, cache, and
  runtime helpers.
- `.agents/skills/` contains domain skills for Beancount bookkeeping, insights,
  Alipay import, WeChat import, and Telegram-facing flows.
- `examples/` contains safe sample ledgers for local and CI use.

## Working Rules

- Do not commit private ledger data, `.env*` secrets, runtime state, passkey
  stores, or imported bill files.
- Prefer existing UI patterns and components before adding new abstractions.
- Keep code changes narrowly scoped to the requested behavior.
- Use structured parsers and existing ledger helpers instead of ad hoc string
  parsing where practical.
- Preserve unrelated worktree changes. Do not reset or revert user changes unless
  explicitly asked.
- Do not start the local dev server by default. Pull requests trigger the
  Raspberry Pi preview deployment workflow.

## Validation

From `web/`, run the smallest useful checks for the change:

```bash
npm run typecheck
npm run test
```

For build or deployment-sensitive changes, also run:

```bash
npm run build
```

The GitHub Actions CI runs typecheck, tests, audit, and build. Pull requests also
trigger a preview deployment through `.github/workflows/deploy-raspberry-pi.yml`.

## Agent4MD Memory

The project-level Agent4MD files live under `.agents/`:

- `.agents/config.yaml` declares the entrypoint, rules, knowledge, and skills.
- `.agents/rules/` contains durable working rules.
- `.agents/knowledge/` contains project context that agents can load as needed.
- `.agents/skills/` contains task-specific workflows.

