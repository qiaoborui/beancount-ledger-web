# Immutable native SQLite read-index core

This is the host-tested storage/query foundation of phase 2 of the [bounded mobile plan](plans/20260921-ios-bounded-read-model.md), stacked on the [stream exporter/verifier](ios-bounded-stream.md). It is **not yet connected to the iOS application**, and does not switch the default engine or implement reports/BQL/accounting aggregates.

## API

Package `server/internal/readindex` exposes:

- `Build(ctx, stream, destination) (Manifest, error)`: exclusively create an immutable index from a fully verified bounded-v1 stream. The complete footer and EOF must pass before commit. Exact original record JSON is retained, including quantities, prices, lots, metadata and custom typed values. Indexes are created before ingestion, avoiding a post-build full sort.
- `OpenContext(ctx, path, expectedManifest) (*Index, error)`: validate schema before integrity checking, verify identity and stream records using bounded-memory replay, then retain one read-only connection. This costs O(stream size) on reopen, **not** canonical loading or a snapshot. `Open` is a non-cancellable convenience wrapper; mobile lifecycle code should use `OpenContext`.
- `Transactions(ctx, PageRequest)`: descending date/ID keyset paging, default 100/max 500 rows, revision-bound cursor, encoded envelope capped at 1 MiB.
- `Detail(ctx, id)`: exact directive/posting/metadata records capped at 1 MiB. Oversized detail returns an explicit resource-limit error; it does not truncate. `DetailRecords` provides bounded continuation pages for larger directives.
- `DetailRecords(ctx, DetailPageRequest)`: source-ordered raw records, default 100/max 500 and 1 MiB; operation/entry/revision-bound cursor. Chunking does not change the all-or-error `Detail` contract.
- `Close()`: serialized lifecycle termination. One serial owner/connection per Index; lock cancellation must also invalidate caller response tokens. Context cannot interrupt an arbitrary blocking input reader, and waiting on the Index mutex is not independently cancellable.

Keep the returned manifest private alongside the corresponding frozen source generation. It is a checksum/identity, not proof of source authenticity. The caller must prevent generation replacement or mutation while readers are active. The core does not publish the app's source/index manifest or manage reader leases.

## Native adapter and protection boundary

`server/internal/readindex/sqlite` links system `libsqlite3` with cgo. SQLite >=3.37 and native development headers are required. There are no new Go module dependencies. The package deliberately has no non-cgo fallback; existing application command builds remain independent of it until integration.

Main files require owner-only `0600`; Build uses a private `0700` directory, refuses overwrites and symlink ancestors, closes and synchronizes files/directories before success, and cleans its own partial generation on failure. Rollback journals use DELETE mode, synchronous FULL, an 8 MiB page-cache setting and disabled mmap. These settings and record/page limits are **not** a total process RSS bound or a power-loss proof.

Temporary disk spilling is **fail-closed**: a connection-local VFS denies temporary/transient/unnamed file opens instead of writing them to a global OS temp directory. This also applies to narrowly authorized integrity checking. No process-global SQLite temporary-directory setting is changed. The indexed queries/build work without temporary sorts; arbitrary sorts, aggregates and statements needing temporary storage may fail explicitly. This is not yet the planned protected-directory spill implementation.

POSIX permissions are not iOS data protection or encryption. Apple linkage, inherited file protection, journal/temp behavior and lock/background lifecycle require actual Apple builds/device tests before any app integration can be considered accepted.

## Verification

From `server/` with cgo and native SQLite installed:

```sh
go test ./internal/readindex/...
go test -race ./internal/readindex/...
go vet ./internal/readindex/...
READINDEX_SCALE=1 go test -run TestSynthetic100K -count=1 -v ./internal/readindex
```

The scale test incrementally builds and reopens a 100k-transaction synthetic index and visits all transactions through bounded pages; it does not first allocate all source records. Smaller tests cover exact values, many-posting oversized detail, envelope limits, malformed streams, missing/corrupt indices, revision cursors, exclusive creation, cancellation, failed synchronization and cleanup. Adapter tests cover copied/native value lifetimes, concurrent interruption, sanitization, integrity-check spill refusal and read-only reopening.

Linux tests, race tests, vet, the 100k test, full backend tests and server build passed for this milestone. No actual device memory/latency measurements, crash-at-every-boundary tests or hosted production writes were performed.

## Required continuation

1. Verify gomobile/cgo system SQLite linkage against device and simulator SDKs and add appropriate native link/package inputs.
2. Bridge Python stream export without a Swift JSON graph; set/verify protection before artifact creation.
3. Extend the existing immutable workspace publication to atomically reference matching source and index, with revision leases and cancellation/unlock tokens.
4. Add explicit opt-in bounded page/detail UI without mixed default-engine fallback, disable unsupported background/Widget work in that mode, and test lifecycle races.
5. Migrate all screens, reports, BQL, editor/import prechecks and Widgets; implement protected spill/remaining capabilities; pass golden/failure/privacy/physical-device gates before changing defaults.

These remaining steps are not implied complete by a successful host SQLite build.
