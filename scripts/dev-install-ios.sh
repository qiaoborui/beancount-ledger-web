#!/usr/bin/env bash
# Build the iOS app signed with the paid team and install it on a connected
# iPhone, for trying a change on the device. Nothing is tagged, archived or
# uploaded; the version is project.yml's and the build number the commit count.
#
# Usage (or `make install-dev [PR=748 | REF=<ref>] [DEVICE=<name|UDID>]`):
#   bash scripts/dev-install-ios.sh            # this checkout, uncommitted edits included
#   bash scripts/dev-install-ios.sh 748        # pull request #748
#   bash scripts/dev-install-ios.sh origin/main
#
# A pull request or ref is built in a separate worktree, so this checkout is
# left alone. That worktree and the build products live under
# LEDGER_DEV_CACHE (default ~/Library/Caches/ledger-dev-install); the generated
# frameworks are copied from this checkout's server/.build when it has them, so
# only LedgerCore is rebuilt there.
#
# DEVICE picks the device by name or UDID; by default the first physical iPhone
# devicectl lists. If it is locked or not reachable, the install is retried for
# WAIT seconds (default 300): unlock the phone and keep it on USB or the same
# Wi-Fi. LAUNCH=0 skips opening the app afterwards.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
target="${1:-${PR:-${REF:-}}}"
cache="${LEDGER_DEV_CACHE:-$HOME/Library/Caches/ledger-dev-install}"
wait_seconds="${WAIT:-300}"
device="${DEVICE:-}"

# Some build scripts default to Xcode-beta, so name the Xcode to use.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  else
    DEVELOPER_DIR="$(xcode-select -p)"
    export DEVELOPER_DIR
  fi
fi
# The main checkout (not a linked worktree) usually holds the built frameworks.
main_root="$(dirname "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)")"

# Pick the device first, so a missing phone fails before a long build.
device_line() {
  xcrun devicectl list devices 2>/dev/null | grep -E ' physical *$' | grep -E 'iPhone|iPad' |
    if [[ -n "$device" ]]; then grep -F -- "$device"; else grep 'iPhone'; fi | head -n 1
}
line="$(device_line || true)"
if [[ -z "$line" ]]; then
  echo "No ${device:-iPhone} found by 'xcrun devicectl list devices'. Connect the phone, unlock it and trust this Mac, or set DEVICE." >&2
  exit 1
fi
udid="$(grep -oE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' <<<"$line" | head -n 1)"
echo "Device: $(sed -E 's/ {2,}/ | /g' <<<"$line")"

