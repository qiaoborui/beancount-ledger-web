# 20260929-ios-widget-implementation
Status: completed
Updated: 2026-09-29T14:35:15.479601+08:00
Goal: implement the user-approved Open Design terminal widgets in native SwiftUI.
Branch: codex/ios-terminal-widgets; base 5b8ff3e (tree identical to b921e5a).
Scope: seven widget views, shared widget tokens and typography, widget visual tests. No ledger/API/authentication changes. Existing App work remains separate.
Completed: light/dark layouts; exact primary amounts; compact headings; category shares; expanded calendar; linear trend; fixed heat levels; import matrix; monochrome Lock Screen; explicit redacted content. Preserve existing timeline providers, account selection/valuation, date links, and actual year-over-year comparison semantics.
Validation: iOS 27 simulator LedgerWidgetsTests 17 passed, 0 failed. 47 safe captures in docs/design/ios-terminal/widgets-v2. Long/empty/privacy and normal outputs inspected; large-import clipping corrected. QA simulator app installed. No physical-widget acceptance or release IPA built for this change.
Changed: seven WidgetExtension Swift files, WidgetTests/LedgerWidgetVisualTests.swift, captures and this note. Code and safe captures committed as 542eeb0 and pushed; PR https://github.com/qiaoborui/beancount-ledger-web/pull/499 is open and mergeable. CI pending at handoff. Native runtime checkout still contains the same widget changes alongside earlier unrelated WIP.
Next acceptance: review PR/CI and test actual home/Lock Screen widgets on a device after a subsequent IPA. No merge or physical acceptance claimed. Engineering implementation and simulator verification complete.
