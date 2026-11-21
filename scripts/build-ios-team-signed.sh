#!/usr/bin/env bash
# Archive the app signed with the paid Apple Developer team, and optionally
# upload it to App Store Connect for TestFlight.
#
# Usage:
#   bash scripts/build-ios-team-signed.sh [--team TEAMID] [--device UDID]
#        [--build-number N] [--marketing-version X.Y.Z] [--archive PATH]
#   bash scripts/build-ios-team-signed.sh --testflight [--team TEAMID]
#
# project.yml signs as the paid team (LEDGER_TEAM_ID) with
#   com.qiaoborui.ledger{,.widgets,.share}
#   group.com.qiaoborui.ledger
# Those IDs belong to that team, so --team with another team signs as
#   com.qiaoborui.ledger.<TEAMID>{,.widgets,.share}
#   group.com.qiaoborui.ledger.<TEAMID>
# through the same build settings. Each bundle's Info.plist carries the group
# (LedgerAppGroupIdentifier), so the app and both extensions agree.
#
# Development archive (default): the build number defaults to the commit count,
# so each commit is a higher build than the last. The team needs at least one
# registered device before a development profile can be generated: connect the
# phone, trust the Mac and pass --device on the first run.
#
# --testflight: HEAD must carry the newest v<X.Y.Z> tag, which sets the version
# and build exactly as for the SideStore package (scripts/ios-release-version.sh).
# The archive is exported for App Store Connect and uploaded; it shows up in
# TestFlight once Apple has processed it, usable by internal and external
# testers (external groups still need Beta App Review). No signing identity is
# needed on the machine: the archive is built unsigned with ad-hoc signatures
# that carry the entitlements, and the export signs it with the cloud-managed
# distribution certificate. That and the upload authenticate with an App Store
# Connect API key with the Admin role (an App Manager key cannot use cloud
# signing), read from:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_<id>.p8)
# This keeps CI off the runner user's login keychain, which is locked without a
# console login (codesign then fails with errSecInternalComponent).
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

project_team="$(sed -n 's/^ *LEDGER_TEAM_ID: *\([A-Z0-9]*\) *$/\1/p' "${project_dir}/project.yml" | head -n 1)"
team="${team:-$project_team}"
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

bundle_id="com.qiaoborui.ledger"
app_group="group.com.qiaoborui.ledger"
if [[ "$team" != "$project_team" ]]; then
  bundle_id="${bundle_id}.${team}"
  app_group="${app_group}.${team}"
fi
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
  "LEDGER_BUNDLE_ID=${bundle_id}"
  "LEDGER_APP_GROUP=${app_group}"
  "CURRENT_PROJECT_VERSION=${build_number}"
)
if [[ -n "$marketing_version" ]]; then
  build_settings+=("MARKETING_VERSION=${marketing_version}")
fi
icloud_container="$(sed -n 's/^ *LEDGER_ICLOUD_CONTAINER: *\([A-Za-z0-9.]*\) *$/\1/p' "${project_dir}/project.yml" | head -n 1)"

if [[ "$testflight" == 1 ]]; then
  # No local signing identity: the archive is built unsigned and given
  # certificate-free ad-hoc signatures that carry the entitlements; the export
  # below re-signs it with the cloud-managed distribution certificate.
  build_settings+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  xcodebuild archive \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -configuration Release \
    -quiet \
    -destination "$destination" \
    -derivedDataPath "${work_dir}/DerivedData" \
    -archivePath "$archive" \
    "${build_settings[@]}"
else
  xcodebuild archive \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -configuration Release \
    -quiet \
    -destination "$destination" \
    -derivedDataPath "${work_dir}/DerivedData" \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "${build_settings[@]}" \
    CODE_SIGN_STYLE=Automatic
fi

app="${archive}/Products/Applications/LedgerMobile.app"
if [[ ! -d "$app" ]]; then
  echo "Archive did not contain LedgerMobile.app." >&2
  exit 1
fi

