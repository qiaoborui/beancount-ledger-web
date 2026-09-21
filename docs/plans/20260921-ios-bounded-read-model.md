# iOS bounded read-model architecture

- Task: 20260921-ios-bounded-read-model; status: proposed, awaiting approval; updated 2026-09-21T17:50:41.961524+08:00.
- Evidence: dc24f33 on codex/ios-typed-response. Current localConfig uses files; canonical JSON is cached but spliced into every request, Go caches a full snapshot. Web LedgerIndexPort still exposes full/lite snapshots and is not a ready-made bounded-memory mobile interface. B1/B2 remove specific wasted serialization passes, not full-model storage.
- User goal: redesign to avoid huge in-memory JSON; SQLite/DuckDB/no database are options, not requirements. Recommend SQLite revision-local derived read models, not a wholesale accounting engine rewrite.

## Recommended architecture

Swift workspace/coordinator -> freeze candidate source -> Python canonical validation/booking/plugins -> bounded protected record stream -> Go index builder -> finalized SQLite artifact -> one atomic current manifest referencing matching source and index -> Go revision-bound query API -> bounded Swift response/page.

Responsibilities:
- .bean files remain the only authoritative financial source. SQLite is disposable and rebuildable, never synced as ledger truth.
- Python remains canonical semantic authority. Iterate booked entries only after validation; do not construct a second all-entry dictionary list, whole canonical JSON string, Swift JSON object graph or Go whole-ledger model. Export and ingestion execute sequentially so builder work need not overlap loader object lifetimes.
- Go owns schema, exact accounting operations and query planning. Swift owns publication, revision pins, lifecycle/unlock and UI paging. Do not implement competing Swift and Go accounting engines.
- Native SQLite C API is the preferred mobile adapter surface; actual gomobile/cgo linking and device packaging need to be verified in implementation, not assumed from host availability. Current build explicitly prunes Python sqlite3/_sqlite3: do not write a Python sqlite3-dependent design without packaging changes. Recommend keeping schema ownership in Go and using protected spool ingestion instead.
- No external service, cloud key, third-party account or network requirement for runtime indexing. No persistent server process.

## Data and memory boundaries

- First version uses immutable index-per-revision construction, not incremental booking or database row patches. Matching source/hash/entrypoint plus canonical exporter/runtime/plugin versions and schema version identify a valid index.
- Export stream consists of typed, length-bounded records (header, directives, transaction/postings, metadata, footer/count/digest). Per-record JSON is acceptable as a transitional encoding: no whole-file json.load/read, no array of all records, and never passes via Swift. Bytes and rows bound buffering, not rows alone. Later binary encoding is optional, not the architecture prerequisite.
- Proposed limits for approval: export records <=1MiB, batch <=1MiB and <=256 records; oversized records fail explicitly before publication, never silently truncate. Split transaction header/postings/metadata into records so an ordinary many-posting transaction does not require one huge record.
- API normal page default100/max500 with serialized page <=1MiB; cursors pin revision/date/stable ID. If a byte cap hits early return a continuation; oversized single detail needs explicit chunking/error, not truncation. Metadata/account lists/history/plots also require explicit limits. Existing globalTransactions consumers must move to paging or scoped queries; changing only storage is insufficient.
- Readers start with max2 read connections/one index builder. Proposed SQLite page cache8MiB per connection, mmap disabled initially, temp work on protected disk. These are tunable budgets, NOT a process-RSS guarantee. UI holds a bounded window rather than concatenating every page forever. Derived chart/summary cache keyed by revision+range+valuation currency, limited by entries AND bytes.
- Ordinary read path never calls canonicalModel, builds LedgerSnapshot or falls back silently to the legacy memory engine. Missing/broken/incompatible index produces explicit rebuilding/unavailable state; previous matched revision may be shown only with a stale indicator.
- Canonical load STILL has O(N) booked AST and intermediate memory. Incremental export only bounds additional memory; Python freeing references need not reduce resident memory immediately. If loader alone cannot fit supported devices, this proposal cannot solve offline write capacity: canonical engine redesign or explicit capacity limits would be separate decisions. No unsupported process isolation/multiprocessing promise on iOS.

## Schema and exactness requirements

Organize indexed entities by revision: source locations/hash, directives/accounts/commodities/options, transaction headers, ordered postings, exact quantities/costs/prices/lot identity, tags/links/typed metadata, prices, assertions, and bounded common account-period aggregates. Preserve booked plugin transformations and raw source references separately; detail/edit reads original source only when needed.

Use exact decimal strings or coefficient/scale with checked exact arithmetic. Do not use SQLite REAL/SUM(CAST(... AS REAL)) or assume all currencies are integer cents. Current canonical metadata converts some Decimal values to float: full exact metadata support requires a versioned export contract rather than pretending current export is universally lossless. Use existing Go exact accounting helpers where suitable. Aggregates must retain valuation/cost/period semantics; do not add nominal totals across currencies.

## Publication, failures and privacy

Existing preview then confirmation validation remains. Candidate index belongs to exact final confirmed source bytes. Construct outside published state, verify semantic/count checks and database integrity; complete SQLite transaction, close/finalize all necessary files and persist them before switching a single manifest. Do not separately flip current source and active database pointers. SQLite transaction atomicity alone does not make a separate filesystem manifest atomic.

