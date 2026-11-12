# Agent Instructions

This repository is the public application repository for Beancount Ledger Web,
a self-hosted personal finance app built from a Go API/static server and a Vite
/ React 19 web client. It contains application code, safe example ledgers,
documentation, deployment assets, helper scripts, and project agent skills.
Real financial data belongs in a separate private ledger repository configured
through `LEDGER_ROOT`.

## Repository Model

- This repo is public application code: `web/`, `server/`, `examples/`,
  `docs/`, `docker/`, `scripts/`, `.github/`, and `.agents/`.
- A private ledger repo stores `main.bean`, account files, transaction files,
  imports, prices, budgets, and any real financial data.
- The server reads the private ledger through `LEDGER_ROOT`.
- Runtime-only state belongs under `RUNTIME_DIR` and must not be committed.
  This includes passkey stores, notification state, web push subscriptions, and
  write locks.
- Local and CI-safe ledgers live under `examples/`; use them for development,
  tests, docs, and previews.

## Project Shape

- `web/` is the Vite / React 19 app. Scripts are defined in
  `web/package.json`: `pnpm run typecheck`, `pnpm run test`, and
  `pnpm run build`.
- `web/src/components/ledger/` contains the main product UI: pages, mobile
  sheets, modals, notification center, transaction list, command palette,
  import/reconcile flows, and shared ledger UI.
- `web/src/components/ledger/hooks/` contains client-side ledger data,
  mutations, auth, git status, privacy, network, route memory,
  pull-to-refresh, swipe, theme, toast, and web push hooks.
- `web/src/lib/` contains browser/client helpers such as schemas, money,
  time ranges, routing, fetch, and IndexedDB cache.
- `server/` is the Go API and static-file server. The module path and Go
  version live in `server/go.mod`.
- `server/cmd/ledger-web/` builds the server binary.
- `server/internal/app/` contains ledger APIs, auth, WebAuthn/passkey, web
  push, AI parse/chat, imports, notifications, Git operations, cache,
  scheduler, Beancount parsing, and safe ledger writing helpers.
- `examples/minimal-ledger/`, `examples/chinese-personal-ledger/`, and
  `examples/preview-ledger/` are safe sample ledgers.
- `scripts/` contains generic ledger helper scripts and deployment/install
  scripts. They must read external ledger paths from environment/config rather
  than assuming real data lives in this repo.
- `docs/` contains privacy, ledger layout, self-hosting, backend architecture,
  and Ubuntu server deployment documentation.
- `docker/` contains container/deployment examples.
- `.github/workflows/ci.yml` runs the checks of the areas a pull request
  touches; see Validation. `.github/workflows/ios-release.yml` packages and
  publishes the iOS app when a release tag is pushed.
- `.agents/` contains Agent4MD config, durable rules, project knowledge, and
  domain skills.

## iOS App Version

The iOS app is the shipped product. A release is declared by one thing only: an
annotated Git tag `v<MAJOR>.<MINOR>.<PATCH>` on the commit to ship.

- The **version** (`CFBundleShortVersionString`) is the tag's version.
- The **build number** (`CFBundleVersion`) is derived from it as
  `MAJOR*10000 + MINOR*100 + PATCH` (v1.4.3 → 10403), so a newer release always
  carries a higher build, which SideStore and AltStore require to offer it as an
  update. MINOR and PATCH stay below 100.

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`App/LedgerMobile/project.yml` are local development values only. Packaging
overrides them for the app, Widget, and Share targets and never writes them back.
Feature, fix, documentation, test, and CI PRs leave them alone, and there are no
version-bump or "record build" PRs. Merging never releases anything; state in the
PR body that a release is needed (`需要发版：新增 <capability>`) so it is not
forgotten.

### Cutting a release

Follow `.agents/skills/ios-release/SKILL.md` for the full runbook: choosing
the version, writing the notes, watching the run, verifying the source, and
recovering from a failed run.

When a batch of merged PRs is ready, tag the `main` commit to ship and push the
tag:

```bash
git tag -a --cleanup=whitespace v<version> -F notes.md
git push origin v<version>
```

- +PATCH by default, whether the batch adds capabilities or only fixes, so
  releases go 1.4.1 → 1.4.2 → 1.4.3; +MINOR only when the maintainer asks for
  one to mark a milestone.
