#!/usr/bin/env bash
# Map changed paths (one per line on stdin) to the CI areas they affect and
# print one JSON object of booleans. `--all` turns every area on.
#
# Each area is one job in .github/workflows/ci.yml:
#   backend      Go tests and build (server/)
#   agent        Bub Agent pytest (agent/)
#   web          typecheck, tests, audit and build (web/)
#   ios          swift test and iOS SDK build of the Swift package (self-hosted Mac)
#   ios_app      Xcode build of the whole app and its unit tests (self-hosted Mac)
#   ios_widgets  Xcode build of the widget extension and its tests (self-hosted Mac)
#   ios_runtime  Python ledger validator bundled into the app
#   selfhost     Compose validation and deploy manifest checks
#   release      IPA packaging and SideStore publishing script tests
#
# The iOS UI tests are not an area: a manual run of ci.yml opts into them.
#
# Paths no rule matches (docs, Markdown, design notes) run nothing.
set -euo pipefail

areas="backend agent web ios ios_app ios_widgets ios_runtime selfhost release"
for area in $areas; do
  eval "$area=false"
done

mark() {
  local area
  for area in "$@"; do
    eval "$area=true"
  done
}

# The widget extension and its tests also compile files from Sources/ and
# Resources/. Read them from the two targets in project.yml so the list
# follows the project.
project_yml="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/App/LedgerMobile/project.yml"
widget_files=""
if [[ -f "$project_yml" ]]; then
  widget_files="$(awk '
    /^  [A-Za-z]+:$/ { inside = ($1 == "LedgerWidgets:" || $1 == "LedgerWidgetsTests:"); next }
    inside && $1 == "-" && $2 == "path:" { print "App/LedgerMobile/" $3 }
  ' "$project_yml")"
fi

if [[ "${1:-}" == "--all" ]]; then
  # shellcheck disable=SC2086 # word splitting is the point
  mark $areas
else
  while IFS= read -r file; do
    if [[ -n "$file" ]] && grep -qxF -- "$file" <<< "$widget_files"; then
      mark ios_widgets
    fi
    case "$file" in
      # The tag-triggered release workflow is not part of CI; its guards live in
      # the release tooling tests.
      .github/workflows/ios-release.yml)
        mark release ;;
      # The pipeline itself: a change here can alter any job.
      .github/workflows/*|.github/scripts/plan-components.sh|.github/scripts/test_plan_components.py)
        # shellcheck disable=SC2086
        mark $areas ;;
      .github/scripts/select-xcode.sh)
        mark ios ios_app ios_widgets ;;
      .github/scripts/ios-app-check.sh)
        mark ios_app ios_widgets ;;
      .github/scripts/test-deploy-selfhost-submit.sh)
        mark selfhost ;;

      # The app links the Go ledger core and Go tests load the example ledgers,
      # so both trees are checked by the Go and Swift suites, and the app is
      # rebuilt against the new LedgerCore.
      server/*|examples/*)
        mark backend ios ios_app ;;
      # Go tests import the bundled validator for canonical-export parity, and
      # the app bundles it.
      App/LedgerMobile/Runtime/*)
        mark ios ios_runtime backend ios_app ;;
      App/LedgerMobile/project.yml)
        mark ios ios_app ios_widgets ;;
      App/LedgerMobile/WidgetExtension/*|App/LedgerMobile/WidgetTests/*)
        mark ios ios_widgets ;;
      # Everything the LedgerMobile scheme compiles besides the widgets. The UI
      # tests are compiled there too, though CI runs them only on request.
      App/LedgerMobile/Sources/*|App/LedgerMobile/Resources/*|App/LedgerMobile/Supporting/*|App/LedgerMobile/ShareExtension/*|App/LedgerMobile/Tests/*|App/LedgerMobile/UITests/*)
        mark ios ios_app ;;
      App/*)
        mark ios ;;
      # Build steps of the app scheme: the frameworks it links, and the scripts
      # its build phases run.
      scripts/build-ledgercore-xcframework.sh|scripts/build-beancount-ios.sh|scripts/build-beancount-ios-resources.sh|scripts/stamp-ios-build-commit.sh)
        mark ios_app ;;

      # Agent tests discover the project skills under .agents/.
      agent/*|.agents/*)
        mark agent ;;

      web/*)
        mark web ;;

      docker/*|scripts/selfhost/*|.env.selfhost.example|.dockerignore)
        mark selfhost ;;

      scripts/build-ios-ipa.sh|scripts/ios-release-version.sh|scripts/test_ios_private_ipa.py|scripts/publish-sidestore-release.py|scripts/test_sidestore_publish.py)
        mark release ;;
    esac
  done
fi

json="{"
separator=""
for area in $areas; do
  json+="${separator}\"${area}\":${!area}"
  separator=","
done
echo "${json}}"
