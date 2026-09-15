#!/usr/bin/env bash
# Build a device IPA whose ad-hoc entitlements can be read by SideStore.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$repo_root/App/LedgerMobile/Runtime/BeancountRuntime.c" ]]; then
  echo 'IPA packaging is gated pending the embedded runtime license audit and framework packaging update.' >&2
  echo 'See App/LedgerMobile/Runtime/THIRD_PARTY.md; use the documented private Xcode build workflow for testing.' >&2
  exit 1
fi
output_dir="${1:?Usage: bash scripts/build-ios-ipa.sh OUTPUT_DIRECTORY}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ios-ipa.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
project_dir="$repo_root/App/LedgerMobile"
archive="$build_dir/LedgerMobile.xcarchive"

cd "$project_dir"
xcodegen generate
build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  build_settings+=("CURRENT_PROJECT_VERSION=$((GITHUB_RUN_NUMBER + 3))")
fi
xcodebuild archive \
  -project LedgerMobile.xcodeproj \
  -scheme LedgerMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  -archivePath "$archive" \
  "${build_settings[@]}"

mkdir "$build_dir/Payload"
ditto "$archive/Products/Applications/LedgerMobile.app" "$build_dir/Payload/LedgerMobile.app"
app="$build_dir/Payload/LedgerMobile.app"

# SideStore discovers App Groups from the Mach-O signature. Preserve those
# entitlements with certificate-free ad-hoc signatures, signing extensions first.
# SideStore supplies the final team's Keychain groups during installation.
sign_bundle() {
  local bundle="$1" source_entitlements="$2"
  local entitlements="$build_dir/$(basename "$bundle").entitlements"
  python3 - "$source_entitlements" "$entitlements" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
entitlements.pop("keychain-access-groups", None)
with open(sys.argv[2], "wb") as target:
    plistlib.dump(entitlements, target)
PY
  codesign --force --sign - --entitlements "$entitlements" --generate-entitlement-der "$bundle"
  codesign --verify --strict "$bundle"
}

sign_bundle "$app/PlugIns/LedgerWidgets.appex" "$project_dir/WidgetExtension/LedgerWidgets.entitlements"
sign_bundle "$app/PlugIns/LedgerShare.appex" "$project_dir/ShareExtension/LedgerShare.entitlements"
sign_bundle "$app" "$project_dir/Supporting/LedgerMobilePersonal.entitlements"
codesign --verify --deep --strict "$app"

# Check device architecture, versions, extensions and the App Group that the
# installer will discover. Fail the job before uploading an incomplete package.
python3 - "$app" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
expected = {
    app: "com.qiaoborui.ledger.mobile",
    app / "PlugIns/LedgerWidgets.appex": "com.qiaoborui.ledger.mobile.widgets",
    app / "PlugIns/LedgerShare.appex": "com.qiaoborui.ledger.mobile.share",
}
versions = set()
for bundle, identifier in expected.items():
    with (bundle / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    assert info["CFBundleIdentifier"] == identifier, bundle
    assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], bundle
    versions.add((info["CFBundleShortVersionString"], info["CFBundleVersion"]))
    executable = bundle / info["CFBundleExecutable"]
    subprocess.run(["lipo", "-verify_arch", "arm64", str(executable)], check=True)
    signature = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)])
    entitlements = plistlib.loads(signature)
    assert entitlements["com.apple.security.application-groups"] == [
        "group.com.qiaoborui.ledger.mobile"
    ], bundle
assert len(versions) == 1, versions
print("Verified arm64 iOS app, both extensions, matching versions and signed App Group entitlements.")
PY

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Info.plist")"
ipa_name="LedgerMobile-${version}-${build}-SideStore.ipa"
ditto -c -k --norsrc --keepParent "$build_dir/Payload" "$output_dir/$ipa_name"
unzip -tq "$output_dir/$ipa_name"
cd "$output_dir"
shasum -a 256 "$ipa_name" > "$ipa_name.sha256"
{
  xcodebuild -version
  echo "iPhoneOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "Source: $(git -C "$repo_root" rev-parse HEAD)"
  echo "App: $version ($build)"
  echo 'Signing: ad-hoc; install and re-sign with SideStore / iLoader / AltStore'
  cat "$ipa_name.sha256"
} | tee build-info.txt
