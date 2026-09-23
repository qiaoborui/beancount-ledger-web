# 20260923-small-purse-yield

- Status: active. Updated 2026-09-23 11:55 +08:00.
- Goal: safely import Alipay Small Purse balance yield as income, retain original-order refund allocation, and merge the verified fix through the protected-branch PR workflow.
- Scope: `server/internal/app/import_alipay_small_purse.go` and `server/internal/app/imports_test.go`. No ledger data or import configuration was changed.
- Base revision: `2a650ed4d7dee751c07c168e5f7a239f075fb1e4`; branch: `codex/fix-small-purse-yield`. PR: pending.
- Progress: explicit top-up/refund/balance-yield classification; balance yield uses the configured income account and contributes to the owner's running share; unknown income requires review. Synthetic regression tests cover configured and default income mapping, unknown income, and existing refund behavior.
- Local state: both source files and this note are pending commit and push. A private native IPA was built from the working tree and package-verified; physical installation remains untested. The IPA is not a server deployment.
- Validation: `go test ./...` passed 787 tests in 37 packages on this worktree; `go build ./cmd/ledger-web` and `git diff --check` passed. CI is pending.
- Next: commit and push the focused branch, open the PR, wait for required `Gate`, inspect mergeability, then merge through normal protection. Verify server deployment separately if remote use is required.