- The tag message carries the release notes. Its first line is a title and is
  dropped; the rest is written in Chinese for users, one line per change with
  its PR number. A line that is exactly `---` ends the part shown in SideStore.
  `--cleanup=whitespace` keeps `## ` headings, which `git tag` otherwise strips
  as comments.
- The push runs `.github/workflows/ios-release.yml`, which packages the IPA on
  the Mac runner, uploads it to the `v<version>` release of the public
  `beancount-ledger-releases` repository, and adds it to `sidestore/source.json`
  there. Pushing a tag publishes; confirm with the maintainer first.

Manual fallback: from a checkout of the tag, run
`bash scripts/build-ios-ipa.sh --private-local <new-dir>` and then
`python3 scripts/publish-sidestore-release.py --public <ipa> --notes <body.md>`,
with `--dry-run` first. That script publishes its notes file as-is, so pass the
body without the title line or anything after `---`. `build-ios-ipa.sh` refuses a commit without a release tag
or with a tag that is not the newest one.

Other rules:

- Never move or delete a tag. A broken release is fixed by a new, higher tag.
- Tags are compared as version numbers, not by commit date, so tagging an older
  commit cannot move the shipped version backwards.
- `FEATURE_PARITY.md` next to the Xcode project records what the app actually
  implements. Update it in the same change that ships or removes a capability.
  Do not list planned work as if it were available.

## Development Workflow

- For new feature development, create a focused branch first and open a pull
  request. Use the `codex/` branch prefix by default unless the user asks for a
  different naming convention.
- Keep PRs small and focused. Include validation results in the PR body when
  creating or updating a PR.
- After completing feature work, make sure a pull request exists. After opening
  or updating a PR, check the PR status, mergeability, and conflict state; if
  conflicts are reported, resolve them before handing the work back.
- Merging to `main` builds and deploys nothing. The only workflows are `ci.yml`
  and `ios-release.yml`, which runs only for a pushed release tag. Do not add
  deployment or image-publishing workflows back without an explicit request.
- When several dependent features must land serially, use Graphite stacked PRs
  instead of mixing the work into one large branch.
- Avoid starting the local dev server by default. Prefer static checks, tests,
  and builds unless the user explicitly asks for local runtime testing.
- Preserve unrelated worktree changes. Never reset, checkout, or revert user
  changes unless explicitly requested.

## Durable Progress and Handoff

- Do not rely on chat history, a context summary, or a `tape.handoff` anchor
  alone to preserve task progress. Save a concise handoff to disk before a
  context reset, window/session switch, planned interruption, or final handoff
  with unfinished work. Checkpoint after meaningful milestones as well.
- Use two layers with the same unique task ID, such as
  `20260921-context-budget`:
  - **Shared project handoff:** `docs/handoffs/<task-id>.md`, tracked by Git.
    Record sanitized goals, decisions, progress, remaining steps, and validation
    so an agent in another clone can resume. Use repository-relative paths.
  - **Local checkpoint:** `agent-handoffs/<task-id>.md` under the directory
    returned by `git rev-parse --path-format=absolute --git-common-dir`.
    Record machine-specific paths, uncommitted work, temporary processes, and
    internal remote maintenance or backup locations here, not in shared notes.
    This location is shared by linked worktrees but is not synced by Git.
    Create it when needed; do not assume `.git` is a directory.
- Save frequent checkpoints locally. Before cross-machine handoff or submitting
  a meaningful milestone, update the sanitized shared handoff alongside the
  relevant code changes. Do not copy local notes wholesale into the public repo.
  A handoff file is not a backup of a diff: preserve the actual worktree too.
- A cross-machine handoff requires the relevant code and shared note to be
  committed and pushed to the intended branch through the normal approved
  workflow. Record the branch and code revision covered by the note; do not try
  to embed the note's own containing commit hash. If work remains uncommitted or
  unpushed, explicitly say it is local-only and not ready in another clone.
  These rules do not authorize pushing unrelated changes or private data.
- At the start of a new session, inspect `docs/handoffs/` and the local checkpoint
  directory for relevant active or blocked tasks. If several tasks could match
  the user's request, clarify which one to resume. If a note is missing or
  inaccessible, say so; do not invent prior progress.
