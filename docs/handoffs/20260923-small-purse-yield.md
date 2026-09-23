# 20260923-small-purse-yield

- Status: active. Updated 2026-09-23 11:57 +08:00.
- Goal: safely import Alipay Small Purse balance yield as income, retain original-order refund allocation, and merge the verified fix through the protected-branch PR workflow.
- Scope: `server/internal/app/import_alipay_small_purse.go` and `server/internal/app/imports_test.go`. No ledger data or import configuration was changed.
- Base revision: `2a650ed4d7dee751c07c168e5f7a239f075fb1e4`; code revision: `72290aff66e6eead9d8eaa0c2c7dd43f29651104`; branch: `codex/fix-small-purse-yield`. PR: https://github.com/qiaoborui/beancount-ledger-web/pull/421.
- Progress: explicit top-up/refund/balance-yield classification; balance yield uses the configured income account and contributes to the owner's running share; unknown income requires review. Synthetic regression tests cover configured and default income mapping, unknown income, and existing refund behavior.
- Local state: source files and the earlier note are committed and pushed; this PR-status update is pending commit. A private native IPA was built from the same source and package-verified; physical installation remains untested. The IPA is not a server deployment.
- Validation: `go test ./...` passed 787 tests in 37 packages on code revision `72290aff`; `go build ./cmd/ledger-web` and `git diff --check` passed. PR CI is running; required `Gate` remains pending.
- Next: commit and push this note update, wait for required `Gate`, inspect mergeability, then merge through normal protection. Verify server deployment separately if remote use is required.
