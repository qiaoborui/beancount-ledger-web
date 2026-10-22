#!/usr/bin/env bash
# Point DEVELOPER_DIR at the newest Xcode in /Applications and report it.
#
# The macOS runner's default developer directory is Command Line Tools, whose
# `swift` cannot load the SwiftPM build service. Both the portable Swift package
# tests and the IPA build need a full Xcode, and this machine keeps a beta
# install beside the release one, so pick by version instead of by name.
set -euo pipefail

if [[ -n "${DEVELOPER_DIR:-}" && -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
  echo "Using preconfigured DEVELOPER_DIR=${DEVELOPER_DIR}"
else
  DEVELOPER_DIR="$(
    python3 - <<'PY'
import pathlib
import plistlib
import re

candidates = []
for app in pathlib.Path("/Applications").glob("Xcode*.app"):
    developer = app / "Contents/Developer"
    version_file = app / "Contents/version.plist"
    if not version_file.is_file() or not (developer / "usr/bin/xcodebuild").is_file():
        continue
    with version_file.open("rb") as source:
        info = plistlib.load(source)
    version = tuple(int(part) for part in info["CFBundleShortVersionString"].split("."))
    version = version + (0,) * (3 - len(version))
    build = tuple((0, int(part)) if part.isdigit() else (1, part)
                  for part in re.findall(r"\d+|\D+", info["ProductBuildVersion"]))
    stable = not re.search(r"\d[a-z]$", info["ProductBuildVersion"])
    candidates.append((version, stable, build, str(developer)))
if not candidates:
    raise SystemExit("Install Xcode in /Applications and complete its first launch setup.")
print(max(candidates)[3])
PY
  )"
  echo "Selected ${DEVELOPER_DIR}"
fi

export DEVELOPER_DIR
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=${DEVELOPER_DIR}" >> "$GITHUB_ENV"
fi

"${DEVELOPER_DIR}/usr/bin/xcodebuild" -version
xcrun --sdk iphoneos --show-sdk-version
