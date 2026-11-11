#!/usr/bin/env bash
# Map changed paths (one per line on stdin) to the CI areas they affect and
# print one JSON object of booleans. `--all` turns every area on.
#
# Each area is one job in .github/workflows/ci.yml:
#   backend      Go tests and build (server/)
#   agent        Bub Agent pytest (agent/)
#   web          typecheck, tests, audit and build (web/)
#   ios          swift test and iOS SDK build (self-hosted Mac)
#   ios_runtime  Python ledger validator bundled into the app
#   selfhost     Compose validation and deploy manifest checks
#   release      IPA packaging and SideStore publishing script tests
#
# Paths no rule matches (docs, Markdown, design notes) run nothing.
set -euo pipefail

areas="backend agent web ios ios_runtime selfhost release"
for area in $areas; do
  eval "$area=false"
done

mark() {
  local area
  for area in "$@"; do
    eval "$area=true"
  done
}

if [[ "${1:-}" == "--all" ]]; then
  # shellcheck disable=SC2086 # word splitting is the point
  mark $areas
else
  while IFS= read -r file; do
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
        mark ios ;;
      .github/scripts/test-deploy-selfhost-submit.sh)
        mark selfhost ;;

      # The app links the Go ledger core and Go tests load the example ledgers,
      # so both trees are checked by the Go and Swift suites.
      server/*|examples/*)
        mark backend ios ;;
      # Go tests import the bundled validator for canonical-export parity.
      App/LedgerMobile/Runtime/*)
        mark ios ios_runtime backend ;;
      App/*)
        mark ios ;;

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
