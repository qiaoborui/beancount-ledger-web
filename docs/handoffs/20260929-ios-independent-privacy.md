# 20260929-ios-independent-privacy
Status: completed — implementation, simulator checks and Build59 delivery complete
Updated: 2026-09-29T15:02:01.632426+08:00

Goal: independent local-ledger authentication and background privacy-cover switches in Settings. Both default on for new ledgers. Previously distributed builds coupled cover to authentication; migrate existing opted-out ledgers without silently re-enabling their cover. Settings are per ledger. Authentication preference changes still require fresh authentication; cover changes do not change authentication, automatic locking, or cold-start loading animation. Remote behavior unchanged.

Branch: codex/ios-privacy-controls, code revision f35a701, base 5b8ff3e. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/500 (open, mergeable; CI Gate passed, not merged). Focused PR includes prerequisite local authentication setting previously delivered only in local builds. Existing unrelated terminal/startup/widget changes stay outside this PR.

Changed: App/LedgerMobile/Sources/LedgerSession.swift, Sources/SettingsView.swift, Tests/LocalLedgerSessionTests.swift, UITests/LocalOnlySurfaceUITests.swift. All paths relative to App/LedgerMobile after the first. No private data or new dependencies.

Validation: integrated native worktree xcodebuild test with LocalLedgerSessionTests: 40 passed; LocalOnlySurfaceUITests/testLocalPrivacySwitchPersistsAndUpdatesLockControls: 1 passed. Covers all four preference combinations, background lock/unlock, restart persistence, ledger scoping, legacy migration, failed authentication and stale settings completion. Simulator screenshot visually inspected. Initial compile rejected stored-property access before initialization; fixed using local values, verified by successful test build. Independent security review found no actionable issues. git diff --check passed. Focused PR source: 38 LocalLedgerSessionTests passed on iOS Simulator.

Delivery: Build59 private IPA contains the app, widget and share extensions at build 59; package signature/ZIP checks passed and hosted HTTP200 download matched SHA256 ca8e185aea235e82c29094716295e07c5263b359fa0f13ff148361b58bc324ab. Packaging includes existing local native changes, while PR500 contains only privacy controls. No physical installation was performed. Next: user installs through the existing self-signing workflow and verifies Settings; no remaining implementation steps. PR remains unmerged.
