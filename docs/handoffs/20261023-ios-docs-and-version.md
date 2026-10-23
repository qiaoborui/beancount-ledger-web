# 20261023-ios-docs-and-version

- Status: active (PR opening; branch `codex/ios-docs-and-version`)
- Last updated: 2026-10-23 19:20 +08:00
- Base: `main` @ `2f50051`

## Goal

The iOS app had reached feature completeness while its documentation kept
describing an earlier version and presented shipped features as "Planned". The
user also noticed the version number never moved (`0.1.0` build 36 across
dozens of builds). This task makes the documentation truthful and turns the
version bump into a durable project rule.

Acceptance:

1. `App/LedgerMobile/FEATURE_PARITY.md` states what the code actually does, with
   no planned work presented as available.
2. `App/LedgerMobile/README.md` contains no claim contradicted by the code.
3. The version-bump rule lives in `AGENTS.md` and in the Agent4MD memory files,
   so future agents (and future sessions) apply it automatically.

## Findings that drove the edit

Verified against the source, not against the old docs:

- `ReconciliationView.swift` (731 lines), `LocalLedgerFileEditor`, and
  `addLocalTransaction` / `updateTransaction` / `deleteTransaction` all exist.
  The parity table still listed them as `Planned`.
- The Agent row should not be in a local-only product at all: `docs/ios-local-first-ledger.md`
  excludes hosted ledger automation.
- `AccountsView.swift` has **no** keyword search. It has an
  `AccountFilterCategory` filter bar (全部/资金/信用/理财/应收) over expandable
  groups. README claimed search; DESIGN.md describes a search field with
  separate expansion state.
- README claimed "a floating bottom search control on iPhone and toolbar search
  on iPad on iOS 26 and later". The code has a quick search inside the
  transactions list (`transaction-quick-search`) and
  `.searchable(placement: .navigationBarDrawer)` on the global search page, with
  no iOS-26 search-placement branch.
- README called the AI features "hosted AI ... outside the product", which
  contradicts the shipped natural-language bookkeeping and Jev classification.
  They are network opt-ins that the user configures; all ledger work stays local.

## Shipped in this change

- **`FEATURE_PARITY.md` rewritten.** One status column, a source-of-truth
  pointer per row, a "Deliberately out of scope" table with the reason for each
  exclusion, a "Known gaps" section (Accounts search, the DESIGN.md/Accounts
  filter-bar contradiction, unopenable non-allowlisted ledgers, app-host tests
  outside CI), and an updated navigation section.
- **`README.md` corrected** in three places: the search/accounts paragraph, the
  plugin allowlist now names the read-only gap, and the AI paragraph now
  distinguishes network opt-in from the local ledger guarantee.
- **`AGENTS.md` gained an "iOS App Version" section.** `CURRENT_PROJECT_VERSION`
  bumps for every shipped behavior change; `MARKETING_VERSION` moves only for a
  notable release; both live in `App/LedgerMobile/project.yml` and cover the app,
  Widget, and Share targets; the PR body must state the new version; a
  documentation/test-only change does not bump. The section also records the
  `FEATURE_PARITY.md` maintenance rule.
- **`.agents/knowledge/project.md`** gained an iOS app section (source layout,
  where the three docs live, where the version lives).
- **`.agents/rules/project.md`** gained two durable rules mirroring the
  version and parity requirements.

## Decisions

- The version bump is **not** applied in this change. It touches documentation
  and agent instructions only, which the new rule explicitly exempts. Applying
  it here would contradict the rule shipped in the same commit.
- The `DESIGN.md` ↔ Accounts contradiction is recorded as a gap instead of
  silently editing either side. Deciding which one is correct is a product
  decision: either the filter bar is intended and the DESIGN sentence is stale,
  or the filter bar is unplanned work.
- Planned-work rows were removed rather than re-labelled, so no reader can
  mistake intent for availability.
- The readiness line about S3 ("remains future work") was dropped: iCloud Drive
  backups cover the need and S3 is now listed as out of scope.

## Validation

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test` in
  `App/LedgerMobile`: 21 tests in 2 suites passed. (The default
  `swift` on this machine is CommandLineTools and cannot build the package;
  set `DEVELOPER_DIR` first.)
- Relative markdown links in `README.md` and `FEATURE_PARITY.md` resolve
  (`DESIGN.md`, `Runtime/THIRD_PARTY.md`).
- Not run: the Xcode scheme tests and UI suite. No Swift source changed, so the
  app-host surface is untouched by this change.

## Remaining work (not part of this PR)

1. Decide the Accounts search question, then either implement the search field
   from `DESIGN.md` (with independent expansion state) or delete that sentence.
2. Add a simulator `xcodebuild test -only-testing:LedgerMobileTests` step to the
   iOS CI job so app-host tests stop depending on manual runs.
3. Read-only opening of ledgers whose plugins are not allowlisted, the one item
   `docs/ios-local-first-ledger.md` still calls future work.

## Next concrete action

Open the PR for this branch, state in the body that no version bump applies
(documentation-only) and quote the `swift test` result.
