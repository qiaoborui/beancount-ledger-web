#!/usr/bin/env bash
# Archive the app signed with the paid Apple Developer team, and optionally
# upload it to App Store Connect for TestFlight.
#
# Usage:
#   bash scripts/build-ios-team-signed.sh [--team TEAMID] [--device UDID]
#        [--build-number N] [--marketing-version X.Y.Z] [--archive PATH]
#   bash scripts/build-ios-team-signed.sh --testflight [--team TEAMID]
#
# project.yml already signs as the paid team (LEDGER_TEAM_ID) with
#   com.qiaoborui.ledger.mobile.<TEAMID>{,.widgets,.share}
#   group.com.qiaoborui.ledger.mobile.<TEAMID>
# --team passes another team through the same build settings; LedgerSharedAccess
# derives the App Group from that bundle ID shape, so the app and both
# extensions agree without editing the project.
#
# Development archive (default): the build number defaults to the commit count,
# so each commit is a higher build than the last. The team needs at least one
# registered device before a development profile can be generated: connect the
# phone, trust the Mac and pass --device on the first run.
#
# --testflight: HEAD must carry the newest v<X.Y.Z> tag, which sets the version
# and build exactly as for the SideStore package (scripts/ios-release-version.sh).
# The archive is exported for App Store Connect and uploaded; it shows up in
# TestFlight once Apple has processed it. Signing and the upload authenticate
# with an App Store Connect API key (Admin or App Manager role, so Xcode can
# create the distribution certificate and profiles), read from:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_<id>.p8)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
project_dir="${repo_root}/App/LedgerMobile"

team=""
device=""
archive=""
build_number=""
marketing_version=""
testflight=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) team="${2:-}"; shift 2 ;;
    --device) device="${2:-}"; shift 2 ;;
    --archive) archive="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --marketing-version) marketing_version="${2:-}"; shift 2 ;;
    --testflight) testflight=1; shift ;;
    *) echo "Usage: bash scripts/build-ios-team-signed.sh [--team TEAMID] [--device UDID] [--build-number N] [--marketing-version X.Y.Z] [--archive PATH] [--testflight]" >&2; exit 1 ;;
  esac
done

if [[ -z "$team" ]]; then
  team="$(sed -n 's/^ *LEDGER_TEAM_ID: *\([A-Z0-9]*\) *$/\1/p' "${project_dir}/project.yml" | head -n 1)"
fi
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "--team must be a 10-character Team ID such as ABCDE12345." >&2
  exit 1
fi

auth_arguments=()
if [[ "$testflight" == 1 ]]; then
  if [[ -n "$build_number" || -n "$marketing_version" || -n "$device" ]]; then
    echo "--testflight takes the version and build from the release tag; drop --build-number, --marketing-version and --device." >&2
    exit 1
  fi
  for variable in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    if [[ -z "${!variable:-}" ]]; then
      echo "--testflight needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (App Store Connect API key)." >&2
      exit 1
    fi
  done
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "ASC_KEY_PATH does not point to a file." >&2
    exit 1
  fi
  auth_arguments=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  # Resolved before the slow framework builds, so an untagged commit fails fast.
  read -r marketing_version build_number < <(bash "${script_dir}/ios-release-version.sh" "$repo_root")
  [[ -n "${build_number:-}" ]] || exit 1
fi

if [[ -z "$build_number" ]]; then
  build_number="$(git -C "$repo_root" rev-list --count HEAD)"
fi
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "--build-number must be an integer." >&2
  exit 1
