# Native Import Category Preselection

- Task ID: `20260922-ios-import-category-preselection`.
- Status: completed (implementation and simulator verification; draft PR delivery).
- Updated: 2026-09-22T18:07:00+08:00.
- Goal: replace an unclassified import draft with a clearly leading suggested
  category while preserving visible review and explicit write confirmation.
- Branch: `codex/ios-import-category-preselection`.
- Code revision: `089e1e6b07a6354031cf531e236acb692587a6d8`, based on main
  `0867241e14d0a7b98d9deb1300fdaec1ade436d4`.
- Draft PR: https://github.com/qiaoborui/beancount-ledger-web/pull/417.
- Scope: main's native import classification path. Existing SQLite experiments,
  capacity work, hosted artifacts and private ledgers remain unchanged.

## Policy And Changes

- For `Expenses:Unknown` / `Income:Unknown`, preselect a concrete expense/income
  candidate with probability >= 0.60, confidence >= 0.50, and a lead >= 0.20 over
  the next account candidate. Preserve raw model values and check compatible
  transaction nature, posting polarity and the account allowlist.
- Keep moderate selections pending review. Existing specific categories, strict
  funding-account thresholds, manual selections, posting values, source metadata,
  canonical validation and final write confirmation retain their behavior.
- Changed files under `App/LedgerMobile/`: `Sources/ImportClassificationContext.swift`,
  `Sources/NativeImportFlowView.swift` (DEBUG safe fixture),
  `Tests/ImportClassificationTests.swift`, `UITests/LedgerMobileUITests.swift`.
- Product and test changes are committed and pushed in the code revision above.
  This note is delivered with the same focused PR. Runtime/build artifacts are
  local-only and excluded from version control.

## Verification

- Old main plus new regression tests: three native cases reproduced five failed
  assertions retaining the unknown category.
- Fixed code: 39 native classification/bookkeeping tests and one UI test passed
  with local simulator signing. Five new unit tests exercise thresholds, pending
  fields, existing classifications, income/refund polarity and invalid candidates.
- UI screenshot inspected: concrete category displayed with pending confirmation;
  the existing test also reaches the final write confirmation and cancels it.
- `git diff --check` passed. No unrelated production changes found in the review.
- Reproduce using `xcodebuild test -project App/LedgerMobile/LedgerMobile.xcodeproj
  -scheme LedgerMobile -configuration Debug -destination '<available simulator>'
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`
  and selectors `LedgerMobileTests/ImportClassificationTests`,
  `LedgerMobileTests/BookkeepingPipelineTests`, and
  `LedgerMobileUITests/LedgerMobileUITests/testImportClassificationReviewsFieldsIndependentlyAndRestoresFullList`.
- An unsigned simulator attempt failed two existing Keychain cases; local signing
  resolved both. The standalone Swift package test entrance has a pre-existing
  missing Cookie editor symbol failure; tests ran through the native app target.
- Synthetic data only. Physical iPhone, live Jev accuracy, IPA packaging and
  deployment were outside this verification. No merge or hosted IPA replacement.

## Next Step

Review draft PR #417 and authorize merge before including the change in a main IPA.
Machine-specific evidence and runtime locations are recorded only in
`$GIT_COMMON_DIR/agent-handoffs/20260922-ios-import-category-preselection.md`.
