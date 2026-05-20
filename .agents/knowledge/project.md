# Project Knowledge

Beancount Ledger Web is a Next.js app for browsing and writing to a Beancount
ledger. The app is designed around a two-repository model:

- This repository stores application code, examples, docs, deployment scripts,
  and agent skills.
- A private ledger repository stores `main.bean`, account files, transactions,
  imports, runtime state, and real financial data.

The app reads the private ledger through `LEDGER_ROOT`. Runtime state goes under
`RUNTIME_DIR`. Local development defaults to `examples/minimal-ledger` when no
ledger root is configured.

Important implementation areas:

- `web/src/lib/beancountParser.ts`: Beancount parsing and summaries.
- `web/src/lib/assetAnalytics.ts`: net worth, credit card, and asset analytics.
- `web/src/lib/timeRange.ts`: shared week, month, quarter, year, all, and custom
  time-range helpers.
- `web/src/components/LedgerApp.tsx`: app-level routing, time controls, privacy
  state, data loading, and page composition.
- `web/src/components/ledger/hooks/useLedgerData.ts`: client data fetching and
  caching.
- `web/src/app/api/ledger/summary/route.ts`: summary, balances, net-worth
  history, and credit-card analytics API.

Deployment:

- CI runs on pushes to `main` and on pull requests.
- Pull requests trigger the Raspberry Pi workflow with the `preview` target when
  the PR is not a draft.
- The deploy workflow packages `.agents/` into the standalone artifact.