fi
if [[ -n "$marketing_version" && ! "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--marketing-version must look like 1.4.32." >&2
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

bundle_id="com.qiaoborui.ledger.mobile.${team}"
app_group="group.com.qiaoborui.ledger.mobile.${team}"
state_dir="${project_dir}/.build/team-${team}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ios-team.XXXXXX")"
archive="${archive:-${state_dir}/LedgerMobile.xcarchive}"
if [[ "$archive" == "${state_dir}/LedgerMobile.xcarchive" ]]; then
  rm -rf "$archive"
fi
destination="generic/platform=iOS"
if [[ -n "$device" ]]; then
  destination="platform=iOS,id=${device}"
fi
finish() { rm -rf "$work_dir"; }
trap finish EXIT

echo "Signing as ${bundle_id} with team ${team}, version ${marketing_version:-(project.yml)}, build ${build_number}."

# Generated inputs the app target links; the same prerequisites as the
# SideStore package. They are cached under server/.build.
bash "${script_dir}/build-ledgercore-xcframework.sh"
bash "${script_dir}/build-beancount-ios.sh"
bash "${script_dir}/build-linux-ios.sh"

cd "$project_dir"
# The Xcode project is generated and git-ignored.
xcodegen generate --spec project.yml --quiet
mkdir -p "$(dirname "$archive")"

build_settings=(
  "LEDGER_TEAM_ID=${team}"
  "CURRENT_PROJECT_VERSION=${build_number}"
  CODE_SIGN_STYLE=Automatic
)
if [[ -n "$marketing_version" ]]; then
  build_settings+=("MARKETING_VERSION=${marketing_version}")
fi
registration=(-allowProvisioningDeviceRegistration)
if [[ "$testflight" == 1 ]]; then
  registration=()
fi
xcodebuild archive \
  -project LedgerMobile.xcodeproj \
  -scheme LedgerMobile \
  -configuration Release \
  -quiet \
  -destination "$destination" \
  -derivedDataPath "${work_dir}/DerivedData" \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  ${registration[@]+"${registration[@]}"} \
  ${auth_arguments[@]+"${auth_arguments[@]}"} \
  "${build_settings[@]}"

app="${archive}/Products/Applications/LedgerMobile.app"
if [[ ! -d "$app" ]]; then
  echo "Archive did not contain LedgerMobile.app." >&2
  exit 1
fi

# Every bundle must carry the team's IDs, one version, and the App Group in both
# the provisioning profile and the signature.
python3 - "$app" "$bundle_id" "$app_group" "$build_number" "$marketing_version" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

app, bundle_id, group, build, version = sys.argv[1:]
app = pathlib.Path(app)
expected = {
    app: bundle_id,
    app / "PlugIns/LedgerWidgets.appex": bundle_id + ".widgets",
    app / "PlugIns/LedgerShare.appex": bundle_id + ".share",
}
for bundle, identifier in expected.items():
    with (bundle / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != identifier:
        sys.exit(f"{bundle.name}: bundle identifier is {info.get('CFBundleIdentifier')}, expected {identifier}")
    if info.get("CFBundleVersion") != build:
        sys.exit(f"{bundle.name}: build is {info.get('CFBundleVersion')}, expected {build}")
    if version and info.get("CFBundleShortVersionString") != version:
        sys.exit(f"{bundle.name}: version is {info.get('CFBundleShortVersionString')}, expected {version}")
    profile = subprocess.run(
        ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")],
        check=True, capture_output=True,
    ).stdout
    groups = plistlib.loads(profile)["Entitlements"].get("com.apple.security.application-groups") or []
    if group not in groups:
        sys.exit(f"{bundle.name}: profile does not entitle {group}: {groups}")
    signed = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
        check=True, capture_output=True,
    ).stdout
    if plistlib.loads(signed).get("com.apple.security.application-groups") != [group]:
        sys.exit(f"{bundle.name}: signature does not carry exactly {group}")
print(f"Signed {bundle_id} and both extensions with {group}.")
PY

echo "Archive: $archive"
[[ "$testflight" == 1 ]] || exit 0

export_options="${work_dir}/ExportOptions.plist"
python3 - "$export_options" "$team" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({
        "method": "app-store-connect",
        "destination": "upload",
        "teamID": sys.argv[2],
        "signingStyle": "automatic",
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
        "testFlightInternalTestingOnly": True,
    }, handle)
PY
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_options" \
  -exportPath "${work_dir}/export" \
  -allowProvisioningUpdates \
  "${auth_arguments[@]}"
echo "Uploaded ${marketing_version} (${build_number}) to App Store Connect; it reaches TestFlight after Apple's processing."