- Each task handoff must let an agent without chat history understand:
  - Task ID, status (`active`, `blocked`, or `completed`), and last-updated time
    with timezone.
  - User goal, acceptance criteria, scope, and approved decisions or limits.
  - Branch, code revision, and PR link if one exists. Keep absolute worktree
    paths in the local checkpoint only.
  - Completed work, in-progress work, and remaining steps in execution order.
  - Changed files and whether work is committed/pushed; local checkpoints also
    distinguish task edits from pre-existing or unrelated uncommitted changes.
  - Validation commands, results, revision/state tested, and what was not tested.
  - Blockers, failed attempts, open questions, and the next concrete action.
  - For remote operations, keep internal targets, deployed revisions, verification
    details, and backup/rollback locations in the local checkpoint; shared notes
    contain only project-relevant information safe for public disclosure.
- Update only the relevant task notes; never overwrite another task's progress.
  Write updates to a temporary file in the same directory and atomically rename
  it into place. Keep notes concise and current, not transcripts or raw logs.
  Mark completed tasks explicitly in each existing layer to avoid repeated work.
- Before resuming, compare notes with current Git status, diffs, branch/HEAD,
  and relevant remote service or PR state. Neither layer overrides live evidence;
  resolve stale or conflicting notes before acting. Notes are checkpoints, not
  authorization for destructive actions. Preserve unrelated changes and
  revalidate stale results.
- In the user-facing handoff and any `tape.handoff` summary, include the task ID,
  note location(s), current status, and next step. Give the shared path and branch
  when available. In replies, refer to local notes as
  `$GIT_COMMON_DIR/agent-handoffs/<task-id>.md` rather than exposing absolute
  machine paths; resolve `GIT_COMMON_DIR` with the Git command above.
  A new clone does not contain local checkpoints; transfer any necessary local
  context only after sanitization through an approved private channel.
- Never store secrets, real ledger entries, or sensitive tool output in either
  layer. Before committing shared notes, review them for private paths, internal
  infrastructure details, and other sensitive metadata. Local checkpoints must
  never be committed to this public repository.

## Safety Rules

- Do not commit private ledger data, `.env*` secrets, runtime state, passkey
  stores, web push subscription stores, notification stores, imported bill
  files, or generated private-ledger artifacts.
- Keep private-ledger paths outside this repo. Root-level `main.bean`,
  `accounts.bean`, `budgets.bean`, `commodities.bean`, `prices.bean`,
  `transactions/`, `imports/`, and `ledgers/` are ignored for this reason.
- Keep financial writes manual-first: preview, validate, then append.
- Use existing Beancount parsers, ledger writers, analytics helpers, caches,
  schemas, and path helpers before introducing new parsing or write logic.
- Use `bean-check` validation paths where ledger writes are involved, and keep
  rollback behavior intact.
- Sensitive values must remain hidden until password or passkey unlock paths
  allow access.
- For UI work, follow the existing mobile-first product patterns in
  `web/src/components/ledger/` before adding new abstractions.
- Keep changes narrowly scoped to the requested behavior.

## Validation

Run the smallest useful checks for the change. For frontend changes, run from
`web/`:

```bash
pnpm run typecheck
pnpm run test
```

For build, dependency, deployment, or broad UI changes, also run from `web/`:

```bash
pnpm run build
```

For backend changes, run from `server/`:

```bash
go test ./...
go build ./cmd/ledger-web
```

CI uses Node.js 24 for the frontend job and the Go version declared in
`server/go.mod` for the backend job. Each CI job is one area, and
`.github/scripts/plan-components.sh` maps a pull request's changed paths to
areas (its test is `.github/scripts/test_plan_components.py`):

