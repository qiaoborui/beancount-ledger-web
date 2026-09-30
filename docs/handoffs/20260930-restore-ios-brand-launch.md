# 20260930 restore iOS brand launch

- Status: active
- Goal: restore the iOS icon and launch experience that was present in the local-only delivery but missing from `main`.
- Branch: `codex/restore-ios-brand-launch`
- Scope: light/dark app icons, launch storyboard and assets, launch fold animation, privacy cover continuity, and an installed-bundle resource regression test.
- Validation: device Release build is running from `App/LedgerMobile`; focused unit/UI tests are running on a fresh iOS 27 simulator.
- Remaining: inspect test result, build the SideStore IPA, inspect its payload, push the branch, and open the PR.
- Out of scope: unrelated bookkeeping sheet and Dynamic Island edits remain on their existing branch.
