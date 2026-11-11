# 20261111-hsbc-post-date-match

- Status: active
- Last updated: 2026-11-11 21:20 +08
- Branch: `codex/hsbc-post-date-match` (based on `main` @ 6ce9359e)

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

## Done (PR 1, backend)

- `server/internal/app/import_postdate_match.go`: matcher, fill writer, preview
  decoration, runtime persistence (`postdate-match` import file).
- Preview (`hsbchk-credit` only): `postDateFills` array, `entries[].duplicateHint`,
  a warning line with counts. Rebuilt previews carry the same data.
- Commit: `excludedPostDateFills` (fill ids) lets the client decline fills;
  response has `postDateFillCount`.
- Tests: `server/internal/app/import_postdate_match_test.go` (matcher cases,
  ambiguity, metadata insertion/idempotency, commit, exclusion, rollback, and an
  end-to-end preview → commit through real DEG generation).

## Remaining

1. PR 2: iOS `NativeImportFlowView` and web `ImportPage` show `postDateFills`
   (with per-fill opt-out) and highlight `duplicateHint` entries (default
   unchecked). Until then clients only see the warning line and all fills apply.
2. PR 3: historical backfill endpoint over archived `*hsbchk-credit*` CSVs under
   `transactions/*/documents/imports/`, preview then apply.
3. Optional: statement-period reconciliation by `post_date`.

## Validation

- `cd server && go build ./... && go test ./...` — pass on the branch head.
- Not tested: iOS/web UI (unchanged), GitHub API write mode against the preview
  environment.
