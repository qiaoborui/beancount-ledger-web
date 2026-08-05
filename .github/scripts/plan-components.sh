#!/usr/bin/env bash
set -euo pipefail

backend=false
agent=false
web=false
cloud_run=false
agent_service=false
zip_worker=false

if [[ "${1:-}" == "--all" ]]; then
  backend=true
  agent=true
  web=true
  cloud_run=true
  agent_service=true
  zip_worker=true
else
  while IFS= read -r file; do
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.github/workflows/*|Dockerfile.vercel|vercel.json|.dockerignore|docker/*|docker/**/*|server/*|server/**/*|examples/*|examples/**/*)
        backend=true
        ;;
    esac
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.github/workflows/*|.dockerignore|docker/*|docker/**/*|.agents/*|.agents/**/*|agent/*|agent/**/*)
        agent=true
        ;;
    esac
    case "$file" in
      .github/scripts/*|.github/scripts/**/*|.github/workflows/*|vercel.json|.dockerignore|docker/*|docker/**/*|web/*|web/**/*)
        web=true
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
  --argjson cloud_run "$cloud_run" \
  --argjson agent_service "$agent_service" \
  --argjson zip_worker "$zip_worker" \
  --argjson deploy_any "$deploy_any" \
  '{
    backend: $backend,
    agent: $agent,
    web: $web,
    cloud_run: $cloud_run,
    agent_service: $agent_service,
    zip_worker: $zip_worker,
    deploy_any: $deploy_any
  }'
