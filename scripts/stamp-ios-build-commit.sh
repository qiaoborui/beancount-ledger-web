#!/usr/bin/env bash
# Xcode post-build phase: record the source commit in the built Info.plist as
# LedgerGitCommit so a running build can say which revision it came from.
# "-dirty" marks uncommitted tracked changes; "unknown" means no Git checkout.
set -euo pipefail

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
commit="unknown"
if git -C "${SRCROOT:?}" rev-parse --git-dir >/dev/null 2>&1; then
  commit="$(git -C "$SRCROOT" rev-parse --short=12 HEAD)"
  # Packaging advances CURRENT_PROJECT_VERSION in project.yml before archiving so
  # the number survives the run, and passes the same values to xcodebuild, so the
  # build does not depend on that edit. It belongs to the packaging step rather
  # than to the source, and counting it would stamp every shipped IPA "-dirty".
  # Ignore that one file so the suffix reflects real uncommitted changes only.
  # `:(top,…)` anchors the path at the repository root, which sits above SRCROOT.
  manifest="$(git -C "$SRCROOT" rev-parse --show-prefix)project.yml"
  if ! git -C "$SRCROOT" diff --quiet HEAD -- . ":(top,exclude)$manifest" 2>/dev/null; then
    commit="${commit}-dirty"
  fi
fi
/usr/libexec/PlistBuddy -c "Delete :LedgerGitCommit" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LedgerGitCommit string $commit" "$plist"
