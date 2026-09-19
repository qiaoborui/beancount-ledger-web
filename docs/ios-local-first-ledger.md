# iOS local-first ledger architecture

## Implementation status

The production application is local-only. It provides an on-device ledger
library, creation and directory import, native browsing/search/reports/BQL,
transaction creation/editing/deletion, file editing/export, and local bill import.
All financial operations use the active device-private workspace. Persisted
legacy server preferences stay recoverable; production never instantiates their
remote repository or network client.

Local repositories invoke the existing Go application services through an
in-process JSON dispatcher. This transport opens no HTTP listener and has an
explicit endpoint allowlist with no cloud, AI, Git, authentication or push routes.
It uses app-private paths and ignores server environment configuration.
Mutations operate on staging generations; embedded CPython and the canonical
Beancount loader validate the complete workspace before atomic publication.
The lightweight parser APIs remain available for diagnostics, while product
financial writes use the canonical validator. Missing runtimes fail closed.

`LogicalLocalStorage` supplies the workspace, committed-revision notification,
status, synchronization, and conflict-resolution interfaces. Device storage and
HTTPS Git storage are implemented. Git uses an embedded pure-Go transport within
the app process, with default-on automatic synchronization and an immediate-sync
action. Foreground saves and network recovery trigger synchronization; iOS grants
background execution opportunities. SQLite indexing and iCloud/S3 provider
adapters remain future work. Reports reuse the Go read model against a pinned local generation.
Files/iCloud Drive sharing currently exports a snapshot. Gmail automation and
hosted ledger automation are outside the local-only product. Optional import
classification calls TypeSafe directly with a user-supplied key; ledger queries,
validation and writes continue to run entirely on the device.

## Product decision

The architecture uses an app-managed local Beancount workspace. SwiftUI reads
through the local repository, financial writes commit to local `.bean` files
after validation, and storage providers exchange committed revisions. Git is a
logical local storage provider whose network operations stay below that boundary.

The local workspace is the financial source of truth for the active device.
SQLite caches, Widget snapshots, search indexes, and sync queues are derived or
runtime state and can be rebuilt from a committed workspace generation.

## Runtime boundaries

```text
SwiftUI, App Intents
        |
        v
LocalLedgerRepository
        |-- LedgerCore XCFramework (queries/imports/write plans)
        |-- embedded Beancount validator
        `-- LogicalLocalStorage
               |-- DeviceLocalStorage -> LocalLedgerWorkspace
               `-- GitLocalStorage -> LocalLedgerWorkspace
                      `-- embedded Git transport -> HTTPS remote

