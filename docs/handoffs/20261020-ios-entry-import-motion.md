# 20261020-ios-entry-import-motion

- Status: completed (pending PR review)
- Last updated: 2026-10-20 15:30 +08:00
- Branch: `codex/ios-entry-transfer-import-fixes` (based on `main` @ eb31dda)

## Goal
Fix iOS fast-entry transfer account drift, the transfer page resetting to the
default account, already-imported bills re-prompting on the import page, and
add motion including a redesigned launch animation.

## Done
- `TransactionViews.swift`: setup runs once (`didSetup`), so returning from a
  picker sheet keeps the selection; source/target detected by posting sign;
  last transfer route remembered in UserDefaults (`CookieTransferMemory`);
  identical source/target rejected on save.
- `NativeImportFlowView.swift`: draft discarded right after a successful
  commit and never persisted afterwards.
- `ImportHistoryView.swift`: archive list loads before draft restore; a draft
  whose import ID is already archived is deleted instead of re-offered.
- `LedgerLaunchView.swift`: staged launch (outline draw → fill → fold drop with
  overshoot → wordmark + accent rule), shorter exit with slight zoom.
  `LedgerLaunchBrand()` at default progress renders the settled brand (used by
  the privacy cover).
- `AmountLabel` / `BalancedAmount`: numeric content transition on value change;
  Reduce Motion falls back to opacity.

## Validation
- Simulator build (unsigned): succeeded.
- `LedgerMobileTests`: 733 run, 3 failures, all Keychain-access tests that need
  a signed build (unrelated to these changes).
- Not tested: on-device manual walkthrough of the launch animation and flows.

## Next
- Review on device via the PR; tune launch timing if it feels slow/fast.
