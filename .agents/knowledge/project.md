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

iOS app (the shipped product):

- `App/LedgerMobile/` is a local-first native SwiftUI app. It runs the Go engine
  and an embedded CPython Beancount validator in-process; no server is required.
- `project.yml` is the XcodeGen source of truth for the app, Widget, and Share
  targets. `LedgerMobile.xcodeproj` is generated.
- `Sources/LedgerSession.swift` owns observable state and mutations,
  `LocalLedgerRepository`/`LocalLedgerWorkspace` own staging and atomic
  publication, and `LedgerExternalRoute.swift` owns `ledger://` deep links.
- `App/LedgerMobile/README.md` is the build and device-install guide,
  `DESIGN.md` is the visual spec, and `FEATURE_PARITY.md` records what the app
  actually implements today.
- `App/LedgerMobile/project.yml` owns `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION`. The build number must advance for every shipped
  behavior change; see the "iOS App Version" section of `AGENTS.md`.

Deployment:

- CI runs on pushes to `main` and on pull requests.
- Pull requests trigger the Raspberry Pi workflow with the `preview` target when
  the PR is not a draft.
- The deploy workflow packages `.agents/` into the standalone artifact.

