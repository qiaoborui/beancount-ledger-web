# 20261114-agent-skills

- Status: active (draft PR #700, CI Gate green, waiting for review and the settings page)
- Last updated: 2026-11-14 21:10 (+08:00)
- Branch: `codex/agent-skills`, one commit rebased onto `main` at `f2e01d9b` (after A #697, B #699 and C #698); PR #700 (draft). Rebase conflicts were all additive and resolved by keeping both sides: A's rewritten 账本助手 row plus this branch's 助手技能 row in `FEATURE_PARITY.md`, the two `Package.swift` file lists, the `disabledSkills` and `appSettings` request fields, turn parameters and call-site arguments, and the two blocks in `runTurnIn` (skills, then B's app-settings tools, which append last). A's `LedgerAgentSettingsView.swift` is untouched: the 技能 entry point is the maintainer's. The `TestFeedNeverCutsACharacter` flake fix C landed in `4833bd90` is used as-is; this branch dropped its own version of that fix.
- Task: D of the AI-native ledger assistant split (see `20261114-ai-native/D-skills.md` in the shared handoff directory)

## Goal

Give the on-device 账本助手 skills: instruction files loaded on demand so the prompt does not carry them. Format is the common `SKILL.md` (YAML frontmatter `name` + `description`, Markdown body). Two sources: skills shipped in the app, and skills in the ledger's `skills/<name>/SKILL.md`, which Git syncs. A ledger skill replaces a built-in one of the same name. The user can turn skills off per device.

## Decisions

- **Go side is `server/mobileagent/skills.go`** plus `server/mobileagent/skills/` (embedded). `runTurnIn` gained five lines: open the set, add the `load_skill` tool, append the prompt section. The section is added after the attachment/history sections and before `remembered.prompt()`, so the memory still ends the cacheable prefix.
- **The turn reads its draft.** `openSkills` uses the scratch copy's root when the turn may edit, so a skill written with `write_file` is loadable in the same turn, and `load_skill` re-discovers on each call instead of serving a snapshot.
- **Frontmatter parsing is hand-rolled**, not a YAML dependency: plain, quoted, folded/literal block values, `---`/`...` terminators, CRLF and BOM, unquoted trailing comments. Only `name` and `description` are read; every other key (including `globs`, `alwaysAllow` from the repo's own `.agents/skills`) is ignored, so a SKILL.md written for another agent loads unchanged.
- **Limits**: name `[a-z0-9]` with hyphens, 1–64 chars; description ≤ 300 bytes; body ≤ 16 KB; at most 40 skills. A file that breaks one of them is skipped and reported (`problems` in the catalog, and by name when `load_skill` is asked for it) — never a failed turn. Hidden folders and `_`-prefixed partials are ignored.
- **Ordering**: merged by name and sorted, so the prompt list is byte-identical every turn.
- **`load_skill(name, file?)`**: the body, plus `path` and `source`. A built-in skill's extra files are read through `file` (only names listed in `files`; `..` cannot escape); a ledger skill's extra files go through the existing `read_file` on `skills/<name>/…`, and `load_skill` says so instead of reading them.
- **Built-in skills, 3**: `alipay-bill-import` (+ `columns.md` reference), `wechat-bill-import`, `beancount-bookkeeping`. All rewritten for the device tools: no shell, no `double-entry-generator`, no Python — attachments → `reconcile_attachment` → `edit_file`/`write_file` → `bean_check` → `archive_statement`. A Go test checks every backticked tool name in every built-in body against the tools this build actually offers, so a skill cannot drift into calling something that does not exist.
- **Writing skills is not a new tool**: the prompt tells the model to write a multi-step 「以后都这样做」 flow with `write_file`/`edit_file` under `skills/<name>/SKILL.md` (same draft, change card and `bean_check`), and to keep loose preferences in memory. The memory sentence is only added when the turn has memory, so a memory-off turn is never told to call `edit_memory`.
- **Request field** `disabledSkills []string` appended at the end of `turnRequestV1`; disabled skills are left out of the prompt list and refused by `load_skill`.
- **Exported catalog** `SkillCatalogJSON(requestJSON)` → `{version, ok, skills:[{name, description, source, path, body, disabled}], problems}`. It lists **every** skill including the disabled ones (the page has to offer a switch back on) and marks them, and it includes each body so the page needs one call, not two. Request: `{version, workspaceRoot, disabledSkills}`.
- **Swift**: new portable file `LedgerAgentSkills.swift` (`LedgerAgentSkill`, `LedgerAgentSkillCatalog`, `LedgerAgentSkillLister` bridge to `MobileagentSkillCatalogJSON`, `LedgerAgentSkillSettings` store) and new page `LedgerAgentSkillsView.swift` (title 技能, one switch per skill, tap for a read-only body sheet, plus the files that could not be read). The off list is per device in `UserDefaults` (`ledger.agent.disabled-skills`), sent only when non-empty so an untouched install sends the same request as before. `runAgentTurn` gained `disabledSkills: [String] = []`; `LedgerAgentView.turnReporting()` passes `LedgerAgentSkillSettings.shared.disabled`. `LedgerAgentSettingsView` was **not** touched — the 技能 entry into this page still has to be added by the task that rewrites the settings page.

## Decisions made after the first CI run

- **`import LedgerCore` is per file.** A new Swift file that calls a gomobile export needs its own `#if canImport(LedgerCore) import LedgerCore #endif`; `canImport` alone only says the module exists. Missing it reads as "cannot find 'MobileagentSkillCatalogJSON' in scope" even though the freshly built framework's header exports it (checked with a throwaway CI step that grepped the header, since reverted). `swift test` cannot catch it: the portable package compiles that branch out.
- **The Swift test fixture must not hand back `[String: Any]` from an actor** (not Sendable) and must mirror `LedgerAgentSkillLister.native` by leaving `disabledSkills` out when nothing is off; both were compile/test failures on the Mac runner, fixed in follow-up commits.
- **`TestFeedNeverCutsACharacter` is deliberately not touched here.** It is flaky for a scheduling reason (a 1200-byte stream produced at once is legitimately merged into one event until the observer takes it, so `len(events) >= 2` depended on timing); C fixed it in `4833bd90`, and this branch uses that version untouched.

## Changed files

- `server/mobileagent/skills.go`, `server/mobileagent/skills_test.go`, `server/mobileagent/skills/{alipay-bill-import,wechat-bill-import,beancount-bookkeeping}/SKILL.md`, `server/mobileagent/skills/alipay-bill-import/columns.md`
- `server/mobileagent/mobileagent.go` (request field + five lines in `runTurnIn`)
- `App/LedgerMobile/Sources/LedgerAgentSkills.swift`, `App/LedgerMobile/Sources/LedgerAgentSkillsView.swift`, `App/LedgerMobile/Tests/LedgerAgentSkillsTests.swift`
- `App/LedgerMobile/Sources/LedgerAgent.swift` (request field), `App/LedgerMobile/Sources/LocalLedgerRepository.swift` (turn parameter), `App/LedgerMobile/Sources/LedgerAgentView.swift` (one line at the call site)
- `App/LedgerMobile/Package.swift` (new portable source; the page in the excluded UI list), `App/LedgerMobile/FEATURE_PARITY.md` (new row), `docs/ledger-layout.md` (skills folder)

## Validation

- `server/`: `go test ./...` — every package passes except `TestGitHubWriteValidationLargeLedgerPerformance` (bean_check over 12k transactions takes 4–5 s against a 2 s budget here; same on `main`, and CI's Backend job runs it with `LEDGER_VALIDATION_PERFORMANCE_REQUIRED=1` and passes). `go build ./cmd/ledger-web` passes; `go vet ./mobileagent` is clean.
- CI: **Gate green** on every head up to the pre-rebase tip (last: run 43586710359), and again on the rebased commit (see the PR's Gate check). Plan checks, Backend, iOS core (`swift test` on the Mac runner) and iOS app (simulator build plus `LedgerMobileTests`) passed each time. The iOS app job is the only one that compiles `LedgerAgentSkillsView.swift` and the `canImport(LedgerCore)` branch.
- New Go tests: frontmatter shapes and rejections, built-in skills usable with only real tool names, ledger override + stable order, prompt lists names/descriptions only, `load_skill` body/file/`..`/unknown/disabled cases, disabled filtering, limits and cap, catalog JSON, a full turn listing and loading a skill, `disabledSkills` reaching the prompt, a skill written in the draft loadable in the same turn, and the skills section sitting before the memory section.
- Swift was not compiled here (Linux, no Xcode). The Mac runner's `swift test` and the simulator build are the only compile; both caught real mistakes (a non-Sendable actor return, a missing `import LedgerCore`, a fixture that did not mirror the native encoder).
- Not tested: a live model choosing to load a skill on its own, the 技能 page on a device, VoiceOver.

## Next

1. The settings-page task adds a 技能 row (`NavigationLink { LedgerAgentSkillsView() }`) next to 记忆; until then the page is reachable only from code.
2. Consider a fourth built-in skill for credit-card statements (`archive_statement` providers `cmb`, `ccb-credit`, `hsbchk-credit`) once the import skills have been used on a real device.
3. Needs a release: `需要发版：新增助手技能（内置与账本里的 SKILL.md、技能开关）`.
