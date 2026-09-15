# iOS local-first ledger architecture

## Implementation status

This document describes the target architecture and its incremental delivery.
The foundation provides a shared Go parser, a versioned mobile JSON boundary,
a standalone XCFramework build, Swift repository interfaces, and an app-private
generation store. The existing remote application remains the active UI path.

Local onboarding, the local repository implementation, embedded canonical
Beancount validation, SQLite reports, and provider synchronization are subsequent
deliverables. The generation store accepts an injected validator; callers must
wire the canonical validator before enabling financial writes in the product.
The lightweight Go compile API checks syntax and selected structural/balance
rules. Full booking, plugins, account lifecycle, and canonical validation belong
to the embedded Beancount runtime.

## Product decision

The target architecture supports an app-managed local Beancount workspace. SwiftUI reads
from a disposable local index, financial writes commit to local `.bean` files
after validation, and remote providers replicate committed revisions. The
existing HTTPS workspace remains available during migration.

The local workspace is the financial source of truth for the active device.
SQLite caches, Widget snapshots, search indexes, and sync queues are derived or
runtime state and can be rebuilt from a committed workspace generation.

## Runtime boundaries

```text
SwiftUI, App Intents
        |
        v
LedgerRepository
        |
        +-- RemoteLedgerRepository -> existing LedgerAPI
        |
        `-- LocalLedgerRepository
               |-- LocalLedgerWorkspace actor
               |-- LedgerCore XCFramework
               |-- embedded Beancount validator
               |-- disposable SQLite read model
               `-- LedgerSyncEngine -> provider adapters

Share extension -> App Group import inbox
Widget extension <- reduced App Group snapshot
```

Platform integration stays in Swift: file coordination, protected storage,
Keychain, background tasks, File Provider access, and Widget publication. The
portable Go core owns Beancount parsing, normalized ledger models, BQL,
analytics, import compilation, and write planning. The embedded Beancount
runtime performs canonical booking and validation in process.

The Swift/Go boundary uses versioned JSON request and response envelopes. This
keeps generated gomobile APIs small and makes server/mobile parity fixtures
easy to compare.

`ParseTextJSON` and `CompileTextJSON` accept `version`, `filename`, and `text`.
`CompileWorkspaceJSON` accepts `version`, `entrypoint`, and
`files: [{path, text}]`. It expands relative includes and sorted glob matches
within the supplied file set, loads each file once, and preserves original
filename/line diagnostics. Paths, include cycles, missing targets, and cumulative
resource limits return structured errors. The mobile input budget is 8 MiB of
JSON and 2 MiB of ledger text; larger ledgers need a later streaming/index design.

## On-device layout

Each configured ledger receives a stable UUID and an app-private directory:

```text
Application Support/Ledgers/<ledger-id>/
  generations/<revision-id>/workspace/
  generations/<revision-id>/revision.json
  generations/<revision-id>/.committed
  current.json
  index.sqlite
  sync.sqlite
  staging/
```

`current.json` identifies the committed generation. A write builds a sibling
generation, validates its complete include graph, and atomically replaces the
pointer after success. Readers pin one revision for the duration of an
operation. Failed and cancelled writes leave the previous generation current.

Writers hold a root-scoped file lock through staging, validation, and pointer
publication. A mutation supplies the revision observed during its preview;
the writer checks it after taking the lock. An empty expected revision denotes
a new workspace. Stale edits return a conflict before staging any changes.
Recovery acquires the same lock and re-reads the pointer before
repairing it. A post-publication marker identifies recovery candidates, and the
committed parent graph selects the head independently of wall-clock time.
Ambiguous or cyclic histories require repair. Readers use a scoped snapshot;
its directory is read-only by caller contract and stays within that operation.

Committed generations are retained until synchronization defines explicit
references for active readers, pending changes, and provider merge bases.
Abandoned staging directories are disposable. The initial implementation copies
the workspace for each write; clone-based copies and storage quotas need device
performance measurements before broad local-write rollout.

Workspace paths are normalized relative paths. Absolute paths, `..`
components, symlink traversal, and destinations outside the generation root are
rejected. External directory copies pin each ancestor with directory descriptors
and open children with `openat` and `O_NOFOLLOW`. The future Files onboarding
layer also owns security-scoped access, file coordination, and download readiness.
Workspace files and staging generations use complete iOS Data Protection.
Derived indexes must receive the same protection when implemented.
The initial workspace limits are 10,000 entries, 256 MiB per generation, and
32 path components; revision metadata is capped at 1 MiB. Committed history
uses additional disk space and requires an explicit future retention policy.

The full ledger remains in the main app container. The App Group contains only
the existing reduced Widget snapshot and Share Extension import inbox.

## Repository contract

LedgerSession talks to one repository selected by the active workspace. The
repository owns bootstrap reads, reports, imports,
transaction mutations, query history, locking, and refresh. Remote repository
methods delegate to the current HTTP API. Local repository methods use the
workspace, core, validator, and local runtime stores. Remote authentication,
quick-unlock credentials, and Gmail flows are separate capabilities. A typed
location identifies a remote origin or a local ledger UUID; repository lifetime
belongs to the active context.

