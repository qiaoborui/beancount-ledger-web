# 20260921-durable-handoff-instructions

- Status: completed (documentation); publication tracked by the branch and PR.
- Updated: 2026-09-21T10:09:07.806946+08:00
- Goal and acceptance: Require durable progress notes that let agents resume in a
  new window or clone, with Git-tracked sanitized notes and private local checkpoints.
- Scope/approval: User approved the two-layer design. Documentation only; no
  application changes or remote maintenance. User subsequently approved commit/push.
- Branch: `codex/durable-handoff-instructions`; base code revision: `7b1efbc42701a07406b829858afe1e9856fdcdbb`.
- Documentation revision: `334517f`, committed and pushed to the branch above.
- PR: https://github.com/qiaoborui/beancount-ledger-web/pull/403 (awaiting review).
- Completed: Updated `AGENTS.md` with both locations, checkpoint triggers,
  discovery, required contents, atomic writes, live-state revalidation, publication
  requirements, privacy boundaries, and completed-task marking. Created this note.
- Changed files: `AGENTS.md`, `docs/handoffs/20260921-durable-handoff-instructions.md`.
- Validation: `git diff --check` passed for the documentation edit; shared note
  reviewed for private paths, credentials, financial data, and internal targets.
  No runtime tests: documentation only.
- In progress / blockers: none. No failed attempts in this documentation task.
- Remaining / next step: Review and merge the documentation PR; no application
  implementation remains. Multi-worktree concurrency rules were not added.
