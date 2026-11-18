#!/usr/bin/env bash
# Build a device archive signed with a paid Apple Developer team, using a
# team-suffixed bundle ID set so a Personal Team build keeps its identifiers.
#
# Usage: bash scripts/build-ios-team-signed.sh --team TEAMID [--device UDID]
#          [--build-number N] [--archive PATH]
#        bash scripts/build-ios-team-signed.sh --team TEAMID --generate-only
#
# The build number defaults to the commit count, so each commit is a higher
# build than the last and SideStore offers it as an update.
#
# The team needs at least one registered device: a development profile cannot be
# generated without one. Connect the phone, trust the Mac, and pass --device to
# register it on the first run.
#
# The suite is signed as:
#   com.qiaoborui.ledger.mobile.<TEAMID>{,.widgets,.share}
#   group.com.qiaoborui.ledger.mobile.<TEAMID>
#
# LedgerSharedAccess recognizes that bundle ID shape (the one iLoader writes) and
# derives the App Group from it, so the app and both extensions agree on the
# group without changing the committed project or entitlements. The team must be
# a paid membership: Personal Team profiles expire in 7 days.
set -euo pipefail

readonly BASE_BUNDLE_ID="com.qiaoborui.ledger.mobile"
readonly BASE_APP_GROUP="group.com.qiaoborui.ledger.mobile"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
project_dir="${repo_root}/App/LedgerMobile"

team=""
device=""
archive=""
build_number=""
generate_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) team="${2:-}"; shift 2 ;;
    --device) device="${2:-}"; shift 2 ;;
    --archive) archive="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --generate-only) generate_only=1; shift ;;
    *) echo "Usage: bash scripts/build-ios-team-signed.sh --team TEAMID [--device UDID] [--archive PATH] [--generate-only]" >&2; exit 1 ;;
  esac
done

if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "--team must be a 10-character Team ID such as ABCDE12345." >&2
  exit 1
fi
if [[ -z "$build_number" ]]; then
  build_number="$(git -C "$repo_root" rev-list --count HEAD)"
fi
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "--build-number must be an integer." >&2
  exit 1
fi
if [[ -n "$archive" && -e "$archive" ]]; then
  echo "Choose a fresh archive path; $archive already exists." >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

alt_bundle_id="${BASE_BUNDLE_ID}.${team}"
alt_app_group="${BASE_APP_GROUP}.${team}"
state_dir="${project_dir}/.build/team-${team}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ios-team.XXXXXX")"
archive="${archive:-${state_dir}/LedgerMobile.xcarchive}"
managed_archive=0
if [[ "$archive" == "${state_dir}/LedgerMobile.xcarchive" ]]; then
  managed_archive=1
fi
destination="generic/platform=iOS"
if [[ -n "$device" ]]; then
  destination="platform=iOS,id=${device}"
fi
finish() { rm -rf "$work_dir"; }
trap finish EXIT

echo "Signing as ${alt_bundle_id} with team ${team}, build ${build_number}."

# Generated inputs the app target links; the same prerequisites as the release
# build. They are cached under server/.build.
if [[ "$generate_only" == 0 ]]; then
  bash "${script_dir}/build-ledgercore-xcframework.sh"
  bash "${script_dir}/build-beancount-ios.sh"
  bash "${script_dir}/build-linux-ios.sh"
fi

rm -rf "${state_dir}/entitlements" "${state_dir}/spec"
mkdir -p "${state_dir}/entitlements" "${state_dir}/spec"
entitlement_sources=(
  "Supporting/LedgerMobilePersonal.entitlements"
  "WidgetExtension/LedgerWidgets.entitlements"
  "ShareExtension/LedgerShare.entitlements"
)
for relative in "${entitlement_sources[@]}"; do
  sed "s|${BASE_APP_GROUP}|${alt_app_group}|g" \
    "${project_dir}/${relative}" > "${state_dir}/entitlements/$(basename "$relative")"
done

