# iOS local-engine baseline harness

This is opt-in measurement infrastructure, not a product optimization or a device performance gate. All ordinary test runs skip it. Never run it against a production app container or point its input at a live ledger. Use a disposable simulator and an external disposable fixture copy. The Swift harness makes further isolated copies before all writes; no app catalog is accessed.

## Reproduce a safe fixture

Use Python with Beancount 3.2.3 installed (matching the embedded runtime). The generator reads no private ledger and refuses destinations inside this repository or existing destinations:

```sh
python scripts/generate-ios-performance-fixture.py /tmp/ledger-perf-10k \
  --transactions 10000 --includes 120
python scripts/generate-ios-performance-fixture.py /tmp/ledger-perf-100k \
  --transactions 100000 --includes 1200
```

Generator smoke manifests: 10k canonical 3,325,774 bytes; 100k canonical 33,346,890 bytes. The earlier exploratory fixtures in the plan differ slightly in directive order/source metadata, so their byte totals differ; both exercise the same scale and capacity boundary. Do not claim byte-identical fixture reproduction across these versions.

These are deterministic, two-account CNY scaling fixtures, **not** the multi-currency/cost-lot workload proposed in the optimization plan. Includes are explicit: the current write-side source reader does not expand wildcard includes. An initial wildcard fixture passed read measurements but failed preview; do not count that as a completed write baseline. The generator declares CNY for the writer's commodity checks.

## Host Go layers

From `server/`, use new output filenames for every run:

```sh
LEDGER_PERF_DISPOSABLE_COPY=1 \
LEDGER_PERF_INPUT=/tmp/ledger-perf-10k/generations/initial/workspace \
LEDGER_PERF_CANONICAL=/tmp/ledger-perf-10k/canonical.json \
LEDGER_PERF_OUTPUT=/tmp/ledger-perf-10k/run-1.json \
go test ./mobilecore -run '^TestDisposablePerformanceBaseline$' -count=1
```

The input must have the generation/workspace structure above. `transport/*` measures direct local transport with a predecoded canonical model. `json_bridge/*` adds request decoding and response-envelope verification; the canonical payload is spliced as raw JSON, as in Swift. Neither measures Python, Swift, authentication, UI, or request construction. Three warmups precede 30 timed operations per phase. Allocation counts are process-wide bytes allocated per operation (including response verification), not RSS or peak memory. Run alone, without builds/profilers/other tests competing for CPU.

A canonical payload over 16 MiB takes a separate capacity check: it must receive `request.too_large`. A passing capacity check means **expected rejection**, not that the ledger is supported or its latency is acceptable. Response size has a separate 16 MiB limit.

## Release simulator app host

1. Follow `App/LedgerMobile/README.md` to regenerate the project and rebuild Go/Beancount frameworks from the revision being tested. Use a newly created, disposable simulator, never a personal simulator or physical phone with existing financial state.
2. Build tests in Release, including `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`:

   ```sh
   xcodebuild build-for-testing \
     -project App/LedgerMobile/LedgerMobile.xcodeproj -scheme LedgerMobile \
     -configuration Release -sdk iphonesimulator \
     -destination 'platform=iOS Simulator,id=<disposable-simulator-id>' \
     -derivedDataPath /tmp/ledger-perf-build \
     ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES
   ```

3. Copy the generated `.xctestrun` into a private temporary directory. Resolve its `__TESTROOT__` placeholders to the original build-products directory. In the `LedgerMobileTests.EnvironmentVariables` dictionary, set:
   - `LEDGER_PERF_DISPOSABLE_COPY=1`
   - `LEDGER_PERF_INPUT` to the external fixture workspace
   - `LEDGER_PERF_OUTPUT` to a **new** external JSON filename outside that workspace
4. Run only `LedgerMobileTests/LocalLedgerPerformanceBaselineTests`, via `xcodebuild test-without-building -xctestrun <copy> -destination ... -only-testing:LedgerMobileTests/LocalLedgerPerformanceBaselineTests -parallel-testing-enabled NO`. A separate invocation starts a fresh test process. The first sample is named `canonical_first_test_load`: it is cold interpreter initialization only when no previous work in that process has initialized it. It is not an OS cold-disk measurement.
5. Require both successful XCTest exit and JSON `succeeded: true`. The test covers canonical load, initial import, cached/uncached repository reads, 1/4/8-reader batches, ten preview/confirm/read cycles and invalid-stage rollback. It records monotonic wall times and post-stage physical-footprint samples. It does **not** render UI, unlock the app, exercise Widget/background sync, or import bill rows. The single `import_copy_validate_publish` sample means importing a ledger directory, not a bill.
6. Destroy the disposable simulator and remove copied data, result bundles, configurations and logs when finished. Even when numeric output is safe, system logs and `.xcresult` artifacts may contain sensitive data. Keep private-derived aggregate metrics outside this public repository too. Confirm original source hashes remain unchanged when an authorized private source was copied.

Output paths are resolved and existing files are refused. The harness is intended for a trusted local runner with exclusive control over fixture/output directories, not a hostile concurrently modified filesystem. XCTest output-write or cleanup failures must be treated as failures; do not accept stale JSON from another run.

## Statistical and acceptance limits

Record revision, hardware, OS, Xcode/Go/Python/Beancount versions, build configuration, fixture manifest and command with results. Sample p95 is a nearest-rank descriptive statistic; n=10 or n=30 is not a calibrated production p95. A single first-load/import sample has no meaningful percentile. Concurrent-reader results measure elapsed **batch** time, not individual-request p95. Memory is sampled after phases, not peak, and simulator footprint cannot determine iPhone jetsam behavior.

For baseline findings and still-unapproved optimization proposals see `plans/20260921-ios-kernel-performance.md`. Physical-device, UI, cold-disk, thermal, battery and long-soak targets remain unmeasured. Do not use the withdrawn SLO table as an acceptance claim.