if [[ "$testflight" == 1 ]]; then
  shopt -s nullglob
  for framework in "$app/Frameworks/"*.framework; do
    codesign --force --sign - "$framework"
  done
  shopt -u nullglob
  # The committed entitlements name values through build settings, which an
  # unsigned archive never expands.
  adhoc_sign() {
    local bundle="$1" source_entitlements="$2" identifier="$3"
    local entitlements="${work_dir}/$(basename "$bundle").entitlements"
    python3 - "$source_entitlements" "$entitlements" "$team" "$identifier" "$app_group" "$icloud_container" <<'PY'
import plistlib
import sys

source, target, team, identifier, group, container = sys.argv[1:]
values = {
    "$(LEDGER_APP_GROUP)": group,
    "$(LEDGER_ICLOUD_CONTAINER)": container,
    "$(AppIdentifierPrefix)": team + ".",
    "$(TeamIdentifierPrefix)": team + ".",
}

def expand(value):
    if isinstance(value, str):
        for name, replacement in values.items():
            value = value.replace(name, replacement)
        if "$(" in value:
            sys.exit(f"{source}: unexpanded build setting in {value}")
        return value
    if isinstance(value, list):
        return [expand(item) for item in value]
    return value

with open(source, "rb") as handle:
    entitlements = {key: expand(value) for key, value in plistlib.load(handle).items()}
entitlements["application-identifier"] = f"{team}.{identifier}"
entitlements["com.apple.developer.team-identifier"] = team
entitlements["get-task-allow"] = False
with open(target, "wb") as handle:
    plistlib.dump(entitlements, handle)
PY
    codesign --force --sign - --entitlements "$entitlements" --generate-entitlement-der "$bundle"
  }
  adhoc_sign "$app/PlugIns/LedgerWidgets.appex" "${project_dir}/WidgetExtension/LedgerWidgets.entitlements" "${bundle_id}.widgets"
  adhoc_sign "$app/PlugIns/LedgerShare.appex" "${project_dir}/ShareExtension/LedgerShare.entitlements" "${bundle_id}.share"
  adhoc_sign "$app" "${project_dir}/Supporting/LedgerMobile.entitlements" "$bundle_id"
  codesign --verify --deep --strict "$app"
fi

# Every bundle must carry the team's IDs, one version, and the App Group in both
# the provisioning profile and the signature. A TestFlight build is checked in
# the exported IPA, signed by Apple, instead of in the unsigned archive.
verify_signed_app() {
  python3 - "$1" "$bundle_id" "$app_group" "$build_number" "$marketing_version" "$icloud_container" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

app, bundle_id, group, build, version, container = sys.argv[1:]
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
    profile_entitlements = plistlib.loads(profile)["Entitlements"]
    if bundle == app and container not in (profile_entitlements.get("com.apple.developer.icloud-container-identifiers") or []):
        sys.exit(f"{bundle.name}: profile does not entitle iCloud container {container}. "
                 "Enable iCloud (CloudKit/iCloud Documents) for the App ID and assign that container "
                 "in the Apple Developer portal, then build again.")
    groups = profile_entitlements.get("com.apple.security.application-groups") or []
    if group not in groups:
        sys.exit(f"{bundle.name}: profile does not entitle {group}: {groups}")
    signed = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
        check=True, capture_output=True,
    ).stdout
    signed_entitlements = plistlib.loads(signed)
    if signed_entitlements.get("com.apple.security.application-groups") != [group]:
        sys.exit(f"{bundle.name}: signature does not carry exactly {group}")
    if bundle == app and signed_entitlements.get("com.apple.developer.icloud-container-identifiers") != [container]:
        sys.exit(f"{bundle.name}: signature does not carry iCloud container {container}")
print(f"Signed {bundle_id} and both extensions with {group}.")
PY
}

if [[ "$testflight" != 1 ]]; then
  verify_signed_app "$app"
  echo "Archive: $archive"
  exit 0
fi

# Signing and upload both use the Admin API key: Xcode creates the App Store
# profiles and signs with the cloud-managed distribution certificate. The first
# export writes the IPA so it can be checked before anything is uploaded.
write_export_options() {
  python3 - "$1" "$team" "$2" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({
        "method": "app-store-connect",
        "destination": sys.argv[3],
        "teamID": sys.argv[2],
        "signingStyle": "automatic",
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
        "testFlightInternalTestingOnly": False,
    }, handle)
PY
}
write_export_options "${work_dir}/ExportLocal.plist" export
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "${work_dir}/ExportLocal.plist" \
  -exportPath "${work_dir}/ipa" \
  -allowProvisioningUpdates \
  "${auth_arguments[@]}"
ipa="$(find "${work_dir}/ipa" -maxdepth 1 -name '*.ipa' | head -n 1)"
if [[ -z "$ipa" ]]; then
  echo "Export wrote no IPA." >&2
  exit 1
fi
mkdir "${work_dir}/unzipped"
ditto -x -k "$ipa" "${work_dir}/unzipped"
exported_app="${work_dir}/unzipped/Payload/LedgerMobile.app"
verify_signed_app "$exported_app"
authority="$(codesign -dvv "$exported_app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
if [[ "$authority" != "Apple Distribution"* && "$authority" != "iPhone Distribution"* ]]; then
  echo "Exported app is signed by '${authority}', not a distribution certificate." >&2
  exit 1
fi
echo "Exported IPA signed by ${authority}."

write_export_options "${work_dir}/ExportUpload.plist" upload
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "${work_dir}/ExportUpload.plist" \
  -exportPath "${work_dir}/upload" \
  -allowProvisioningUpdates \
  "${auth_arguments[@]}"
echo "Uploaded ${marketing_version} (${build_number}) to App Store Connect; it reaches TestFlight after Apple's processing."
