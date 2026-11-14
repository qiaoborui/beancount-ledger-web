# Project Rules

- Treat this repository as public application code. Real financial data belongs
  in a separate private ledger repository.
- Avoid local dev server startup unless the user asks for it. Use PR preview
  deployment as the default UI validation path.
- Keep financial writes manual-first: preview, validate, then append. The iOS
  ledger assistant follows its write policy (助手设置 → 写入账本): a change that
  passes validation is written at once as a revertible commit, while file
  deletions and large removals wait for a confirmation. Other write paths are
  unchanged.
- Sensitive data must remain hidden until the app's passkey or password unlock
  path grants access.
- Reuse existing time-range, cache, parser, analytics, and UI helpers whenever a
  change touches ledger data.
- For GitHub pull requests, use a focused branch and include validation results
  in the PR body.
- An iOS release is declared only by an annotated `v<MAJOR>.<MINOR>.<PATCH>` tag
  pushed on the commit to ship; the version comes from the tag and the build
  number is derived as `MAJOR*10000 + MINOR*100 + PATCH`. `MARKETING_VERSION`
  and `CURRENT_PROJECT_VERSION` in `project.yml` are local development values:
  no PR changes them for a release and nothing commits a build number. Say in
  the PR body that the change needs a release, for example
  `需要发版：新增 <capability>`.
- Never move or delete a release tag; fix a broken release with a new, higher
  tag. Pushing a tag publishes, so confirm with the maintainer first.
- Keep `App/LedgerMobile/FEATURE_PARITY.md` truthful: ship or remove a capability
  and the same change updates it. Never list planned work as available.