Share extension -> App Group import inbox
Widget extension <- reduced App Group snapshot
```

Platform integration stays in Swift: file coordination, protected storage,
Keychain, background tasks, File Provider access, and Widget publication. The
portable Go core owns Beancount parsing, normalized ledger models, BQL,
analytics, import compilation, and write planning. The embedded Beancount
runtime performs canonical booking, plugin transformations, and validation in
process. Its versioned canonical snapshot supplies the Go financial read model;
the original parsed source supplies editor drafts and mutation locators. Derived
plugin entries without an original transaction remain read-only. The native
engine caches only the latest immutable generation model; mutable stages reload.

The Swift/Go boundary uses versioned JSON request and response envelopes. This
keeps generated gomobile APIs small and makes server/mobile parity fixtures
easy to compare.

`DispatchJSON` accepts a versioned request with workspace and runtime roots,
entrypoint, method, allowlisted API path, query and body. Swift owns the paths and
selects a managed generation for reads or a managed staging directory for writes.
Endpoint-compatible results populate existing native models. A staging success
is a proposal; canonical validation and workspace publication must still succeed.
Relative transaction source paths and content hashes survive generation moves.

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
  ledger.json
  sync/<git-configuration-id>/
    state.json
    repository.git/
    candidates/<attempt-id>/
  staging/
  runtime/imports/<import-id>/
  runtime/scratch/imports/<import-id>/
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

Import previews and extracted files live in runtime storage. A stage's runtime
sibling is removed before its ledger generation is published. Successful import
publication records an exact-ID cleanup intent; cleanup failures retain that
intent for retry while the financial commit stays successful. Failed validation
preserves the original preview for retry. Preview creation and cleanup share the
workspace write lock. Previews expire after 24 hours; maintenance on preview/write
operations and hourly opportunistic read maintenance remove expired app-owned
import directories and runtime siblings
left in committed generations by earlier development builds. Ledger workspaces
and committed revision history are retained.

Local requests validate the selected workspace and runtime tree plus their
managed ancestors. Unselected generations, sync candidates, and Git object
storage are outside this request scan. Runtime cleanup may remove a file during
validation; missing runtime descendants are tolerated while selected workspace
and ancestor checks remain strict.

Workspace paths are normalized relative paths. Absolute paths, `..`
components, symlink traversal, and destinations outside the generation root are
rejected. External directory copies pin each ancestor with directory descriptors
and open children with `openat` and `O_NOFOLLOW`. The future Files onboarding
layer also owns security-scoped access, file coordination, and download readiness.
Workspace files, staging generations, runtime state and Git caches use iOS
`completeUntilFirstUserAuthentication` protection. Git credentials use device-only
`AfterFirstUnlockThisDeviceOnly` Keychain accessibility. This explicitly permits
background synchronization while locked after the first device unlock following
reboot. Existing workspace attributes and credentials are prepared after a
successful foreground authentication before background authorization is recorded.
Face ID and privacy shielding continue to gate the app UI. Manual app locking or
leaving the ledger revokes background authorization until the next explicit unlock.
The initial workspace limits are 10,000 entries, 256 MiB per generation, and
32 path components; revision metadata is capped at 1 MiB. Committed history
uses additional disk space and requires an explicit future retention policy.

The full ledger remains in the main app container. The App Group contains only
the existing reduced Widget snapshot and Share Extension import inbox.

## Repository contract

LedgerSession talks to the local repository selected by the active workspace.
The repository owns bootstrap reads, reports, imports, transaction mutations,
query history, locking, and refresh, using the workspace, core, validator, and
local runtime stores. Production sets `localOnly: true` and refuses remote
locations before invoking any repository factory. Legacy remote implementations
remain reachable only through explicitly injected compatibility test composition.

Repository results retain the current `LedgerModels` data shapes while the
migration is active. This lets existing native screens move to local data
without a second presentation model.

Local mode uses device-owner authentication (biometrics with device passcode
fallback), privacy shielding, and per-ledger lock intervals. Authentication and
import completion recheck the session identity and foreground state before
activation. Preferences use a private `ledger-local://<UUID>` identity; that
identity is never sent to URLSession. Widget network credentials are suspended
when a local ledger becomes active, and only reduced local summaries are shared.

## Unified bookkeeping pipeline

The native inputs converge on a reviewable local change set:

```text
Natural language -> semantic parser (BYOK compatible API / future device parser)
Manual entry ----> exact structured records
Statements ------> existing engine extraction and source-aware deduplication
                           |
                           v
                BookkeepingDraft + source evidence
                           |
                Local candidates and confirmed history
                           |
                Optional account/classification provider
                (Jev today; protocol supports device models)
                           |
                Editable review of missing facts and proposals
                           |
                Existing local engine renders exact postings
                           |
.bean transaction text -> original-byte import, preserving comments/postings
                           |
                Private staged workspace + canonical Beancount validation
                           |
                PreparedBookkeepingChange: actual file diff + ledger revision
                           |
                User confirms -> revision check -> atomic local publication
                           |
                Optional storage synchronization
```

Whole-ledger directory imports keep their separate catalog import workflow and
never classify existing transactions. The `.bean` transaction-file route accepts
transaction directives and comments only; account declarations, includes, plugins
and configuration belong to the whole-ledger workflow. The native parser checks
the fragment and the canonical validator checks it in the destination ledger.
The exact UTF-8 fragment is stored in a content-addressed `.bean` file beside the
entrypoint and included from that entrypoint. Importing identical bytes again is
rejected. Users review possible semantic duplicates with different source text.

`BookkeepingSemanticParser` and `BookkeepingClassifier` are separate replaceable
capabilities. `BookkeepingPipeline` assembles account context and proposals outside
SwiftUI. `BookkeepingDraft` carries multiple transaction records, exact posting
strings, source fingerprint/location/original text, unresolved questions and
account proposals. Existing statement commit requests retain the engine's source
metadata, archive receipts and deduplication identity. Legacy statement summary
amounts remain display values; the new writer path requires exact posting strings.

### Natural language and manual entry

Open **Add transaction -> 用一句话记账**. Configure **语义解析设置** there or
in Settings with an HTTPS OpenAI-compatible base URL (including `/v1`), model
name and personal API Key. The endpoint must support `/chat/completions` and
`response_format: {"type":"json_object"}`. Each explicit **发送并解析** action
sends the entered text, captured reference date/timezone and account candidates
to that endpoint. There is no automatic cloud fallback or background parsing.
Keys use a separate unsynchronized, device-only, `WhenUnlocked` Keychain item.
Changing endpoint requires reentering the key. Redirects, embedded URL credentials,
queries and fragments are rejected; request and response bodies are bounded.

