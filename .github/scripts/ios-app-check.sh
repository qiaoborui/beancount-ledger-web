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
#             manual run asks for them. UI_TESTS_ONLY narrows the run to the
#             classes or Class/testMethod entries it lists (space or comma
#             separated, no target prefix), and `smoke` stands for the release
#             smoke set below; empty runs every UI test except the screenshot
#             generators.
set -euo pipefail

mode="${1:-}"
skipped_tests=()
only_tests=()
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
    only_input="${UI_TESTS_ONLY:-}"
    read -r -a requested <<< "${only_input//,/ }"
    for item in ${requested[@]+"${requested[@]}"}; do
      # The release smoke set: launch, tab switching, the accounts and 更多 pages,
      # and a local ledger restarting without placeholder cards.
      if [[ "$item" == smoke ]]; then
        only_tests+=(
          "$test_target/TerminalOverviewUITests/testFlatNavigationKeepsSearchAndOverviewReachable"
          "$test_target/TerminalAccountsMoreUITests/testAccessibilityKeepsAccountFiltersAndMoreReachable"
          "$test_target/LocalLedgerUITests/testLocalRestartDoesNotShowPassiveLoadingCards"
        )
        continue
      fi
      # Class or Class/testMethod: letters, digits, `_` and at most one `/`.
      if [[ ! "$item" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$ ]]; then
        echo "::error::invalid UI_TESTS_ONLY entry: $item (expected Class, Class/testMethod or smoke)" >&2
        exit 2
      fi
      only_tests+=("$test_target/$item")
    done
    if [[ ${#only_tests[@]} -eq 0 ]]; then
      # They generate App Store screenshots rather than check behaviour; name
      # them in UI_TESTS_ONLY to run them.
      skipped_tests=(
        LedgerMobileUITests/BalancedScreenshotTests
        LedgerMobileUITests/BalancedStreamAScreenshotTests
      )
    fi
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

if [[ "$mode" == ui-tests ]]; then
  # The app keeps its layout preferences (compact tab bar, hidden amounts,
  # overview sections) in UserDefaults, and the simulator outlives the job: a
  # run that customised the bar leaves every later run starting from a bar the
  # tests do not expect, and the failures cascade. Begin from a clean install.
  xcrun simctl uninstall "$simulator" com.qiaoborui.ledger.mobile 2>/dev/null || true
fi

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

only_args=()
for test in ${only_tests[@]+"${only_tests[@]}"}; do
  only_args+=("-only-testing:$test")
done
if [[ ${#only_args[@]} -eq 0 ]]; then
  only_args=("-only-testing:$test_target")
fi
echo "Selected: ${only_args[*]}"
if [[ ${#skipped_tests[@]} -gt 0 ]]; then
  echo "Skipped: ${skipped_tests[*]}"
fi
skip_args=()
for test in ${skipped_tests[@]+"${skipped_tests[@]}"}; do
  skip_args+=("-skip-testing:$test")
done
test_log="$derived_data/test.log"
xcodebuild test-without-building "${common[@]}" \
  "${only_args[@]}" \
  ${skip_args[@]+"${skip_args[@]}"} \
  -resultBundlePath "$derived_data/Tests.xcresult" > "$test_log" 2>&1 || true
grep -E '(error|failed|passed|Executed|TEST (SUCCEEDED|FAILED)|\*\* )' "$test_log" || true
# The step-by-step lines around a failure are what make it diagnosable, and
# grep above drops them: print them for every failing test.
awk '/error: -\[/ { start = NR } { line[NR] = $0 }
     END { for (i = 1; i <= NR; i++) if (line[i] ~ /error: -\[/) {
             print "::group::context for " line[i]
             for (j = (i > 40 ? i - 40 : 1); j <= i; j++) print line[j]
             print "::endgroup::"
           } }' "$test_log" || true
# The grep hides the full log, so take the verdict from the result bundle.
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
