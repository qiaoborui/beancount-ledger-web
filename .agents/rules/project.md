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

