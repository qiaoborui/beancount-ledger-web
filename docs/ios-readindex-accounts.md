# Bounded account catalog and native balances

Schema 2 extends the [immutable read index](ios-readindex-core.md) with typed
canonical posting, account-event and price projections. Schema 1 fails closed;
explicitly rebuild the derived index. Source ledger files do not migrate.

Every projected field (including NULL versus empty text) is verified against
raw records on reopen. Inverse row counts reject extras. Build/replay retains
one record, not an account/posting collection. Exact raw quantity, cost, price,
lot date/label and flag values remain available; no rebooking or pad expansion.

## Bounded APIs

- `Accounts`: binary UTF-8 account-name keyset pages. Includes explicitly opened
  accounts, including closed accounts; does not synthesize posted-only names.
  Duplicate synthetic opens choose the first. `close_date` is the latest explicit
  close, not an as-of status. `open_id` locates metadata through `DetailRecords`.
- `AccountBalances`: required account filter, optional strict `[start,end)` pair,
  currency keyset pages, exact normalized decimal strings. Unknown/unposted
  accounts return empty; posted-only accounts can be queried. Zero sums remain.
  `basis` is always `native_nominal`: **not valuation, lot accounting, opening,
  running balance, or report parity**. Cursors bind operation, revision and filters.

Both enforce default 100/max 500 rows and 1 MiB response bytes. Indexed reads do
not require temporary sorts. A selected account's complete posting history may
be scanned; page-size limits do not establish constant latency.

The shared exact-decimal accumulator limits input/coefficient/alignment to 4096
digits and exponent magnitude to 1024. Additions are atomic on failure. Fractional
trailing zeros normalize before retained-state and final coefficient limits;
an intermediate overflow remains an explicit resource error even if later
postings could cancel it. No authoritative accumulation uses REAL, float or cents.

The opt-in Swift browser offers replace-only account and currency pages with
exact-string display. Native account identity is byte-exact UTF-8, not Swift's
canonical-equivalence equality; selection uses unique opening directive IDs.
The transport rejects duplicate IDs and mismatched identities. Legacy UI remains
unchanged. No market conversion, balance assertions, account activity or writes
are implied by this catalog/native-unit slice.

## Validation

Go1.25.10 full tests/build, serialized full race, scoped vet and both synthetic
100k regressions passed. Independent review found a decimal false resource-limit
case from obsolete fractional scale; fixed with unit and build/reopen regressions.
Swift review found Unicode identity and duplicate-ID acceptance issues; fixed.
49 Linux stub-harness tests passed repeatedly plus both-mode Apple-target parsing.
Real hosted Apple/package/native checks for this milestone remain required.
Full Go vet reports a pre-existing test-goroutine Fatalf finding outside this scope.
No private ledger, production or physical-device tests were performed.

## Native account activity and summary

`AccountSummary` and `AccountActivity` require exact account and currency filters
and optionally `[start,end)`. Summary returns current (all dates), opening,
closing and period change as exact strings. Activity groups repeated matching
postings per transaction in ascending canonical date/ID order, retains matched
zero-delta transactions, and reports exact changes/running balances plus the raw
directive/detail locator. Missing pairs return zeros/empty pages, without currency
inference. This remains `native_nominal`, not historical market valuation or
legacy cents-compatible account reports.

Cursor identities bind revision, operation, exact filters and a real transaction
boundary. Running prefixes are recomputed rather than trusting cursor amounts;
worst-case page latency is O(N), while retention stays bounded. Pages default100,
max500 and1MiB. Existing schema2 indexes avoid temporary sorts. ExactDecimal can
add validated accumulators directly, avoiding rejection when normalized wire
spelling includes an extra leading zero at the raw-input digit limit.

The experimental browser selects a currency, then displays summary and replace-only
activity pages on the same retained reader; activity rows open bounded detail
pages. Lock/selection clear dependent state. 62 Linux stub-harness tests and both
configuration parse checks passed; fresh hosted Apple/native tests remain the gate.
