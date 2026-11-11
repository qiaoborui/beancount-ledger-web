#!/usr/bin/env bash
# Map changed paths (one per line on stdin) to the CI areas they affect and
# print one JSON object of booleans. `--all` turns every area on.
#
# Each area is one job in .github/workflows/ci.yml:
#   backend      Go tests and build (server/)
#   agent        Bub Agent pytest (agent/)
#   web          typecheck, tests, audit and build (web/)
#   ios          swift test and iOS SDK build of the files Package.swift lists (self-hosted Mac)
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

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/App/LedgerMobile"

# The Swift package compiles only the Sources/ files its `sources:` list names;
# the rest of Sources/ is the app's UI layer, which only Xcode builds.
package_files=""
if [[ -f "$app_root/Package.swift" ]]; then
  package_files="$(sed -n 's/^ *sources: \[\(.*\)\]$/\1/p' "$app_root/Package.swift" \
    | grep -o '"[^"]*"' | tr -d '"' | sed 's|^|App/LedgerMobile/Sources/|')"
fi

# The widget extension and its tests also compile files from Sources/ and
# Resources/. Read them from the two targets in project.yml so the list
# follows the project.
project_yml="$app_root/project.yml"
widget_files=""
if [[ -f "$project_yml" ]]; then
  widget_files="$(awk '
    /^[^ #]/ { inside = 0; next }
    /^  [^ #][^ ]*:/ { inside = ($1 == "LedgerWidgets:" || $1 == "LedgerWidgetsTests:"); next }
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
    if [[ -n "$file" ]] && grep -qxF -- "$file" <<< "$package_files"; then
      mark ios
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

      # The app links LedgerCore, which gomobile builds from server/mobile*
      # and the server/internal packages they import (internal/app among them).
      # Go tests, the server binary, its HTTP service and logging are not in
      # it, so a change to those leaves the app alone.
      server/*_test.go|server/cmd/*|server/internal/httpservice/*|server/internal/logging/*)
        mark backend ;;
      server/*)
        mark backend ios_app ;;
      # Go tests load the example ledgers; nothing on iOS reads them.
      examples/*)
        mark backend ;;
      # Go tests import the bundled validator for canonical-export parity, and
      # the app bundles it.
      App/LedgerMobile/Runtime/*.md)
        ;;
      App/LedgerMobile/Runtime/*)
        mark ios_runtime backend ios_app ;;
      App/LedgerMobile/Package.swift)
        mark ios ;;
      App/LedgerMobile/project.yml)
        mark ios_app ios_widgets ;;
      App/LedgerMobile/WidgetExtension/*|App/LedgerMobile/WidgetTests/*)
        mark ios_widgets ;;
      # The package's tests, which the app's unit test target also compiles.
      App/LedgerMobile/Tests/*)
        mark ios ios_app ;;
      # Everything else the LedgerMobile scheme compiles. Sources/ files the
      # package lists also mark ios above. The UI tests are compiled here too,
      # though CI runs them only on request.
      App/LedgerMobile/Sources/*|App/LedgerMobile/Resources/*|App/LedgerMobile/Supporting/*|App/LedgerMobile/ShareExtension/*|App/LedgerMobile/UITests/*)
        mark ios_app ;;
      # Notes and screenshots compile into nothing.
      App/*.md|App/LedgerMobile/Screenshots/*)
        ;;
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
