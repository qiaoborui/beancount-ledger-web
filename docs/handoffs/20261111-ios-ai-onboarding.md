# 20261111-ios-ai-onboarding

- Status: completed (awaiting PR review)
- Last updated: 2026-11-11 (+08:00)
- Branch: `codex/ios-ai-onboarding`, based on `main` at `bf1fcca3`; PR #638
- Code covered: commit `8fdfbfb3` plus the follow-up review/test fix commit on the same branch

## Goal

Feature B of a two-part request: replace the hand-picked opening of a new ledger with an AI-native onboarding that reuses the existing on-device agent (`server/mobileagent`), keeping the manual `OnboardingWizardView` as a fallback. Feature A (customizable overview) is PR #636.

## Decisions

- The onboarding page configures the model and key first (the 账本助手 settings) and offers 跳过，手动开账. 手动开账 stays in the toolbar throughout.
- No new native entry point: `RunTurnJSON` takes an optional `onboarding` state. In that mode the loop has no ledger (workspace, scratch, memory and attachments are rejected) and exposes only `ask_user` plus the onboarding tools: `set_ledger_profile`, `upsert_account`, `remove_account`, `replace_categories`, `upsert_category`, `remove_category`, `present_onboarding_plan`.
- The app owns the draft and sends it with every turn; the response returns the edited draft. A failed or stopped turn keeps the draft, and 重试 resends the same question with the last good transcript. A new message after a failure carries the unanswered question with it.
- The app sends the device's calendar day (`today`, `yyyy-MM-dd`) with each turn: Go on iOS keeps time in UTC, so "future start date" is judged on the user's own date. Start dates before 1970-01-01 are rejected.
- `ready` is set only by `present_onboarding_plan`, and any later edit clears it. 确认创建 shows only when ready and complete (at least one asset account, plus income and expense categories).
- Creation goes through `createCustomLocalLedger`, the wizard's path. `createCustom` gained an optional opening date and exact `Decimal` opening amounts. Income and expense categories open with every currency the ledger holds, so a foreign-currency account can spend into them (found in a live HKD + CNY run, where bean-check failed before the fix).
- Currency codes must end in a letter or digit on both the Go and Swift sides.
- Feature PR only: `MARKETING_VERSION` and the build number are untouched. A release is still needed.

## Validation

- `server/`: `go test ./...` and `go build ./cmd/ledger-web` passed. `go vet` on `mobileagent` is clean; `go vet ./...` reports a pre-existing issue in `internal/app/gmail_poll_worker_test.go` that is not on this branch. `TestFeedNeverCutsACharacter` failed once in a full run and passed 3/3 alone on both this branch and `main` (flaky, unrelated).
- LedgerCore xcframework rebuilt; `swift test` in `App/LedgerMobile`: 1024 tests, 26 skipped, 0 task failures; the Xcode simulator build of the LedgerMobile scheme succeeded.
- Live model: five scripted onboarding conversations (one-shot, guided, multi-currency HKD + CNY, revise after ready, messy input with a prompt-injection attempt and a future date) were run through `RunTurnJSON` against an OpenAI-compatible model with tool calls. All produced a ready, valid draft with no tool errors; each draft became a ledger through the app's `createCustom` path and passed `bean-check` with the expected balances. The scenario harness was a local, uncommitted test.
- Full Xcode test scheme on an iOS 27.2 simulator, unsigned build: 37 failures. All 4 unit-test failures (3 need the keychain, which unsigned builds lack) and 21 of the UI failures also fail on `main` with the same tests. `test292TransactionsScrollLoadsEveryRowWithoutJumping` passed 2/2 when rerun alone on this branch (timing under load). The remaining 11 navigation/overview/report UI failures are being compared against `main`; see the PR body for the result.
- Not tested: signed builds (keychain tests and the live UI flow), VoiceOver, a real device.

## Next

1. Review and merge the PR; include it in the next iOS release together with #636.
2. Try a real conversation on device with a configured model and tune the onboarding system prompt in `server/mobileagent/onboarding.go` if the questions feel long.
