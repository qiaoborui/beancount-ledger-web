---
name: "ios-release"
description: "Cut and publish an iOS release of Ledger: choose the version, write Chinese release notes, push an annotated vX.Y.Z tag on main, watch the ios-release workflow, verify the SideStore source, and recover from failed runs."
globs:
  - ".github/workflows/ios-release.yml"
  - "scripts/ios-release-version.sh"
  - "scripts/build-ios-ipa.sh"
  - "scripts/publish-sidestore-release.py"
alwaysAllow:
  - "Bash"
---

# iOS Release Skill

Use this skill when the maintainer asks to ship the iOS app: 发版, 发个版本, 打 tag 发布,
release, publish to SideStore. The rules behind it are in the "iOS App Version" section of
`AGENTS.md`; this file is the step-by-step runbook.

Pushing a release tag **publishes immediately**: the IPA becomes publicly downloadable and
every phone with the SideStore source sees the update. Do it only when the maintainer has
asked for this release, and show them the version and notes before pushing. A pushed tag uses
up its version even if the run fails, because tags are never moved or deleted.

## How a release works

- The only input is an annotated tag `v<MAJOR>.<MINOR>.<PATCH>` on a `main` commit. There is
  no version-bump PR before it and no build-number commit after it.
- `scripts/ios-release-version.sh` reads the version from the tag on HEAD and derives the build
  number `MAJOR*10000 + MINOR*100 + PATCH` (v1.4.3 → 10403). It refuses an untagged HEAD, a
  tag that is not the newest release tag, and MINOR or PATCH of 100 or more. Tags with leading
  zeros or suffixes (`v1.04.3`, `v1.4.3-rc1`) do not count as release tags.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `App/LedgerMobile/project.yml` are local
  development values. Packaging overrides them; never edit them for a release.
- The tag push runs `.github/workflows/ios-release.yml`. It calls the shared reusable workflow
  in `Ami0307/tethera-releases` (pinned by SHA) on the self-hosted Mac runner (label
  `ledger-ios`). That workflow runs `scripts/build-ios-ipa.sh`, checks the IPA (tag matches the
  version, bundle names are ASCII), creates the `v<version>` release of
  `qiaoborui/beancount-ledger-releases`, uploads the IPA, marks the release Latest, and only then
  adds the version to `sidestore/source.json` there.

## Steps

### 1. Check that main is ready

```bash
git fetch origin main --tags
git log --oneline -1 origin/main
```

Release from `origin/main` only; never tag a feature branch or an unmerged commit. CI runs on
pull requests only, so check the PRs merged since the last release with `gh pr checks <number>`
rather than `gh run list --branch main`.

### 2. Choose the version

Find the newest release tag and what is live in the source. They can differ when a tagged run
failed or was cancelled before publishing: v1.4.2 is such a tag, pushed but never published.

```bash
git tag --list 'v*' | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 3
gh api repos/qiaoborui/beancount-ledger-releases/contents/sidestore/source.json \
  -H 'Accept: application/vnd.github.raw' \
  | jq -r '.apps[0].versions[:3][] | "\(.version) (\(.buildVersion))"'
```

The new version is the newest **tag** +PATCH (1.4.3 → 1.4.4), whether the batch adds features
or only fixes. Bump MINOR only when the maintainer asks for it. A version whose tag already
exists is never reused, even if it was never published.

### 3. Write the release notes

List what changed since the last **published** version (the top of `source.json`), not since
the last tag:

```bash
git log --first-parent --merges --format='%s' v<last-published>..origin/main
```

If the log is empty, or nothing in it is visible to users, do not tag: tell the maintainer
there is nothing to release and stop.

Write the notes file outside the repository, for example `/tmp/notes-1.4.4.md`:

```markdown
1.4.4: short English title

## 改进
- 面向用户的中文描述，一条一个改动，附 PR 号（#650）
## 修复
- 修复……的问题（#651）
```

- The first line is a title and is dropped from the published notes.
- The body is Chinese, written for users: what they will notice, one line per change, each
  with its PR number. Leave out changes users cannot see (CI, docs, tests, refactors).
- Optional: a line that is exactly `---` ends the part shown in SideStore; the GitHub Release
  shows everything.
- The "Read release notes from the tag" step fails when there is no text between the title line
  and the first `---` (or the end of the message).

Show the version and notes to the maintainer and wait for their go-ahead.

### 4. Tag and push

```bash
sha="$(git rev-parse origin/main)"
git tag -a --cleanup=whitespace v1.4.4 "$sha" -F /tmp/notes-1.4.4.md
git tag -l --format='%(contents)' v1.4.4     # the notes must read exactly as written
git push origin v1.4.4
```

`--cleanup=whitespace` is required for headings: by default `git tag` strips every line that
starts with `#` as a comment, so `## 改进` would silently disappear.

Optionally confirm the derived numbers before pushing; the resolver must print `1.4.4 10404`:

```bash
git worktree add --detach /tmp/ledger-v144 v1.4.4
bash /tmp/ledger-v144/scripts/ios-release-version.sh /tmp/ledger-v144
git worktree remove /tmp/ledger-v144
```

