# Main iOS Capacity Baseline

- Task ID: `20260922-main-capacity`.
- Status: completed (simulator measurement scope).
- Updated: 2026-09-22T17:33:00+08:00.
- Goal: assess current main using an authorized, isolated ledger copy and validated
  growth fixtures. The user deprioritized SQLite experimentation for this task.
- Acceptance completed: representative read/manual-write timings, observed
  capacity failures, conditional growth horizons, original-source hash verification,
  and removal of owned private input copies and the dedicated simulator.
- Baseline: `origin/main`, `0867241e14d0a7b98d9deb1300fdaec1ade436d4`, verified
  against the remote before and after testing. Release app-host tests used the
  actual embedded Python/Beancount and Go runtimes. Product sources are unchanged.
- Method: first/warm canonical load, first/cached bootstrap, dashboard, full-history
  transactions, BQL aggregation, concurrent readers, preview, durable confirmation,
  post-save reload, and sampled process footprint. Repeated steady runs are
  separated from initial simulator background initialization. Report sample counts
  and medians; no small-sample tail-latency guarantee.
- Fixtures preserve booked user-transaction, price, metadata and source-file
  structure, shifting cost dates with transaction dates. Existing accounts are
  retained. Generated padding, historical balance/pad/close/document assertions
  and future account/attachment growth are outside the replay model. Corrected
  fixtures pass uncached Beancount hardcore validation.
- An early replay exposed an empty-payee editable-entry decoding incompatibility
  when generated padding was materialized as source text. Corrected growth
  fixtures exclude generated padding. This issue is separate from capacity;
  production code remains unchanged.
- Observed hard boundaries reproduce the native dispatch's 16 MiB request and
  response limits (`server/mobilecore/dispatch.go`, `mobilecore.go`). Full-history
  response capacity and full-model request capacity are distinct. Record counts
  depend on actual content and metadata density.
- Private counts, timings, forecast and reproduction details are retained only
  under `$GIT_COMMON_DIR/agent-handoffs/20260922-main-capacity.md`, the associated
  private report/results, and code-only reproduction tools. No private content or
  derived measurements are included in this shared note.
- Validation boundary: physical iPhone, UI rendering, authentication, AI, network,
  sync and hosted-backend capacity were not measured. Simulator footprint cannot
  establish a phone's memory termination threshold. Existing IPA hosting remains
  unchanged.
- Changed files: this sanitized note only in the original checkout. The isolated
  temporary test probe was removed after its source was retained privately.
  No task PR, commit, push, merge or deployment. This note is local-only on
  `codex/ios-typed-response`; another clone cannot resume from it yet.
- Next recommendation: prioritize validation-only export overhead, full-history
  pagination and repeated full-model JSON transfer before a storage redesign.
  Preserve full canonical validation, manual confirmation and rollback. No
  remaining measurement or cleanup work in this task's approved scope.
