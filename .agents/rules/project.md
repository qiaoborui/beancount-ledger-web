# Project Rules

- Treat this repository as public application code. Real financial data belongs
  in a separate private ledger repository.
- Avoid local dev server startup unless the user asks for it. Use PR preview
  deployment as the default UI validation path.
- Keep financial writes manual-first: preview, validate, then append.
- Sensitive data must remain hidden until the app's passkey or password unlock
  path grants access.
- Reuse existing time-range, cache, parser, analytics, and UI helpers whenever a
  change touches ledger data.
- For GitHub pull requests, use a focused branch and include validation results
  in the PR body.
- Compute the iOS version at the start of **every** iOS task: read
  `App/LedgerMobile/project.yml`'s `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION`, decide both values from the table in the "iOS App
  Version" section of `AGENTS.md`, and state the decision in the report and PR
  body even when it stays unchanged. Shipped behavior always advances the build
  number; a user-visible defect advances PATCH, a new capability advances MINOR.
- Keep `App/LedgerMobile/FEATURE_PARITY.md` truthful: ship or remove a capability
  and the same change updates it. Never list planned work as available.

