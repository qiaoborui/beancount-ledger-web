#!/usr/bin/env bash
# Build a device IPA whose ad-hoc entitlements can be read by SideStore.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ( $# != 2 && $# != 4 ) || "${1:-}" != --private-local ]]; then
  echo 'Usage: bash scripts/build-ios-ipa.sh --private-local NEW_OUTPUT_DIRECTORY [--configuration Release|BoundedRelease]' >&2
  echo 'Private local use only. Public redistribution remains gated; see App/LedgerMobile/Runtime/THIRD_PARTY.md.' >&2
  exit 1
fi
configuration=Release
if [[ $# == 4 ]]; then
  if [[ "$3" != --configuration || ( "$4" != Release && "$4" != BoundedRelease ) ]]; then
    echo 'Configuration must be Release or BoundedRelease.' >&2
    exit 1
  fi
  configuration="$4"
fi
umask 077
output_dir="$2"
if ! mkdir "$output_dir"; then
  echo 'Choose a fresh output directory; existing files are preserved.' >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ios-ipa.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
project_dir="$repo_root/App/LedgerMobile"
archive="$build_dir/LedgerMobile.xcarchive"

# Build generated inputs from this checkout, including a fresh Python bridge.
bash "$repo_root/scripts/build-ledgercore-xcframework.sh"
bash "$repo_root/scripts/build-beancount-ios.sh"

cd "$project_dir"
xcodegen generate
build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  build_settings+=("CURRENT_PROJECT_VERSION=$((GITHUB_RUN_NUMBER + 3))")
fi
# Verify the opt-in flag across the app and both extensions before archiving.
xcodebuild -project LedgerMobile.xcodeproj -alltargets \
  -configuration "$configuration" -sdk iphoneos -showBuildSettings -json \
  "${build_settings[@]}" > "$build_dir/settings.json"
python3 - "$build_dir/settings.json" "$configuration" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    targets = {item["target"]: item["buildSettings"] for item in json.load(source)}
for name in ("LedgerMobile", "LedgerWidgets", "LedgerShare"):
    settings = targets[name]
    flags = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
    assert settings["CONFIGURATION"] == sys.argv[2], name
    assert ("LEDGER_BOUNDED_READ_INDEX" in flags) == (sys.argv[2] == "BoundedRelease"), name
print("Verified configuration for app, Widget and Share: " + sys.argv[2])
PY
xcodebuild archive \
  -project LedgerMobile.xcodeproj \
  -scheme LedgerMobile \
  -configuration "$configuration" \
  -quiet \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  -archivePath "$archive" \
  "${build_settings[@]}"

mkdir "$build_dir/Payload"
ditto "$archive/Products/Applications/LedgerMobile.app" "$build_dir/Payload/LedgerMobile.app"
app="$build_dir/Payload/LedgerMobile.app"

# Xcode's unsigned archive leaves Python and its extension frameworks unsigned.
# Sign inner bundles first; SideStore will replace these ad-hoc signatures.
shopt -s nullglob
frameworks=("$app/Frameworks/"*.framework)
if [[ ${#frameworks[@]} == 0 || ! -d "$app/Frameworks/Python.framework" ]]; then
  echo 'Embedded Python frameworks are missing from the archive.' >&2
  exit 1
fi
for framework in "${frameworks[@]}"; do
  if [[ -L "$framework" ]]; then
    echo 'Unexpected framework symlink in the device archive.' >&2
    exit 1
  fi
  codesign --force --sign - "$framework"
  codesign --verify --strict "$framework"
done

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
frameworks = list((app / "Frameworks").glob("*.framework"))
assert (app / "Frameworks/Python.framework").is_dir()
for framework in frameworks:
    with (framework / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    subprocess.run(["lipo", "-verify_arch", "arm64", str(framework / info["CFBundleExecutable"])], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(framework)], check=True)
packages = app / "python/app_packages"
for required in ("ledger_validator.py", "ledger_stream.py", "ledger_stream_bridge.py",
                 "beancount/loader.py", "regex/__init__.py",
                 "licenses/Beancount-GPL-2.0.txt", "licenses/regex.txt", "licenses/CPython.txt"):
    assert (packages / required).is_file(), required
assert (app / "python/lib/python3.14").is_dir(), "Python standard library is missing"
print(f"Verified app, both extensions, App Groups and {len(frameworks)} embedded framework signatures.")
PY
for module in ledger_validator ledger_stream ledger_stream_bridge; do
    cmp "$repo_root/App/LedgerMobile/Runtime/$module.py" "$app/python/app_packages/$module.py"
done

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Info.plist")"
ipa_name="com.qiaoborui.ledger.mobile.ipa"
ditto -c -k --norsrc --keepParent "$build_dir/Payload" "$output_dir/$ipa_name"
unzip -tq "$output_dir/$ipa_name"
cd "$output_dir"
shasum -a 256 "$ipa_name" > "$ipa_name.sha256"
{
  xcodebuild -version
  echo "iPhoneOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "Source: $(git -C "$repo_root" rev-parse HEAD)"
  echo "Configuration: $configuration"
  echo "App: $version ($build)"
  echo 'Signing: ad-hoc; install and re-sign with SideStore / iLoader / AltStore'
  echo 'Distribution: private local use only; public redistribution remains gated'
  cat "$ipa_name.sha256"
} | tee build-info.txt
