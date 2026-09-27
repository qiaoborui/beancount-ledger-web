# 20260923-small-purse-yield

- Status: completed. Updated 2026-09-23 12:03 +08:00.
- Goal: safely import Alipay Small Purse balance yield as income, retain original-order refund allocation, and merge the verified fix through the protected-branch PR workflow.
- Scope: `server/internal/app/import_alipay_small_purse.go` and `server/internal/app/imports_test.go`. No ledger data or import configuration was changed.
- Base revision: `2a650ed4d7dee751c07c168e5f7a239f075fb1e4`; merged code revision: `7dc91e44a4e74f43679a0009831dfa84856ebbb1`; branch: `codex/fix-small-purse-yield`. PR #421 merged via normal squash on 2026-09-23.
- Progress: explicit top-up/refund/balance-yield classification; balance yield uses the configured income account and contributes to the owner's running share; unknown income requires review. Synthetic regression tests cover configured and default income mapping, unknown income, and existing refund behavior.
- Local state: all application changes were committed and pushed, then merged into `main`. A private native IPA was built from the same source and package-verified; physical installation remains untested.
- Validation: `go test ./...` passed 787 tests in 37 packages on code revision `72290aff` (identical application code in merged revision); `go build ./cmd/ledger-web` and `git diff --check` passed. PR #421 required `Gate` passed before merge; merged product files matched the tested code.
- Deployment: local self-hosted stack workflow started for merged revision; production runtime deployment remains separately unverified. The native IPA is independent of server deployment.
- Next: none for the merge task. Confirm the deployment workflow and runtime separately if server rollout is required.