Use rollback-journal build and closed standalone published DB initially; no live WAL-dependent artifact. Keep old generations while readers hold leases. Disk-full/cancel/crash/plugin validation failure must leave old manifest usable; clean unreferenced builds only after validating references. Source hash checks on import/reopen/sync/publication plus app-owned immutable generations; external edits cannot be treated as safe merely because UUID/mtime match. Avoid rescanning/hash of entire source on every routine query by controlling mutation paths and invalidating the revision explicitly.

All spool/DB/sidecar/temp-sort artifacts get app-private protection from creation, remain outside exported/synced ledger source, and are never logged or committed. Lock cancels/invalidates readers and suppresses stale responses; the final iOS data-protection class must remain aligned with existing foreground/background/Widget protection policy. Do not claim app sandbox equals encryption or that unlink securely erases flash.

## Query and compatibility strategy

New mobile-specific read port: revision info, paged transactions, detail, accounts/search, scoped exact balances, bounded time series and common report aggregates. Reuse Web revision/query semantics and accounting functions; do not adapt via ActiveSnapshot. Investments require exact lot/cost handling, not naive monthly cash sums.

BQL is not SQLite SQL or DuckDB SQL. Preserve current supported grammar/semantics via bounded indexed operators where possible; unsupported/resource-exceeding operations return explicit capability errors. Do not quietly rewrite meaning, remove BQL UI, or reconstruct full snapshots as a hidden fallback. Full BQL coverage and query working-set behavior are acceptance items, not assumed by choosing a database.

## Alternatives

- DuckDB is attractive for large analytical scans, but does not remove canonical peak memory or simplify selective mobile reads/BQL compatibility. Its documented larger-than-memory support and spill do not mean all allocations are bounded by memory_limit. Reconsider only if representative reports dominate measured work and device integration/memory wins are demonstrated.
- No-DB opaque model handle is a minimal mitigation for repeated JSON, but retains O(N) Go memory and cold rebuild. It fails the user's stronger bounded-read-memory objective.
- Custom mmap/binary indexes avoid a DB dependency but recreate indexes, cursor consistency, exact aggregation, corruption checks and migration machinery. Not recommended first.

## Delivery boundaries and validation

More than8 files across Python/C/Go/Swift/build/tests; significant architecture work, not another tiny serialization patch. Keep unchanged default engine until a coherent database path works.
1. Independently useful protected streaming export/import verification tooling; legacy app still functional, adds parity and memory evidence, not a hidden dependency on next phase.
2. End-to-end opt-in coherent source+index publication and paged transaction/detail vertical slice with explicit opt-in capability surface. Existing default app unaffected. No automatic mixed-revision/full-memory fallback inside new mode.
3. Cover all default screens, reports, editor/import prechecks, Widget and existing BQL capabilities through bounded reads; switch default only after parity/failure/scale gates pass. This integration may exceed a small PR and must remain behind the opt-in boundary until complete, rather than exposing a half-functional default.

Acceptance proposed: synthetic1k/10k/100k canonical golden results (multi-currency/cost/plugin/metadata), successful100k index+first page without16MiB whole-model request, no loader/full-snapshot calls on normal reads and reopen, bounded request/response/buffer counters, stable pagination across concurrent publication, malformed stream/oversized records, exact decimals, stale/corrupt index/rebuild, crash at every publication boundary, disk-full/cancel, lock/Widget races, source edits same size/mtime, upgrades/rollback. Profile loader/export/build/query separately. Physical-device read working-set plateau and write peak must be measured; no invented millisecond or RSS achievement.

Rollback: explicit selection of old engine for supported ledgers leaves .bean source intact; indices can be ignored/rebuilt. A100k ledger exceeding legacy caps does not magically become readable on old engine, so show explicit incompatibility/restore previous revision, never silently fall back. Existing financial revisions/backup not deleted.

## References and next decision

Official references consulted: https://www.sqlite.org/whentouse.html ; https://www.sqlite.org/atomiccommit.html ; https://www.sqlite.org/floatingpoint.html ; https://duckdb.org/docs/current/guides/performance/how_to_tune_workloads.html . Independent architecture review supports SQLite and flags snapshot-shaped APIs, exact arithmetic, publication and canonical-memory floor.

This document is a proposed architecture, not approved implementation instructions. Schema/query compatibility scope and device budgets need a focused implementation plan after the user agrees to the SQLite-derived-index direction. No code changed for this design. Existing private IPA download server remains active and untouched.

## Cross-agent handoff — 2026-09-21T17:55:58.237379+08:00

User requested committing and pushing this proposal so another agent can continue. This is authorization to publish the design, not evidence that SQLite is implemented or every proposed parameter is approved. Resume from branch `codex/ios-typed-response` (PR406), which includes B1/B2 optimizations and this proposal. Baseline application code revision covered is `dc24f3325acc27336f0cf4c3dbda035835b887cb`.

Next agent: read this plan and `docs/handoffs/20260921-ios-bounded-read-model.md`, compare current Git/PR state, then finalize the native SQLite adapter/build integration, versioned record/schema contract, query/BQL coverage and file-protection/publication semantics before implementation. Preserve unrelated changes and use focused stacked PRs. Do not require prior local metrics/private artifacts: they are not in a new clone; reproduce using the public synthetic generator. Do not assume any original private-ledger access or installed-device access is authorized for the new agent.
