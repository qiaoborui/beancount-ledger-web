#!/usr/bin/env bash
# Xcode post-build phase: record the source commit in the built Info.plist as
# LedgerGitCommit so a running build can say which revision it came from.
# "-dirty" marks uncommitted tracked changes; "unknown" means no Git checkout.
set -euo pipefail

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
commit="unknown"
if git -C "${SRCROOT:?}" rev-parse --git-dir >/dev/null 2>&1; then
  commit="$(git -C "$SRCROOT" rev-parse --short=12 HEAD)"
  if ! git -C "$SRCROOT" diff --quiet HEAD -- 2>/dev/null; then
    commit="${commit}-dirty"
  fi
fi
/usr/libexec/PlistBuddy -c "Delete :LedgerGitCommit" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LedgerGitCommit string $commit" "$plist"
