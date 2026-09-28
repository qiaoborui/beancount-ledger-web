# 20260928-ios-terminal-overview

Status: active. Updated: 2026-09-28T14:42:33+08:00.

## Goal and scope
Implement the approved terminal visual direction in native SwiftUI, beginning with shared components and the overview screen. Light and dark themes, single-row title/date/sync, no local-only sync indicator, no quick-entry dock, privacy-safe amounts, and existing shared date state are required. Other pages and shell/navigation migration are later increments. Use synthetic data for screenshots and tests; preserve existing ledger logic.

## State
Branch: codex/ios-terminal-overview. Base: 94c07e6968ccc1224f8a06cdab06dbfd36bf181c. No PR yet.
Implementation is uncommitted. Overview, terminal components, and shared date-sheet styling are implemented. Existing local category aggregation, range state, ledger loading, and manual financial confirmation are reused.

## Validation and next steps
Simulator build passed. 40 model/sync tests and 2 date-session tests passed; 3 UI scenarios passed on iPhone 17 Pro (date draft/detail return, accessibility reachability, local-only/configured sync details). Initial date accessibility-label failure was corrected and rerun passed. Architecture and security specialists found no new issues. All three overview UI tests passed on iPhone 13 mini (375 pt), including hidden amounts/percentages. A final dark-mode date/detail test passed after the date sheet was expanded to show the complete month grid. Light/dark, largest text, privacy, and date screenshots were exported and visually inspected. Next: commit, push, create PR, and check mergeability. No real ledger was accessed; no physical-device/signing/IPA acceptance is claimed.

Changed files: App/LedgerMobile/Sources/OverviewView.swift, TerminalDesignSystem.swift, DesignSystem.swift, TimeRangePicker.swift; App/LedgerMobile/Package.swift; three UI-test files. Design mapping: docs/design/ios-terminal/README.md.
