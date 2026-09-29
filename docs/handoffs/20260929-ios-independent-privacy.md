# 20260929-ios-independent-privacy
Status: active — implementation and integrated simulator checks passed; packaging in progress
Updated: 2026-09-29T15:02:01.632426+08:00

Goal: independent local-ledger authentication and background privacy-cover switches in Settings. Both default on for new ledgers. Previously distributed builds coupled cover to authentication; migrate existing opted-out ledgers without silently re-enabling their cover. Settings are per ledger. Authentication preference changes still require fresh authentication; cover changes do not change authentication, automatic locking, or cold-start loading animation. Remote behavior unchanged.

Branch: codex/ios-privacy-controls, base 5b8ff3e. Focused PR includes prerequisite local authentication setting previously delivered only in local builds. Existing unrelated terminal/startup/widget changes stay outside this PR.

Changed: App/LedgerMobile/Sources/LedgerSession.swift, Sources/SettingsView.swift, Tests/LocalLedgerSessionTests.swift, UITests/LocalOnlySurfaceUITests.swift. All paths relative to App/LedgerMobile after the first. No private data or new dependencies.

Validation: integrated native worktree xcodebuild test with LocalLedgerSessionTests: 40 passed; LocalOnlySurfaceUITests/testLocalPrivacySwitchPersistsAndUpdatesLockControls: 1 passed. Covers all four preference combinations, background lock/unlock, restart persistence, ledger scoping, legacy migration, failed authentication and stale settings completion. Simulator screenshot visually inspected. Initial compile rejected stored-property access before initialization; fixed using local values, verified by successful test build. Independent security review found no actionable issues. git diff --check passed. Focused PR source: 38 LocalLedgerSessionTests passed on iOS Simulator.

Next: open PR; finish Build59 private package and verify hosted bytes. Physical installation/acceptance remains user-driven.
