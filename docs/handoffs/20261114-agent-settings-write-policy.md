# 20261114-agent-settings-write-policy

- Status: active (draft PR open, CI running)
- Last updated: 2026-11-14 (+08:00)
- Branch: `codex/ios-agent-settings-write-policy`, based on `main` at `8ef3888b`; PR #697 (draft)
- Task: subtask A of the AI-native 账本助手 work (see the parent notes in the
  maintainer's local handoff directory; this note is the sanitized, shareable
  half)

## Goal

One 助手设置 page instead of the single long 模型与密钥 page, and a graded write
policy: the assistant writes a change that passes validation at once by
default, and asks first only for the changes that are hard to notice going
wrong. Acceptance: a new install defaults to tiered, an existing install keeps
its old switch, the root page fits one screen, Go and Swift tests pass and CI
`Gate` is green.

## Decisions

- `LedgerAgentWritePolicy` (`.tiered` default, `.always`, `.confirm`) lives in
  `LedgerAgentSettings.swift` and is stored under `ledger.agent.write-policy`.
  The old `ledger.agent.auto-write` switch is only read for migration: `true` →
  `.always`, explicitly stored `false` → `.confirm`, absent → `.tiered`. The
  legacy key is left in place and no longer written.
- Tiered holds a change back when a file is deleted or when the removed lines
  add up to more than `largeRemoval` (20). The reason travels on
  `LedgerAgentPendingEdit.holdReason` and the change card shows it above the
  validation sentence; `.always` never holds, `.confirm` always waits and needs
  no reason because the card already asks. Nothing else about the card, the
  diff or the 写入账本 button changed.
- The empty-reply fallback under a change now says 正在写入账本 when the policy
  writes it at once, and keeps 请在下方查看并确认 when it does not.
- New app-target file `App/LedgerMobile/Sources/LedgerAgentSettingsView.swift`
  holds the settings root, the 模型与密钥 page, 可用工具, 高级, the model picker
  and the thinking picker. It is listed in `Package.swift`'s exclude list
  (SwiftUI, app target only). `LedgerAgentQuickSwitch` stays in
  `LedgerAgentView.swift` so the other subtasks keep their file.
- Root rows: 模型 / 思考强度 / 写入账本 / 记忆 / 智能建议 / 推荐问题 / 可用工具 /
  高级. 可用工具 sits in a 能力 section, with a comment marking where 技能 and
  MCP 服务器 rows are added by the other subtasks. Only 权限 and 建议 carry a
  one-sentence footer.
- Identifiers: `ledger-agent-model` still marks the row that opens the model
  list, which now lives in the 模型与密钥 page; the root's model row is
  `ledger-agent-settings-model`. `ledger-agent-thinking` is the root row that
  opens the thinking picker (unchanged meaning). New: `ledger-agent-write-policy`.
  Every other identifier is unchanged. `UITests/` had no dependency on the old
  layout.
- 使用记忆 moved to the top of `LedgerAgentMemoryView`; the root's 记忆 row shows
  已开启 / 已关闭.
- AI 开账 opens `LedgerAgentSettingsView(modelOnly: true)`, which is the
  模型与密钥 page itself: write policy, memory and suggestions need a ledger.
- Entry points renamed 模型与密钥 → 助手设置: chat bar button, history drawer menu,
  quick-switch menu.
- `LocalAgentSystemPrompt(canEdit:)` item 4 now says the app writes after
  validation, holds deletions and large removals for a confirmation, and still
  forbids claiming 已写入. The two attachment tool descriptions and the assist
  `nextPrompt` line that said the card's button was the only way to write were
  updated for the same reason.
- `AGENTS.md` and `.agents/rules/project.md` Safety Rules now describe the iOS
  assistant as the one exception to manual-first writes.
- `FEATURE_PARITY.md`: only the 账本助手 row changed (write policy, 助手设置 entry,
  access column, source list).
- Feature PR only: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are
  untouched, and a release is needed.

## Validation

- `cd server && go build ./cmd/ledger-web`: passed.
- `cd server && go test ./...`: passed except two failures that also fail on
  `origin/main` on this machine, with no code of this branch involved:
  `TestFeedNeverCutsACharacter` (event-chunk timing) and
  `TestGitHubWriteValidationLargeLedgerPerformance` (`bean_check` budget; both
  were re-run on a clean `origin/main` worktree and failed the same way).
- `go test ./internal/app -run LocalAgent -v`: `TestLocalAgentSystemPrompt…`
  both pass, including the new `DoesNotClaimAWrite`.
- This machine is Linux with no Swift/Xcode, so the Swift side was not compiled
  or tested locally. CI's iOS core (`swift test`), iOS app and iOS widgets jobs
  are the check for: the write policy migration, the tiered decisions, the
  tiered / always / confirm conversation cases, and the new settings file.
- Not tested: the settings page on a simulator or device (whether the root fits
  one screen, how the menu-style picker looks), and any live model conversation
  with the new prompt wording.

## Next

1. Watch CI until `Gate` is green; fix any Swift compile or test failure.
2. Look at the settings root on a simulator when one is available, and shorten
   or merge sections if it does not fit one screen.
3. Hand over to the parent task for review and merge; the 能力 section is the
   place to add 技能 and MCP 服务器 rows from the other subtasks.