The semantic response describes source quantities and signed addition/subtraction
terms. Code verifies source tokens/spans and computes with checked Decimal
arithmetic. For a 128 purchase with 48 advanced for a colleague, postings become
80 expense, 48 receivable and -128 payment. The response cannot introduce an
invented numeric literal to balance the entry. Unknown accounts and missing facts
remain questions. Dates, accounts, amounts and currencies can be edited before
preview. Arabic decimal amounts are supported; Chinese number words and unsupported
cost/rate semantics require clarification or manual entry. Explicit review is
required even when the model output parses successfully.

The natural-language editor can explicitly request **补充账户建议** when the
ledger's Jev classification setting is enabled. Only unresolved accounts are sent
for candidate decisions; proposals remain separate until the user selects one.
Candidates respect economic role, account dates and currency. Each request can
include up to five confirmed history examples for that merchant. Input edits,
settings changes, privacy shielding, cancellation or ledger changes invalidate
in-flight results. Tests inject an offline classifier to verify provider independence.

### Optional Jev account classification

Open **Settings -> 智能分类**, save a personal TypeSafe key and enable the active
ledger. Statement review calls Jev automatically; natural-language account advice
requires its explicit button. The consent screen describes both uses. Keys are
excluded from ledger files, exports, Git, App Group and preferences. Removing the
key disables classification for every ledger on the device.

Statement classification supplies two independent `Choice` questions to
`https://api.typesafe.ai/v1/systemone`, model `jev-1.13.0`: category/counterpart
account and payment/receipt account. Transaction nature is a local description of
the selected posting roots and signs. Jev generates neither transaction text nor
tags. Source dates, exact posting amounts, currency, description, metadata and
existing tags are preserved. Complex/priced statement postings remain editable
for manual review. Generic per-posting decisions support split natural-language
drafts, with explicit acceptance of each account proposal.

Local statement history retrieval uses merchant, description and payment identity,
returning up to five confirmed examples on/before the transaction date. The
request contains the transaction facts, eligible account names/labels and selected
history. Original statements, attachments, balances, full ledger contents, source
paths and order IDs stay local. Natural-language account advice additionally
sends the entered description. The ephemeral cookie-free transport rejects
redirects. Full finite distributions, candidate membership, sums and the selected
maximum are checked. Up to 254 eligible candidates plus review are supported;
larger sets request manual selection instead of silently truncating coverage.

Unique card identities and established payment mappings can provide local funding
hints. Issuer, credit/debit and suffix constraints gate model funding results.
Generic payment channels alone never establish a bank-card identity. Statement
account autofill requires probability >= 0.95, confidence >= 0.9 and lead >= 0.2,
plus compatible posting roots/signs. These thresholds are review policies, not
measured accuracy guarantees. Manual edits win; stale answers are discarded.
Service failures retain the draft and existing suggestions.

### Prepared changes and validation

`LocalLedgerWorkspace.prepare` uses a private staging copy and the same local
writers/canonical validator as commit. It publishes no ledger revision. The
preview contains actual changed file bytes, source ledger revision and draft
revision. Repository-owned opaque tokens expire after 15 minutes, are bounded to
four retained previews (up to 64 MiB of changed bytes per preview), and are
single-use. Returning to editing discards a token. The financial preview shows
transaction text and attachments; internal write receipts remain bound to the
commit token.
Confirmation copies exactly those prepared bytes into a fresh stage, checks the
expected revision, validates again and atomically publishes. Inference runs before
workspace locking. Concurrent edits/sync require a fresh preview. Failures retain
the previous generation; original statement runtime is consumed only after a
successful import publication.

Run `BookkeepingPipelineTests`, `ImportClassificationTests`,
`LocalLedgerRepositoryTests`, `LocalLedgerWorkspaceTests`, `LedgerImportModelsTests`
and the native creation/import/settings UI tests. Synthetic integration tests use
the app-linked Go engine and canonical Python Beancount runtime, including split
entries, precision, original-byte import, rejected directives/duplicates, failed
validation and stale revisions. Transport tests use mocked model responses.
Live model quality and latency require consented data and working provider keys.

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
7. The storage provider records pending synchronization. Failure to record sync
   metadata leaves the successful local financial commit intact; status also
   derives pending changes from the current workspace revision.

App-created transactions carry `ledger_id` metadata containing a UUID. A
legacy transaction keeps its source path and content hash until its first
successful local edit, when it receives a stable ID. This identity survives
line movement and supports semantic conflict detection.

## Validation and plugins