### 5. Watch the run

```bash
gh run list --workflow ios-release.yml --branch v1.4.4 --limit 1   # repeat until it appears
gh run watch <run-id> --exit-status
```

A run takes about 5 minutes (v1.4.3: about 4.5 minutes, Build about 3); the job timeout is 45.
Steps: Check trigger, Check out the tag, Check out release tools, Read release notes from the
tag, Build, Verify (always skipped: no `verify-command` is configured), Inspect IPA, Publish.

### 6. Verify what was published

```bash
gh release view v1.4.4 -R qiaoborui/beancount-ledger-releases --json assets -q '.assets[].name'
gh api repos/qiaoborui/beancount-ledger-releases/contents/sidestore/source.json \
  -H 'Accept: application/vnd.github.raw' \
  | jq -r '.apps[0] | "legacy: \(.version)", (.versions[:2][] | "\(.version) (\(.buildVersion))")'
```

Expect the assets `LedgerMobile-<version>-<build>-SideStore.ipa` plus its `.sha256` and
`.build-info.txt`, and `<version> (<build>)` at the top of the source. Report both to the
maintainer and suggest refreshing the source in SideStore on a phone; an agent cannot confirm
the on-device install.

## When a run fails

Read the failing step first: `gh run view <run-id> --log-failed | tail -80`.

- **Read release notes from the tag** (lightweight tag, or no notes before the first `---`):
  nothing was built. A rerun cannot help, because the notes come from the tag message. Write
  correct notes and push the next PATCH as an annotated tag; the bad tag stays.
- **Build or Inspect IPA**: nothing was uploaded and the source is unchanged.
  - Runner-only problem (a tool missing on the Mac such as bison or xcodegen, disk space, an
    Xcode install): once the runner is fixed, `gh run rerun <run-id> --failed`. The tag and the
    derived build number stay the same.
  - Problem in the repository (compile error, non-ASCII bundle name, `select-xcode.sh` or the
    build command): a rerun builds the tag's commit again and will not pick up a fix. Fix it
    through a normal PR, merge, and release the next PATCH.
  - A rerun works only while its tag is still the newest release tag. Once a higher tag exists,
    the rerun fails with "is not the newest release tag"; skip that version.
- **Publish failed on a network or GitHub error**: the release may exist without the source
  update. Rerunning the same run is safe: uploads replace the same-named assets, and the source
  replaces the entry for the same version and build in place.
- **Publish refused by the source** — these come after the release was already created, the IPA
  uploaded, and the release marked Latest, so a stray release now exists although the source is
  unchanged. Report it to the maintainer; do not delete it yourself.
  - "source already has newer version V": the tag is older than a published version. Release a
    version above V; a successful publish takes Latest back.
  - "build X is not above build Y of V" or "build X of A is not below build Y of the newer B":
    the derived build collides with a listed build (for example a hand-set legacy build).
    Report it instead of retagging blindly.
- **Cancelled run**: cancelled by hand, or by GitHub when a newer tag's run is queued while this
  one is still pending (the job's concurrency group keeps one pending run). If it stopped before
  Publish, nothing was published; rerun it if its tag is still the newest, otherwise skip the
  version. If it stopped during Publish, treat it as a failed Publish.

## Manual fallback

Only when the workflow cannot run (runner offline) and the maintainer agrees. It mirrors the
workflow's build command:

```bash
git worktree add --detach /tmp/ledger-v144 v1.4.4    # the pushed tag
cd /tmp/ledger-v144
source .github/scripts/select-xcode.sh
export PATH="/opt/homebrew/bin:$PATH"
bash scripts/build-ios-ipa.sh --private-local /tmp/ledger-ipa-1.4.4   # must not exist yet
# The script publishes its notes file as-is: no title line, nothing after `---`.
tail -n +2 /tmp/notes-1.4.4.md | sed '/^---$/,$d' > /tmp/notes-1.4.4-body.md
python3 scripts/publish-sidestore-release.py --public \
  /tmp/ledger-ipa-1.4.4/LedgerMobile-1.4.4-10404-SideStore.ipa --notes /tmp/notes-1.4.4-body.md --dry-run
# then the same command without --dry-run
```

`publish-sidestore-release.py` refuses: without `--public`; an IPA whose `v<version>` tag is
missing locally, not pushed, or not the newest; one whose `build-info.txt` does not record a
clean worktree at the tag's commit on `origin/main`; a version already in the source or not
above the newest listed one; a build not above every listed build; and an existing
`v<version>` release whose IPA asset has a different sha256. So it cannot finish a release that
a workflow run partly published; rerun the workflow for that. It uploads only the IPA and its
`.sha256`, not `.build-info.txt`.

## Never

- Never move, delete, or re-point a tag, local or remote. A broken release is fixed by a new,
  higher tag.
- Never reuse a version or lower a build number.
- Never edit `project.yml` versions, or open a version-bump or "record build" PR, for a release.
- Never edit `sidestore/source.json` or releases in the releases repository by hand.
- Never push a tag the maintainer has not approved, and never put private ledger data in the
  notes.
