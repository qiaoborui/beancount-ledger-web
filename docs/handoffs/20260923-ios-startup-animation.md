# 20260923-ios-startup-animation

- Status: active (animation committed and PR open; load-cost findings awaiting a
decision). Updated 2026-09-24 00:31 +08:00.
- Goal: replace the iOS app's static privacy startup cover with a lively opening
  animation, and separately determine whether the local startup path's
  perceived jank is animation or load cost.
- Scope: `App/LedgerMobile/Sources/DesignSystem.swift` and
  `App/LedgerMobile/Sources/RootView.swift`. No ledger data, no server code, no
  import configuration changed.
- Base revision: `4ef1b8040a4a` (`origin/main`, "docs: mark small purse yield
  handoff complete (#422)"). Branch: `codex/ios-startup-animation`, cut fresh
  from `origin/main` per the approved decision.
- Code revision: `37a460db` on `codex/ios-startup-animation`, pushed to `origin`.
  PR #459: https://github.com/qiaoborui/beancount-ledger-web/pull/459
- Approved decisions: base branch = fresh from `origin/main`; motion style =
  "subtle & alive" (brand mark breathes 1.0↔1.04, title rises at 0.10 s,
  subtitle at 0.18 s, three staggered dots, exit = fade + swell 1.0→1.06);
  load-cost work is scoped as **investigate and report, propose a plan before
  changing anything**.

## Completed

- Startup cover animation, in `DesignSystem.swift`:
  - `LedgerMotion` holds the launch-argument gate (`--safe-`/`--local-` prefix
    disables ambient motion) and the `Cover` timings
    (`revealDuration 0.45`, `breathDuration 1.9`, `exitDuration 0.32`,
    `exitScale 1.06`).
  - `LedgerAmbientMotion` drives a repeating Core Animation rather than a
    `TimelineView`. A `TimelineView` re-renders SwiftUI on the main thread every
    frame — exactly during the ledger load, when the main thread must stay
    free. Core Animation runs on the render server. Content receives the
    driver's 0…1 value, or `nil` when motion is off, so it picks its own
    resting state.
  - `LedgerBrandMark` gained `breathes`; the cover passes `true`, ordinary
    chrome (e.g. `ServerConfigurationView`) stays still.
- Cover restructured in `RootView.swift`: it moved out of the `.checking`
  switch case into its own `ZStack` above the phase switch, with its own
  `.animation(value: coverVisible)` scope. Animating `session.phase` instead
  cross-faded the cover, toolbar and populated list as one — which is why the
  local path previously had animation disabled and cut in with no transition.
  `PrivacyCover` gained per-line reveal state, and `StartupWaitingDots` folds
  the driver's 0…1 into a travelling pulse (`cycle 1.2`, `stagger 0.16`).
  Reduce Motion and UI-test launches both fall back to the static cover.

## Validation

- Build: green (xcodegen regenerated, simulator build).
- Unit tests: `Executed 415 tests, with 4 skipped and 3 failures (3
  unexpected)`. The three failures are pre-existing keychain failures, all
  unrelated to this change:
  `BookkeepingPipelineTests.testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey`,
  `ImportClassificationTests.testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences`,
  `LocalGitBackgroundCredentialTests.testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken`.
- UI tests: `testCompactLedgerShowsCategoriesAndAlignedTitles` (11.778 s) and
  `testReadOnlyNavigationAndResponsiveSurfaces` (9.209 s) fail identically on
  pristine `origin/main`, confirmed by baseline comparison — pre-existing.
- Animation: verified on captured simulator frames through the
  background→foreground resume path. The frames show the brand mark, "Ledger",
  "敏感数据已隐藏" and three cobalt dots at differing opacities collapsing over
  the dimmed ledger with the scale swell. An instrument sanity check
  (`XCTAssertNotEqual` on consecutive screenshots) ruled out the "screenshots
  don't capture frames" explanation.
- Load cost, measured against a real on-disk ledger through the production
  repository and engine (see the local checkpoint for the harness details):
  - Cold start, 100k entries spread over 12 months: 3.80 s to `.ready`, main
    thread blocked only 0.031 s.
  - Cold start, 100k entries all inside one opened month: 7.06 s, and the
    ledger fails to open at all — ends in `.locked(authenticated: true)` with
    `local request exceeds 16 MiB`. Main thread blocked only 0.006 s.
  - Canonical model growth is linear at ~330 bytes and ~73 µs per entry.
  - Bootstrap payload 10.99 MB for 20k entries; JSON decode 0.159 s; canonical
    model build 1.39 s; range-scoped bootstrap of an uncached month 0.76 s.

## Findings (not fixed; awaiting a decision)

1. The perceived startup jank is **not** main-thread CPU. The main thread is
   blocked 6–31 ms across every measured cold start because the heavy work is
   correctly off the main actor. The latency is wall-clock waiting, so the fix
   is shortening the wait, not shaving frames.
2. Genuine scaling defect: every local request carries the entire canonical
   bookmark model as inline JSON (`LocalLedgerJSON.requestData`), growing
   ~330 bytes per entry. Past roughly 40k entries in the opened month
   (≈140k Beancount lines) the request exceeds the 16 MiB cap enforced at
   `server/mobilecore/dispatch.go:59`, and the app opens to a locked screen
   with "local request exceeds 16 MiB" rather than the ledger.
3. Cover timing: on the fast UI-test fixture the cover is on screen well under
   0.3 s while `revealDuration` is 0.45 s, so part of the staggered reveal can
   go unseen on a fast load. Options are shortening `revealDuration` or
   enforcing a minimum cover duration; neither is applied yet.

## Remaining steps

1. Get a decision on the load-cost plan for finding 2 before touching it.
2. Decide the cover-timing question (finding 3).
3. Merge PR #459 once its required `Gate` check passes.

## Not tested

- Physical device. All animation verification is simulator-only.
- A ledger large enough to trip the 16 MiB cap on a real user's device; the
  oversized fixture was synthetic and built for measurement only.
