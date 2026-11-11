#!/usr/bin/env bash
# Build the whole LedgerMobile scheme for an iOS simulator and run its unit tests.
#
# `swift test` and the iOS SDK cross-build in the iOS core job only compile the
# files Package.swift lists. The app's UI layer (RootView, MoreView, the agent
# screen, the widgets and the share extension) is compiled only by Xcode, so a
# change there could pass CI and still break the IPA build. This builds the
# app, its extensions and every test bundle, then runs the unit test targets.
#
# The UI test target is built but not run: on a loaded machine several of its
# screenshot and navigation tests time out, so it would fail for reasons that
# have nothing to do with the change.
#
# Usage: bash .github/scripts/ios-app-check.sh   (from any directory)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/.github/scripts/select-xcode.sh"
export PATH="/opt/homebrew/bin:$PATH"

# Unsigned simulator builds have no keychain access group, so these tests fail
# on every unsigned run regardless of the change.
skipped_tests=(
  LedgerMobileTests/BookkeepingPipelineTests/testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey
  LedgerMobileTests/ImportClassificationTests/testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences
  LedgerMobileTests/LocalGitBackgroundCredentialTests/testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken
)

# The frameworks project.yml links: LedgerCore (gomobile) and the embedded
# Beancount runtime with its Python. Both scripts reuse their downloads.
bash "$repo_root/scripts/build-ledgercore-xcframework.sh"
bash "$repo_root/scripts/build-beancount-ios.sh"

cd "$repo_root/App/LedgerMobile"
# The Xcode project is generated and git-ignored.
xcodegen generate --spec project.yml --quiet

# The newest available iPhone simulator on the newest iOS runtime.
simulator="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match[1]), int(match[2]))
    for device in entries:
        if device["name"].startswith("iPhone"):
            best = max(best or (version, ""), (version, device["udid"]))
if not best:
    sys.exit("No available iPhone simulator; install an iOS simulator runtime in Xcode.")
print(best[1])
')"
echo "Simulator: $simulator"

derived_data="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ios-app.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT
common=(
  -project LedgerMobile.xcodeproj
  -scheme LedgerMobile
  -destination "platform=iOS Simulator,id=$simulator"
  -derivedDataPath "$derived_data"
  CODE_SIGNING_ALLOWED=NO
)

echo "::group::Build the app, its extensions and the test bundles"
xcodebuild build-for-testing -quiet "${common[@]}"
echo "::endgroup::"

skip_args=()
for test in "${skipped_tests[@]}"; do skip_args+=("-skip-testing:$test"); done
xcodebuild test-without-building "${common[@]}" \
  -only-testing:LedgerMobileTests \
  -only-testing:LedgerWidgetsTests \
  "${skip_args[@]}" \
  -resultBundlePath "$derived_data/UnitTests.xcresult" \
  | grep -E --line-buffered '(error|failed|passed|Executed|TEST (SUCCEEDED|FAILED)|\*\* )' \
  || true
# grep hides the full log, so take the verdict from the result bundle.
xcrun xcresulttool get test-results summary --path "$derived_data/UnitTests.xcresult" \
  | python3 -c '
import json, sys
summary = json.load(sys.stdin)
result = summary.get("result")
print("%s: %s passed, %s failed, %s skipped" % (result, summary.get("passedTests"),
      summary.get("failedTests"), summary.get("skippedTests")))
for failure in summary.get("testFailures", []):
    print("::error::%s: %s" % (failure.get("testIdentifierString"), failure.get("failureText")))
sys.exit(0 if result == "Passed" else 1)
'