| Changed path | Jobs |
|---|---|
| `web/` | Frontend |
| `agent/`, `.agents/` | Bub Agent |
| `server/` code that LedgerCore compiles (`mobile*/`, most of `internal/`) | Backend, iOS app |
| `server/` Go tests, `cmd/`, `internal/httpservice/`, `internal/logging/`; `examples/` | Backend |
| `App/LedgerMobile/Runtime/` | iOS Beancount runtime, Backend, iOS app |
| `App/LedgerMobile/Package.swift`, and the `Sources/` files it lists | iOS core (those files also iOS app) |
| `App/LedgerMobile/Tests/` | iOS core, iOS app |
| `App/LedgerMobile/project.yml` | iOS app, iOS widgets |
| other `Sources/`, and `Resources/`, `Supporting/`, `ShareExtension/`, `UITests/` under `App/LedgerMobile/` | iOS app |
| `WidgetExtension/`, `WidgetTests/` under `App/LedgerMobile/`, and the shared files the widget targets list in `project.yml` | iOS widgets |
| Markdown and `Screenshots/` under `App/` | nothing |
| other `App/` | iOS core |
| the app's framework and build-phase scripts under `scripts/` | iOS app |
| `docker/`, `scripts/selfhost/`, `.env.selfhost.example`, `.dockerignore` | Self-hosted stack |
| IPA packaging and SideStore publishing scripts | Release tooling |
| `.github/workflows/`, the planner and its test | every job except iOS UI tests |
| docs and anything unmatched | nothing |

A manual run checks every area. `Gate` is the required status check: it
passes only when every planned job succeeded and every other job was skipped.
When a new directory needs CI, add it to the planner and its test in the same
change. The iOS jobs run on the self-hosted Mac runner, one at a time, and
select their Xcode through `.github/scripts/select-xcode.sh`. iOS core runs
`swift test` in `App/LedgerMobile` on the portable core, but Package.swift
leaves out the app's UI layer, widgets and share extension. iOS app and iOS
widgets compile those with `.github/scripts/ios-app-check.sh`: iOS app builds
the LedgerMobile scheme for a simulator and runs `LedgerMobileTests`, and iOS
widgets builds the LedgerWidgets scheme and runs `LedgerWidgetsTests`. The UI
tests are flaky under load, so pull requests only compile them; run them by
starting CI manually with `ui_tests` checked
(`gh workflow run ci.yml --ref <branch> -f ui_tests=true`). A full run skips
`BalancedScreenshotTests` and `BalancedStreamAScreenshotTests`, which capture
App Store screenshots instead of checking behaviour. `ui_tests_only` narrows a
run to the classes or `Class/testMethod` entries it lists, separated by spaces
or commas and without the target prefix; the name `smoke` expands to the
pre-release set defined in `.github/scripts/ios-app-check.sh` (the overview's
tab and search navigation, the accounts and 更多 pages at accessibility sizes,
and a local ledger restarting without placeholder cards). Before a release, run
`gh workflow run ci.yml --ref main -f ui_tests=true -f ui_tests_only="smoke"`,
adding the UI tests of each PR in the batch to that list when there are any.

When an integration-level behavior depends on hosted infrastructure, GitHub API
ledger storage, the Postgres read model, or hosted runtime configuration, prefer
using the dedicated test/preview environment instead of production. The public
demo ledger repository and preview Supabase database may be used for agent-run
integration tests, write-path smoke tests, and deployment verification. Keep
test writes confined to that environment, document any mutations in the handoff,
and never point automated agent tests at the private production ledger unless
the user explicitly asks for it.

## Agent4MD Memory and Skills

The project-level Agent4MD entrypoint is this file. Supporting memory lives
under `.agents/`:

- `.agents/config.yaml` declares this entrypoint, validation commands,
  knowledge files, rule files, and the skills directory.
- `.agents/rules/project.md` contains durable project rules.
- `.agents/knowledge/project.md` contains project context that agents can load
  as needed.
- `.agents/skills/alipay-bill-import/` supports Alipay CSV bill imports.
- `.agents/skills/wechat-bill-import/` supports WeChat Pay XLSX bill imports.
- `.agents/skills/beancount-bookkeeping/` supports manual-first bookkeeping
  drafts and appends.
- `.agents/skills/beancount-insights/` supports read-only ledger analysis.
- `.agents/skills/ios-release/` is the step-by-step runbook for cutting,
  verifying, and recovering an iOS release.
- `.agents/skills/telegram-ledger-agent/` supports Telegram-facing ledger
  flows.

When a task matches one of these skills, read that skill's `SKILL.md` and use
its workflow. Keep context small by loading only the referenced files needed for
the current task.
