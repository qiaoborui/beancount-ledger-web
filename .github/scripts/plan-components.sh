#!/usr/bin/env bash
set -euo pipefail

backend=false
agent=false
web=false
ios=false
cloud_run=false
agent_service=false
zip_worker=false

if [[ "${1:-}" == "--all" ]]; then
  backend=true
  agent=true
  web=true
  ios=true
  cloud_run=true
  agent_service=true
  zip_worker=true
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
      .github/workflows/publish-images.yml)
        ;;
      .github/workflows/*)
        ios=true
        ;;
    esac
    case "$file" in
      .dockerignore|.github/workflows/deploy-google-cloud.yml|docker/Dockerfile|server/*|server/**/*|web/*|web/**/*)
        cloud_run=true
        ;;
    esac
    case "$file" in
      .dockerignore|.github/workflows/deploy-google-cloud.yml|docker/Dockerfile|.agents/skills/*|.agents/skills/**/*|agent/*|agent/**/*)
        agent_service=true
        ;;
    esac
    case "$file" in
      .dockerignore|.github/workflows/deploy-google-cloud.yml|docker/Dockerfile|server/*|server/**/*)
        zip_worker=true
        ;;
    esac
  done
fi

deploy_any=false
if [[ "$cloud_run" == "true" || "$agent_service" == "true" || "$zip_worker" == "true" ]]; then
  deploy_any=true
fi

jq -cn \
  --argjson backend "$backend" \
  --argjson agent "$agent" \
  --argjson web "$web" \
  --argjson ios "$ios" \
  --argjson cloud_run "$cloud_run" \
  --argjson agent_service "$agent_service" \
  --argjson zip_worker "$zip_worker" \
  --argjson deploy_any "$deploy_any" \
  '{
    backend: $backend,
    agent: $agent,
    web: $web,
    ios: $ios,
    cloud_run: $cloud_run,
    agent_service: $agent_service,
    zip_worker: $zip_worker,
    deploy_any: $deploy_any
  }'