# Source tree to build.
src="$repo_root"
if [[ -n "$target" ]]; then
  src="$cache/worktree"
  if [[ "$target" =~ ^#?[0-9]+$ ]]; then
    number="${target#\#}"
    git -C "$repo_root" fetch --quiet origin "pull/${number}/head"
    commit="$(git -C "$repo_root" rev-parse FETCH_HEAD)"
    label="PR #${number}"
  else
    git -C "$repo_root" fetch --quiet origin 2>/dev/null || true
    git -C "$repo_root" rev-parse --verify --quiet "${target}^{commit}" >/dev/null || {
      echo "Unknown ref: $target" >&2; exit 1; }
    commit="$(git -C "$repo_root" rev-parse "${target}^{commit}")"
    label="$target"
  fi
  if [[ ! -e "$src/.git" ]]; then
    mkdir -p "$cache"
    git -C "$repo_root" worktree prune
    git -C "$repo_root" worktree add --quiet --detach "$src" "$commit"
  else
    git -C "$src" checkout --quiet --force --detach "$commit"
    git -C "$src" clean -fdq
  fi
fi
# Seed the slow, rarely changing frameworks from the main checkout.
if [[ "$src" != "$main_root" ]]; then
  mkdir -p "$src/server/.build"
  for name in beancount-ios linux-ios gomobile; do
    if [[ ! -e "$src/server/.build/$name" && -d "$main_root/server/.build/$name" ]]; then
      cp -cR "$main_root/server/.build/$name" "$src/server/.build/$name"
      [[ "$name" != beancount-ios ]] || seeded_runtime=1
    fi
  done
  export LEDGER_LINUX_SEED="${LEDGER_LINUX_SEED:-$main_root/server/.build/linux-ios}"
fi
if [[ -z "$target" ]]; then
  commit="$(git -C "$src" rev-parse HEAD)"
  label="this checkout ($(git -C "$src" rev-parse --abbrev-ref HEAD))"
  git -C "$src" diff --quiet HEAD -- || label="$label with uncommitted changes"
fi
echo "Building ${label} at ${commit:0:8}."

# A framework is rebuilt only when its sources changed since it was built here.
# tree_of <checkout> <path>: the committed tree plus any uncommitted diff.
tree_of() {
  echo "$(git -C "$1" rev-parse "HEAD:$2")-$(git -C "$1" diff HEAD -- "$2" | git hash-object --stdin)"
}
rebuild_if_changed() { # <product> <sources> <script>
  local stamp="$src/server/.build/$1.dev-install-tree" tree
  tree="$(tree_of "$src" "$2")"
  if [[ ! -d "$src/server/.build/$1" || "$(cat "$stamp" 2>/dev/null)" != "$tree" ]]; then
    bash "$src/scripts/$3"
    echo "$tree" >"$stamp"
  fi
}
if [[ -n "${seeded_runtime:-}" ]]; then
  # The copied runtime was built from the main checkout's Runtime sources.
  tree_of "$main_root" App/LedgerMobile/Runtime >"$src/server/.build/beancount-ios/BeancountRuntime.xcframework.dev-install-tree"
fi
rebuild_if_changed ledgercore/LedgerCore.xcframework server build-ledgercore-xcframework.sh
rebuild_if_changed beancount-ios/BeancountRuntime.xcframework App/LedgerMobile/Runtime build-beancount-ios.sh
rebuild_if_changed linux-ios/LedgerLinux.xcframework App/LedgerMobile/Linux build-linux-ios.sh

project_dir="$src/App/LedgerMobile"
team="$(sed -n 's/^ *LEDGER_TEAM_ID: *\([A-Z0-9]*\) *$/\1/p' "$project_dir/project.yml" | head -n 1)"
derived="$cache/DerivedData-$(basename "$src")"
(cd "$project_dir" && xcodegen generate --spec project.yml --quiet)
# -quiet prints a harmless "command failed with exit code 0" line; the exit
# status is what counts.
xcodebuild build \
  -project "$project_dir/LedgerMobile.xcodeproj" \
  -scheme LedgerMobile \
  -configuration Release \
  -quiet \
  -destination generic/platform=iOS \
  -derivedDataPath "$derived" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  "LEDGER_TEAM_ID=${team}" \
  LEDGER_BUNDLE_ID=com.qiaoborui.ledger \
  LEDGER_APP_GROUP=group.com.qiaoborui.ledger \
  "CURRENT_PROJECT_VERSION=$(git -C "$src" rev-list --count HEAD)" \
  CODE_SIGN_STYLE=Automatic

app="$derived/Build/Products/Release-iphoneos/LedgerMobile.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Info.plist")"

log="$(mktemp "${TMPDIR:-/tmp}/ledger-dev-install.XXXXXX")"
trap 'rm -f "$log"' EXIT
deadline=$((SECONDS + wait_seconds))
until xcrun devicectl device install app --device "$udid" "$app" >"$log" 2>&1; do
  if ((SECONDS >= deadline)); then
    grep -E 'ERROR|error' "$log" | head -n 3 >&2
    echo "Install failed. Unlock the phone, keep it on USB or the same Wi-Fi, then run this again." >&2
    exit 1
  fi
  if [[ -z "${waiting:-}" ]]; then
    waiting=1
    echo "The device is not reachable yet (locked or disconnected). Retrying for ${wait_seconds}s; unlock it."
  fi
  sleep 5
done
echo "Installed ${version} (${build}) from ${label} at ${commit:0:8}."
if [[ "${LAUNCH:-1}" != 0 ]]; then
  xcrun devicectl device process launch --device "$udid" --terminate-existing com.qiaoborui.ledger >/dev/null 2>&1 ||
    echo "Open the app on the phone (it could not be launched while locked)."
fi