iOS executes validation inside the app process. The packaged runtime calls
`beancount.loader.load_file` with hardcore validations and returns structured
filename, line, code, and message diagnostics.

The validator checks every Beancount `plugin` directive before executing plugins.
Only its explicit bundled safe-plugin allowlist is accepted. Unknown plugins,
external paths, and unsupported plugin configuration block import or publication
with a compatibility error; the original source folder remains unchanged.
Read-only opening of incompatible ledgers is future work. Canonical validation
and the Go read-side limits both pass before a generation can become current.

The runtime bundle contains Python, Beancount, required pure-Python packages,
statically registered Beancount/regex extensions, and separately signed frameworks
for Python standard-library binary extension modules. Release checks
verify every embedded framework in the exported IPA.

## Revision and sync semantics

Every provider implements three capabilities: fetch the remote head, publish a
new revision against an expected base revision, and return enough material for
conflict resolution. Provider credentials live in the device-only Keychain.

- Git fetches an explicitly selected HTTPS branch into a private bare cache and
  materializes immutable candidates. It merges files against the durable base,
  validates the whole candidate, then publishes a local generation. Push uses a
  non-forced expected-head update. Adding a Git ledger only reads the remote;
  automatic synchronization then handles saved revisions, foreground entry and
  network recovery. Users may pause automatic sync or request immediate sync.
- Future iCloud Drive storage uses a coordinated versioned `.ledgerbundle` selected through
  Files. `NSFileCoordinator` and file versions expose concurrent changes.
- Future S3 storage uses client-encrypted immutable revision bundles plus a small manifest.
  Conditional ETag updates protect the manifest head.

Different-file changes merge automatically. Divergent changes in the same file,
including edit/delete conflicts and structural path collisions, preserve both
versions for review. Users can export both versions and choose local or remote
for the listed conflicts. Resolution checks the originally observed local
revision and validates the complete candidate before committing locally. Every
merged generation passes canonical validation before publication. Transaction-
level semantic merging is future work.

The UI reports local and remote state independently: committed locally,
syncing, synced, or conflict. Network availability never controls local commit
success.

The foreground coordinator debounces saves by two seconds, polls for remote
changes every five minutes, serializes attempts and retries transient failures
with capped exponential backoff. Authentication/authorization errors and conflicts
persist a paused state until credentials or conflict choices are updated.
`BGProcessingTask` requests a network opportunity with an earliest start of fifteen
minutes; iOS controls actual execution. Expiration cancels the operation. No
fixed lock-screen refresh interval is promised.

After successful synchronization, the main app builds a reduced Widget snapshot
from local reports. Revision and active-ledger authorization checks reject mixed
or stale results before App Group publication and a WidgetKit reload request.
The Widget extension reads only that local snapshot; it creates no remote client
and stores no Git credentials. Web imports appear after the web deployment has
pushed the same Git branch and the phone receives a synchronization opportunity.

## Delivery slices

1. Extract a portable Go parsing/core boundary and run the existing server
   through it with golden parity tests.
2. Add the local-only repository composition, workspace generations, local
   validation, and ledger library.
3. Add validated local transaction mutations and revision recovery.
4. Add logical storage providers, embedded HTTPS Git, and native conflict review.
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
bash scripts/build-beancount-ios.sh
bash scripts/build-beancount-ios-smoke.sh
# With an already booted simulator:
bash scripts/test-ledgercore-simulator.sh <simulator-udid>
```

Select a full Xcode installation with `DEVELOPER_DIR` when the default developer
directory points to Command Line Tools. The standalone framework builder uses
Go 1.26 or newer, pins `golang.org/x/mobile`, and writes
`server/.build/ledgercore/LedgerCore.xcframework`. Its slices support iOS arm64
and iOS Simulator arm64/x86_64, with an iOS 17 deployment target. The generated
framework is a static build input linked by the app. Xcode also links the native
Beancount bridge, embeds Python, and packages/signs its standard-library extension
frameworks through `build-beancount-ios-resources.sh`. Source files and build
scripts are committed; generated binaries remain local build artifacts.
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

The current embedded runtime is for private local builds and device testing.
Beancount 3.2.3 declares GPL-2.0-only and its regex dependency declares
Apache-2.0 AND CNRI-Python. Those terms create an unresolved combined-binary
redistribution issue; general willingness to use GPL does not resolve it.
Public IPA redistribution stays gated pending compatible authorization or a
verified dependency/architecture change, a complete dependency-license audit,
and corresponding-source delivery. See `App/LedgerMobile/Runtime/THIRD_PARTY.md`
for pinned sources and bundled notices. Publishing source changes and reporting
private device test results must not be described as public binary release approval.