Repository results retain the current `LedgerModels` data shapes while the
migration is active. This lets existing native screens move to local data
without a second presentation model.

## Local write transaction

1. The UI creates a confirmed mutation with a stable operation ID.
2. The workspace actor pins the current revision and creates a staging
   generation.
3. LedgerCore resolves stable transaction identity and prepares file changes.
4. The embedded Beancount runtime validates the complete staging ledger with
   hardcore validations.
5. The workspace atomically publishes the new generation and records a local
   revision.
6. The read model applies the new normalized snapshot and publishes Widget data.
7. The sync engine queues the committed revision for the configured provider.

App-created transactions carry `ledger_id` metadata containing a UUID. A
legacy transaction keeps its source path and content hash until its first
successful local edit, when it receives a stable ID. This identity survives
line movement and supports semantic conflict detection.

## Validation and plugins

iOS executes validation inside the app process. The packaged runtime calls
`beancount.loader.load_file` with hardcore validations and returns structured
filename, line, code, and message diagnostics.

The workspace scanner records every Beancount `plugin` directive before opening
a ledger for writes. Core Beancount modules and plugins bundled with the app are
writable. A workspace containing an unknown plugin opens read-only with an
actionable compatibility result. Existing committed files remain exportable and
syncable.

The runtime bundle contains Python, Beancount, required pure-Python packages,
and separately signed frameworks for binary extension modules. Release checks
verify every embedded framework in the exported IPA.

## Revision and sync semantics

Every provider implements three capabilities: fetch the remote head, publish a
new revision against an expected base revision, and return enough material for
conflict resolution. Provider credentials live in the device-only Keychain.

- GitHub publishes blobs, trees, commits, and a non-forced ref update against
  the expected SHA. A diverged ref creates a three-way merge request.
- iCloud Drive stores a coordinated versioned `.ledgerbundle` selected through
  Files. `NSFileCoordinator` and file versions expose concurrent changes.
- S3 stores client-encrypted immutable revision bundles plus a small manifest.
  Conditional ETag updates protect the manifest head.

Different-file changes merge automatically. Changes touching the same stable
transaction or global directive require review. Every merged generation passes
canonical validation before publication.

The UI reports local and remote state independently: committed locally,
syncing, synced, or conflict. Network availability never controls local commit
success.

## Delivery slices

1. Extract a portable Go parsing/core boundary and run the existing server
   through it with golden parity tests.
2. Add the repository boundary, local workspace generations, local validation,
   and read-only ledger opening while preserving remote mode.
3. Add validated local transaction mutations and revision recovery.
4. Add GitHub synchronization and native conflict review.
5. Move bill import compilation into the local core.
6. Add iCloud Drive and S3 provider adapters independently.

Each slice leaves a usable application and can merge separately. The first
local milestone is complete when a physical iPhone in airplane mode opens a
ledger, restarts with the same revision, and performs an add, edit, and delete
whose invalid candidates are rejected without changing the committed files.

## Verification gates

Foundation checks from the repository root:

```sh
(cd server && go test ./... && go build ./cmd/ledger-web)
swift test --package-path App/LedgerMobile
bash scripts/build-ledgercore-xcframework.sh
# With an already booted simulator:
bash scripts/test-ledgercore-simulator.sh <simulator-udid>
```

Select a full Xcode installation with `DEVELOPER_DIR` when the default developer
directory points to Command Line Tools. The standalone framework builder uses
Go 1.26 or newer, pins `golang.org/x/mobile`, and writes
`server/.build/ledgercore/LedgerCore.xcframework`. Its slices support iOS arm64
and iOS Simulator arm64/x86_64, with an iOS 17 deployment target. The generated
framework is an unsigned build input; application linking and archive signing
are part of the runtime integration slice. Source files and the build script
are committed; generated binaries remain local build artifacts.
The simulator smoke test links the generated Objective-C API and executes Go
parsing, balance checks, and include-aware diagnostics in the simulator runtime.

The following gates apply to the complete local product milestone:

- Golden fixtures produce equivalent normalized entries on the server and
  mobile core.
- Every local write passes valid, invalid, cancellation, crash-recovery, path
  traversal, symlink, and stale-base tests.
- Ten-times-size example ledgers meet the launch and mutation performance
  budget recorded by the test run.
- Widget and Share extensions retain reduced App Group access only.
- SideStore/iLoader renewal preserves the workspace, active revision, Widget
  namespace, and embedded framework signatures on a physical device.
- GitHub conflicts, iCloud conflict versions, and S3 ETag races preserve both
  revisions until the user resolves them.

## Distribution gate

Beancount is distributed under GPL-2.0-only. Shipping an embedded runtime
requires a compatible license decision for the linked iOS deliverable and a
complete source-availability path. This gate is resolved before an IPA that
contains Beancount is distributed.
