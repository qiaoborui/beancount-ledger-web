# GitHub write validation performance

Every changed candidate runs a complete `bean-check` before commit. Validation
fetches the recursive Git tree at the transaction's immutable base tree SHA,
then walks the candidate include graph in breadth-first batches. Missing
contents download with the existing six-request limit. Every transaction uses
a fresh temporary directory, removed on success or failure.

A per-writer, memory-only LRU caches include contents by Git blob SHA (32 MiB,
512 entries maximum). The scope includes storage mode, API URL, owner/repository,
branch, ledger root and credentials. A scope change clears the cache; repeated
configuration refreshes preserve it. Candidate files have their own content
identities. An external edit, added or deleted wildcard match, and force push
are resolved from the new tree on every write. A truncated tree fails validation.
Documents get existence placeholders and their bytes stay outside this cache.
Symlink includes always resolve through the fixed-revision Contents API because
their tree SHA identifies link text; regular file contents use the SHA cache.

## CI merge prerequisite

The Backend job runs this explicit performance gate with Beancount 3.2.3:

```sh
cd server
LEDGER_VALIDATION_PERFORMANCE_REQUIRED=1 go test ./internal/app \
  -run '^TestGitHubWriteValidationLargeLedgerPerformance$' -count=1 -v
```

The fixture has 120 included files and 12,000 valid synthetic transactions.
Three consecutive file edits use a real validator and simulated GitHub endpoints.
Each content GET has 20 ms added latency, outside the server state mutex.
The timer includes the writer, validation and simulated commit round trip.

Required budgets:

- Cold write: at most 5 seconds, at most 121 content GETs, 2–6 simultaneous downloads.
- Each warm write: at most 2 seconds and one content GET for the edited file.
- All three edits must commit successfully; missing `bean-check` fails the gate.

These assertions are part of the Backend job and feed the existing CI Gate.
Additional regression tests exercise immutable revisions, changed includes,
cache isolation/eviction, and full validation after cache hits.

## Measured comparison

Local macOS arm64 measurements on 2026-09-12 used Go 1.27.1, Beancount 3.2.3,
the same fixture and the real validator.
The baseline was PR commit `d55e22a`, before caching and concurrent hydration.

| Scenario | Baseline | Optimized, five runs | Content GETs before → after |
| --- | --- | --- | --- |
| Cold write | 3.172 s | 0.826–0.892 s | 121 → 121 |
| Warm write | 3.148–3.187 s | 0.360–0.412 s | 121 → 1 |
| Three writes total | 9.507 s | median 1.607 s | 363 → 123 |

Cold download concurrency rose from one to six. Across ten warm observations,
the median was 0.373 s and nearest-rank p95 was 0.412 s. Repeat locally with
`-count=5`; CI logs the observed duration, content requests and concurrency.

These are controlled regression budgets for the stated workload. Real GitHub
latency, hosted CPU, cold instance startup, larger ledgers, custom plugins and
cache eviction affect deployed latency. Every write still fetches one complete
tree; tree transfer and full Beancount checking grow with repository/ledger size.
Instances each warm their own cache. The existing write timeout remains in force.
No private production ledger is used by this benchmark.

Structured write logs include `validation_elapsed`, `bean_check_elapsed`,
`validation_cache_hits`, `read_requests`, and `total_elapsed` for deployment
measurement.