python3 - "${project_dir}/project.yml" "${state_dir}/spec/project.yml" \
  "${state_dir}/entitlements" "${BASE_BUNDLE_ID}" "${alt_bundle_id}" \
  "Supporting/LedgerMobilePersonal.entitlements" \
  "WidgetExtension/LedgerWidgets.entitlements" \
  "ShareExtension/LedgerShare.entitlements" <<'PY'
import os
import re
import sys

source, target, entitlements_dir, base_id, alt_id, *entitlements = sys.argv[1:]
rewritten = {}
for relative in entitlements:
    rewritten[relative] = os.path.join(entitlements_dir, os.path.basename(relative))

bundle_pattern = re.compile(r"^(\s*PRODUCT_BUNDLE_IDENTIFIER:\s*)(\S+)\s*$")
entitlement_pattern = re.compile(r"^(\s*CODE_SIGN_ENTITLEMENTS:\s*)(\S+)\s*$")
replaced = 0
with open(source, encoding="utf-8") as handle, open(target, "w", encoding="utf-8") as output:
    for line in handle:
        bundle = bundle_pattern.match(line)
        if bundle and (bundle.group(2) == base_id or bundle.group(2).startswith(base_id + ".")):
            suffix = bundle.group(2)[len(base_id):]
            line = f"{bundle.group(1)}{alt_id}{suffix}\n"
            replaced += 1
        entitlement = entitlement_pattern.match(line)
        if entitlement and entitlement.group(2) in rewritten:
            line = f"{entitlement.group(1)}{rewritten[entitlement.group(2)]}\n"
        output.write(line)

if replaced < 3:
    sys.exit(f"expected at least three bundle identifiers, rewrote {replaced}")
PY

cd "$project_dir"
xcodegen generate --spec "${state_dir}/spec/project.yml" \
  --project "$project_dir" --project-root "$project_dir" --quiet
if [[ "$generate_only" == 1 ]]; then
  echo "Generated ${project_dir}/LedgerMobile.xcodeproj with ${alt_bundle_id}."
  exit 0
fi
if [[ "$managed_archive" == 1 ]]; then
  rm -rf "$archive"
fi
mkdir -p "$(dirname "$archive")"

archive_arguments=(
  archive
  -project "${project_dir}/LedgerMobile.xcodeproj"
  -scheme LedgerMobile
  -configuration Release
  -quiet
  -destination "$destination"
  -derivedDataPath "${work_dir}/DerivedData"
  -archivePath "$archive"
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
  "DEVELOPMENT_TEAM=${team}"
  "CURRENT_PROJECT_VERSION=${build_number}"
  CODE_SIGN_STYLE=Automatic
)
xcodebuild "${archive_arguments[@]}"

app="${archive}/Products/Applications/LedgerMobile.app"
if [[ ! -d "$app" ]]; then
  echo "Archive did not contain LedgerMobile.app." >&2
  exit 1
fi

python3 - "$app" "$alt_bundle_id" "$alt_app_group" <<'PY'
import plistlib
import subprocess
import sys

app, expected_id, expected_group = sys.argv[1:]
with open(f"{app}/Info.plist", "rb") as handle:
    info = plistlib.load(handle)
if info.get("CFBundleIdentifier") != expected_id:
    sys.exit(f"bundle identifier is {info.get('CFBundleIdentifier')}, expected {expected_id}")

profile = subprocess.run(
    ["security", "cms", "-D", "-i", f"{app}/embedded.mobileprovision"],
    check=True, capture_output=True,
).stdout
entitlements = plistlib.loads(profile)["Entitlements"]
groups = entitlements.get("com.apple.security.application-groups") or []
if expected_group not in groups:
    sys.exit(f"profile does not entitle {expected_group}: {groups}")

signed = subprocess.run(
    ["codesign", "-d", "--entitlements", ":-", app],
    check=True, capture_output=True, text=True,
)
sandbox = signed.stdout + signed.stderr
if expected_group not in sandbox:
    sys.exit(f"signed app does not carry {expected_group}")
print(f"Signed {expected_id} with {expected_group}.")
PY

echo "Archive: $archive"
