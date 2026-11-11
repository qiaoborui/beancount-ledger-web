# 20261111-hsbc-post-date-match

- Status: active (all three PRs open, awaiting review/merge)
- Last updated: 2026-11-11 21:45 +08
- Branches: `codex/hsbc-post-date-match` (based on `main` @ 6ce9359e) -> `codex/hsbc-post-date-ui` -> `codex/hsbc-post-date-backfill`

## Goal

Alipay/WeChat are the primary record for HSBC HK credit-card purchases (readable
merchant and category); the HSBC CSV is the authority for the bank post date and
the billed amount. Importing the HSBC CSV must not duplicate purchases already
booked from Alipay/WeChat, and it should carry the post date onto them so
statement-period reconciliation by post date works.

## Decisions

- Matching lives in Go only (no separate Python script); the same matcher will
  serve the import path (PR 1) and a historical backfill (PR 2).
- Candidate bank rows: `status == POSTED`, have `post_date`, and are not already
  in the ledger as their own bank entry (an existing bank entry + an Alipay copy
  is a duplicate, not a backfill target).
- Candidate ledger entries: on the same liability account, no `post_date`, no
  `credit_or_debit` (i.e. not written by the bank importer).
- Window ±5 days, same sign and currency. Round 1 exact amount; round 2 only on
  leftovers on both sides, tolerance 0.50.
- Deterministic greedy ordering: amount diff → day diff → statement order →
  ledger order (no mixed-unit score).
- Exact unique pair → fill: the row leaves the import and `post_date` +
  `post_date_source` are inserted (key-sorted) into the existing entry in the
  same write transaction as the import; bean-check failure rolls both back.
- Exact but ambiguous pair (an equally good, non-interchangeable alternative) and
  tolerance pairs → `duplicateHint` on the preview entry; nothing is merged or
  dropped automatically.
- No `post-date-map.json` cache: `post_date_source` in the ledger is the audit
  trail; entries with `post_date` are skipped.

## PRs (stacked, plain branches; Graphite not installed)

1. #648 `codex/hsbc-post-date-match` -> `main`: matcher in the HSBC import
   preview/commit (`import_postdate_match.go`).
2. #649 `codex/hsbc-post-date-ui` -> PR 1 branch: iOS `NativeImportFlowView` and
   web `ImportPage` show `postDateFills` (per-fill opt-out, sent as
   `excludedPostDateFills`, kept in drafts) and `duplicateHint` entries (iOS:
   start unchecked; web: set aside with restore).
3. `codex/hsbc-post-date-backfill` -> PR 2 branch: historical backfill.
   - `POST /api/ledger/imports/post-date-backfill` (read-only scan) and
     `.../apply` (`{fillIds}`), also allowlisted in the local transport.
   - Scan regenerates every archived `hsbchk-credit` CSV with the importer,
     unions rows across overlapping statements (multiplicity kept within one
     statement), and reuses `unimportedPostDateRows` + `pairPostDateRows`.
   - Apply is stateless: it rescans and refuses if any selected fill id is no
     longer produced (ledger or statements changed, or already written).
   - `possibleDuplicates`: bank-imported entry + Alipay/WeChat/manual entry on
     the same card within 5 days and 0.50; listed only, never deleted; entries
     in such pairs are excluded from fills.
   - `post_date_source` for backfill fills is `hsbchk-credit:<sha256[:12]>` of
     the archived statement.
   - UI: web `PostDateBackfillPanel` (shown when an hsbchk-credit document is
     archived); iOS `PostDateBackfillView` from the import history page; local
     ledgers write through the change preview (`preparePostDateBackfill`).

## Remaining

1. Merge in order #648 -> #649 -> PR 3, retargeting each base to `main` after
   the one below it merges.
2. Release note needed (iOS embeds LedgerCore; new UI).
3. Optional: statement-period reconciliation by `post_date`.

## Validation (PR 3 head)

- `cd server && go build ./... && go test ./...` — pass.
- `cd web && pnpm run typecheck` — pass; `vitest run` under Node 24: 49 files,
  283 tests pass. (Node 26 locally fails `hooks/writeReliability.test.tsx`
  because of its built-in `localStorage`; unrelated, passes on Node 24.)
- `cd App/LedgerMobile && swift test` — 1037 tests, 0 failures.
- `xcodebuild -scheme LedgerMobile -destination 'generic/platform=iOS Simulator'`
  — BUILD SUCCEEDED.
- Not tested: interactive UI in a simulator/browser; GitHub API storage mode;
  real private-ledger data (deliberately not touched).
