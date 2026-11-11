# 20261111-ios-ai-onboarding

- Status: completed (awaiting PR review)
- Last updated: 2026-11-11 (+08:00)
- Branch: `codex/ios-ai-onboarding`, based on `main` at `bf1fcca3`

## Goal

Feature B of a two-part request: replace the hand-picked opening of a new ledger with an AI-native onboarding that reuses the existing on-device agent (`server/mobileagent`), keeping the manual `OnboardingWizardView` as a fallback. Feature A (customizable overview) is PR #636.

## Decisions

- The onboarding page configures the model and key first (the 账本助手 settings) and offers 跳过，手动开账. 手动开账 stays in the toolbar throughout.
- No new native entry point: `RunTurnJSON` takes an optional `onboarding` state. In that mode the loop has no ledger (workspace, scratch, memory and attachments are rejected) and exposes only `ask_user` plus the onboarding tools: `set_ledger_profile`, `upsert_account`, `remove_account`, `replace_categories`, `upsert_category`, `remove_category`, `present_onboarding_plan`.
- The app owns the draft and sends it with every turn; the response returns the edited draft. A failed or stopped turn keeps the draft, and 重试 resends the same question with the last good transcript.
- `ready` is set only by `present_onboarding_plan`, and any later edit clears it. 确认创建 shows only when ready and complete (at least one asset account, plus income and expense categories).
- Creation goes through `createCustomLocalLedger`, the wizard's path. `createCustom` gained an optional opening date (validated `YYYY-MM-DD`) and now formats opening amounts with exact `Decimal` rounding instead of `Double`.
- Feature PR only: `MARKETING_VERSION` and the build number are untouched. A release is still needed.

## Validation

- `server/`: `go test ./...` and `go build ./cmd/ledger-web` passed; the LedgerCore xcframework was rebuilt with the Xcode toolchain.
- `App/LedgerMobile`: `swift test` passed (1020 tests, 26 skipped, 0 failures), using `DEVELOPER_DIR` pointing at Xcode.app.
- The iOS SDK cross-build (`swift build --triple arm64-apple-ios17.0`) succeeded.
- `xcodegen generate` plus the Xcode simulator build of the LedgerMobile scheme succeeded; this is the only build that compiles `LedgerOnboardingAgentView.swift` and `LocalLedgerViews.swift`.
- Not tested: a live model conversation, screenshots (no simulator device was available), VoiceOver, app-host UI tests, and a real device.

## Next

1. Review and merge the PR; include it in the next iOS release together with #636.
2. Try a real conversation on device with a configured model and tune the onboarding system prompt in `server/mobileagent/onboarding.go` if the questions feel long.
