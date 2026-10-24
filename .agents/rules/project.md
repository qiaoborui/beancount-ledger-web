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
- Do not change `MARKETING_VERSION` in a feature, fix, documentation, test, or
  CI PR. It is the release, declared by an annotated `v<MAJOR>.<MINOR>.<PATCH>`
  tag that collects however many PRs the batch needed. Say in the PR body that
  the change needs a release, for example `需要发版：新增 <capability>`.
- `CURRENT_PROJECT_VERSION` is the binary build number. Feature work leaves it
  alone; `scripts/build-ios-ipa.sh` advances it by one on every package, refuses
  to package without a release tag, and refuses when the tag and
  `MARKETING_VERSION` disagree. Commit the bump it leaves behind.
- Never reuse or lower a build number, never move a release tag, and never edit
  `MARKETING_VERSION` to match a tag retroactively; fix whichever side is wrong.
- Keep `App/LedgerMobile/FEATURE_PARITY.md` truthful: ship or remove a capability
  and the same change updates it. Never list planned work as available.

