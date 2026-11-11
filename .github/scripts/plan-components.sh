#!/usr/bin/env bash
set -euo pipefail

backend=false
agent=false
web=false
ios=false

if [[ "${1:-}" == "--all" ]]; then
  backend=true
  agent=true
  web=true
  ios=true
else
  while IFS= read -r file; do
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.dockerignore|docker/*|docker/**/*|server/*|server/**/*|examples/*|examples/**/*)
        backend=true
        ;;
      # A workflow only concerns the components it builds. Treating every
      # workflow as a change to everything made an iOS packaging tweak run the
      # backend, agent and frontend suites, where an unrelated upstream advisory
      # could then block an iOS-only pull request.
      .github/workflows/ios-ipa.yml)
        ;;
      .github/workflows/*)
        backend=true
        ;;
    esac
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.dockerignore|docker/*|docker/**/*|.agents/*|.agents/**/*|agent/*|agent/**/*)
        agent=true
        ;;
      .github/workflows/ios-ipa.yml)
        ;;
      .github/workflows/*)
        agent=true
        ;;
    esac
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.dockerignore|docker/*|docker/**/*|web/*|web/**/*)
        web=true
        ;;
      .github/workflows/ios-ipa.yml)
        ;;
      .github/workflows/*)
        web=true
        ;;
    esac
    case "$file" in
      # The iOS app links the Go ledger core and the Beancount runtime built
      # from these trees, so its Swift package tests follow them too.
      .github/scripts/*|.github/scripts/**/*|App/*|App/**/*|server/*|server/**/*|examples/*|examples/**/*)
        ios=true
        ;;
      .github/workflows/ios-ipa.yml)
        # The repository's own iOS packaging workflow is iOS work, and the
        # `swift test` job is the check that covers it.
        ios=true
        ;;
      .github/workflows/*)
        ios=true
        ;;
    esac
  done
fi

jq -cn \
  --argjson backend "$backend" \
  --argjson agent "$agent" \
  --argjson web "$web" \
  --argjson ios "$ios" \
  '{
    backend: $backend,
    agent: $agent,
    web: $web,
    ios: $ios
  }'
