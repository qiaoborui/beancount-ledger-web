# 20261114-agent-settings-write-policy

- Status: active (draft PR open, CI `Gate` green, waiting for review)
- Last updated: 2026-11-14 (+08:00)
- Branch: `codex/ios-agent-settings-write-policy`, based on `main` at `8ef3888b`; PR #697 (draft)
- Code covered: commits `49eaf005`, `8dcb46ab`, `a831caae`, `0dab48a3`; `f39133b0` and later only
  update this note
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
  locally. CI checked it: `Gate` is green on run 43578411528, and again on the final run before handover — iOS core
  (`swift test`), iOS app (simulator build plus `LedgerMobileTests`) and
  Backend all pass; iOS widgets, iOS UI tests, Frontend and the rest are
  skipped because no path of this change plans them.
- Two CI failures were fixed on the way: the change card's `note` getter lost
  its implicit return once a case had statements, and five existing tests
  assumed a fresh conversation waits for the card, so they now set
  `.confirm` explicitly (`LedgerAgentTests`, `LedgerAgentBranchesTests`).
- Not tested: the settings page looked at on a simulator or device (whether the
  root fits one screen, how the menu-style picker looks), and any live model
  conversation with the new prompt wording. `LedgerAgentSettingsView.swift` is
  app-target only, so no automated test draws it.

## Next

1. Review and merge; the 能力 section is the place to add 技能 and MCP 服务器
   rows from the other subtasks, and `LedgerAgentSettingsView` is the file they
   touch for that.
2. Look at the settings root on a simulator when one is available, and shorten
   or merge sections if it does not fit one screen.
