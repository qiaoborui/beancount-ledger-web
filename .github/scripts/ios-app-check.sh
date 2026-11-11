#!/usr/bin/env bash
# Build an Xcode scheme of the iOS app for a simulator and run one test target.
#
# `swift test` and the iOS SDK cross-build in the iOS core job only compile the
# files Package.swift lists. The app's UI layer (RootView, MoreView, the agent
# screen), the widgets and the share extension are compiled only by Xcode, so a
# change there could pass that job and still break the IPA build.
#
# Usage: bash .github/scripts/ios-app-check.sh <mode>   (from any directory)
#   app       build the LedgerMobile scheme (the app, both extensions and every
#             test bundle) and run LedgerMobileTests
#   widgets   build the LedgerWidgets scheme and run LedgerWidgetsTests; needs
#             neither LedgerCore nor the Beancount runtime, so it is quick
#   ui-tests  build the LedgerMobile scheme and run LedgerMobileUITests; several
#             of them time out on a loaded machine, so CI runs them only when a
#             manual run asks for them
set -euo pipefail

mode="${1:-}"
skipped_tests=()
case "$mode" in
  app)
    scheme=LedgerMobile
    test_target=LedgerMobileTests
    needs_frameworks=true
    # Unsigned simulator builds have no keychain access group, so these tests
    # fail on every unsigned run regardless of the change.
    skipped_tests=(
      LedgerMobileTests/BookkeepingPipelineTests/testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey
      LedgerMobileTests/ImportClassificationTests/testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences
      LedgerMobileTests/LocalGitBackgroundCredentialTests/testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken
    )
    ;;
  widgets)
    scheme=LedgerWidgets
    test_target=LedgerWidgetsTests
    needs_frameworks=false
    ;;
  ui-tests)
    scheme=LedgerMobile
    test_target=LedgerMobileUITests
    needs_frameworks=true
    ;;
  *)
    echo "usage: $0 app|widgets|ui-tests" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/.github/scripts/select-xcode.sh"
export PATH="/opt/homebrew/bin:$PATH"

if [[ "$needs_frameworks" == true ]]; then
  # The frameworks the app links: LedgerCore (gomobile) and the embedded
  # Beancount runtime with its Python. They are built under server/.build,
  # which the checkout step cleans, so every CI run builds them afresh.
  echo "::group::Build LedgerCore and the Beancount runtime"
  bash "$repo_root/scripts/build-ledgercore-xcframework.sh"
  bash "$repo_root/scripts/build-beancount-ios.sh"
  echo "::endgroup::"
fi

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
  -scheme "$scheme"
  -destination "platform=iOS Simulator,id=$simulator"
  -derivedDataPath "$derived_data"
  CODE_SIGNING_ALLOWED=NO
)

echo "::group::Build the $scheme scheme and its test bundles"
xcodebuild build-for-testing -quiet "${common[@]}"
echo "::endgroup::"

skip_args=()
for test in ${skipped_tests[@]+"${skipped_tests[@]}"}; do
  skip_args+=("-skip-testing:$test")
done
xcodebuild test-without-building "${common[@]}" \
  "-only-testing:$test_target" \
  ${skip_args[@]+"${skip_args[@]}"} \
  -resultBundlePath "$derived_data/Tests.xcresult" \
  | grep -E --line-buffered '(error|failed|passed|Executed|TEST (SUCCEEDED|FAILED)|\*\* )' \
  || true
# grep hides the full log, so take the verdict from the result bundle.
xcrun xcresulttool get test-results summary --path "$derived_data/Tests.xcresult" \
  | python3 -c '
import json, sys
summary = json.load(sys.stdin)
result = summary.get("result")
print("%s: %s passed, %s failed, %s skipped" % (result, summary.get("passedTests"),
      summary.get("failedTests"), summary.get("skippedTests")))
for failure in summary.get("testFailures", []):
    print("::error::%s: %s" % (failure.get("testIdentifierString"), failure.get("failureText")))
# A filter that matches nothing also reports Passed.
if not summary.get("passedTests"):
    print("::error::no tests ran")
    sys.exit(1)
sys.exit(0 if result == "Passed" else 1)
'
