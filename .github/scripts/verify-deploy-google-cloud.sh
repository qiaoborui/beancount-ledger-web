#!/usr/bin/env bash
set -euo pipefail

deployment="${1:-.github/workflows/deploy-google-cloud.yml}"
ci="${2:-.github/workflows/ci.yml}"
publisher="${3:-.github/workflows/publish-images.yml}"
component_planner="${4:-.github/scripts/plan-components.sh}"

for file in "$deployment" "$ci" "$publisher" "$component_planner"; do
  if [[ ! -f "$file" ]]; then
    echo "required workflow file is missing: ${file}" >&2
    exit 1
  fi
done

if ! grep -Fq '  push:' "$deployment" || ! grep -Fq '    branches: [main]' "$deployment"; then
  echo "production pipeline must run directly on main pushes" >&2
  exit 1
fi

if grep -Fq 'workflow_run:' "$deployment"; then
  echo "production deployment must not wait for a separate CI workflow run" >&2
  exit 1
fi

for required in \
  'uses: ./.github/workflows/ci.yml' \
  'needs: [plan, checks, build-standalone, build-agent, build-zip-worker]' \
  "needs.checks.result == 'success'" \
  'name: Verify current main commit' \
  'needs.build-standalone.outputs.digest' \
  'needs.build-agent.outputs.digest' \
  'needs.build-zip-worker.outputs.digest'; do
  if ! grep -Fq "$required" "$deployment"; then
    echo "production pipeline is missing its parallel build/check gate: ${required}" >&2
    exit 1
  fi
done

if ! grep -Fq '  workflow_call:' "$ci"; then
  echo "CI must remain reusable by the production pipeline" >&2
  exit 1
fi

for required in \
  'reusable_call:' \
  'reusable_call: true' \
  'INPUT_REUSABLE_CALL: ${{ inputs.reusable_call }}' \
  'if [[ "${INPUT_REUSABLE_CALL}" == "true" ]]'; do
  if ! grep -Fq "$required" "$ci" "$deployment"; then
    echo "reusable CI must use an explicit invocation marker: ${required}" >&2
    exit 1
  fi
done

if grep -Fq "github.event_name != 'workflow_call'" "$ci" || grep -Fq 'github.event_name }}" == "workflow_call"' "$ci"; then
  echo "reusable CI must not infer its invocation mode from the caller event" >&2
  exit 1
fi

if grep -Fq '  push:' "$ci"; then
  echo "main pushes must not start a second serial CI workflow" >&2
  exit 1
fi

if ! grep -Fq 'workflow_run:' "$publisher" || ! grep -Fq 'workflows: [Deploy Google Cloud]' "$publisher"; then
  echo "GHCR publishing must run asynchronously after the production pipeline" >&2
  exit 1
fi

for required in \
  'cancel-in-progress: false' \
  'gh run list --workflow publish-images.yml --status success --limit 100' \
  'gh run download "$previous_run_id"' \
  'git diff --name-only "$base_sha" "$source_sha"' \
  'name: container-publish-state' \
  'record-state:'; do
  if ! grep -Fq "$required" "$publisher"; then
    echo "GHCR publishing is missing cumulative publication state: ${required}" >&2
    exit 1
  fi
done

for job in build-standalone build-agent build-zip-worker; do
  build_job="$(awk -v job="$job" '
    $0 == "  " job ":" { capture = 1 }
    capture && /^  [a-z0-9-]+:$/ && $0 != "  " job ":" { capture = 0 }
    capture { print }
  ' "$deployment")"
  if [[ -z "$build_job" ]]; then
    echo "production image build job was not found: ${job}" >&2
    exit 1
  fi
  for required in 'needs: plan' 'id-token: write' 'push: true' '${{ github.sha }}' 'vars.GCP_BUILD_SERVICE_ACCOUNT'; do
    if [[ "$build_job" != *"$required"* ]]; then
      echo "production image build job ${job} is missing: ${required}" >&2
      exit 1
    fi
  done
  if [[ "$build_job" == *':latest'* ]]; then
    echo "production image build job ${job} must not update latest before checks pass" >&2
    exit 1
  fi
  if [[ "$build_job" == *'vars.GCP_DEPLOY_SERVICE_ACCOUNT'* ]]; then
    echo "production image build job ${job} must not receive the Cloud Run deploy identity" >&2
    exit 1
  fi
done

web_plan="$(printf '%s\n' 'web/src/App.tsx' | "$component_planner")"
if [[ "$(jq -r '.web and .cloud_run and (.agent | not) and (.zip_worker | not)' <<< "$web_plan")" != "true" ]]; then
  echo "component planner misclassified a frontend-only change" >&2
  exit 1
fi

server_plan="$(printf '%s\n' 'server/internal/app/app.go' | "$component_planner")"
if [[ "$(jq -r '.backend and .cloud_run and .zip_worker and (.agent_service | not)' <<< "$server_plan")" != "true" ]]; then
  echo "component planner misclassified a backend-only change" >&2
  exit 1
fi

agent_plan="$(printf '%s\n' 'agent/src/ledger_agent/main.py' | "$component_planner")"
if [[ "$(jq -r '.agent and .agent_service and (.cloud_run | not) and (.zip_worker | not)' <<< "$agent_plan")" != "true" ]]; then
  echo "component planner misclassified an agent-only change" >&2
  exit 1
fi

docs_plan="$(printf '%s\n' 'docs/privacy.md' | "$component_planner")"
if [[ "$(jq -r '([.[]] | any) | not' <<< "$docs_plan")" != "true" ]]; then
  echo "component planner must leave documentation-only changes idle" >&2
  exit 1
fi

workflow_script_plan="$(printf '%s\n' '.github/scripts/plan-components.sh' | "$component_planner")"
if [[ "$(jq -r '.backend and .agent and .web and (.deploy_any | not)' <<< "$workflow_script_plan")" != "true" ]]; then
  echo "component planner must validate shared workflow scripts without deploying application services" >&2
  exit 1
fi

worker_step="$(awk '
  /^      - name: Deploy private ZIP worker$/ { capture = 1 }
  /^      - name: Tag deployed ZIP worker image as latest$/ { capture = 0 }
  capture { print }
' "$deployment")"

if [[ "$worker_step" != *"needs.plan.outputs.zip_worker == 'true'"* ]]; then
  echo "ZIP worker deployment must be conditional" >&2
  exit 1
fi

for required in \
  'gcloud run deploy' \
  'gcloud run services set-iam-policy' \
  'gcloud run services get-iam-policy' \
  'gcloud run services describe'; do
  if [[ "$worker_step" != *"$required"* ]]; then
    echo "ZIP worker deployment step is missing: ${required}" >&2
    exit 1
  fi
done

if [[ "$worker_step" == *'gcloud auth print-identity-token'* ]]; then
  echo "ZIP worker deployment must not mint an identity token from WIF credentials" >&2
  exit 1
fi

agent_step="$(awk '
  /^      - name: Deploy private Bub Agent$/ { capture = 1 }
  /^      - name: Tag deployed Bub Agent image as latest$/ { capture = 0 }
  capture { print }
' "$deployment")"

if [[ "$agent_step" != *"needs.plan.outputs.agent_service == 'true'"* ]]; then
  echo "Bub Agent deployment must be conditional" >&2
  exit 1
fi

deploy_step="$(awk '
  /^      - name: Deploy Cloud Run service$/ { capture = 1 }
  /^      - name: Verify candidate and promote traffic$/ { capture = 0 }
  capture { print }
' "$deployment")"

for required in \
  "needs.plan.outputs.cloud_run == 'true'" \
  'legacy_migration_required=false' \
  'legacy_environment_present=' \
  '.configSource // empty' \
  '--set-secrets="${candidate_secret_mappings}"'; do
  if [[ "$deploy_step" != *"$required"* ]]; then
    echo "Cloud Run candidate deployment is missing guard: ${required}" >&2
    exit 1
  fi
done

verify_step="$(awk '
  /^      - name: Verify candidate and promote traffic$/ { capture = 1 }
  /^      - name: Restore failed promotion$/ { capture = 0 }
  capture { print }
' "$deployment")"

for required in \
  'steps.deploy-candidate.outputs.legacy_migration_required' \
  '--remove-env-vars=LEDGER_GITHUB_OWNER,LEDGER_GITHUB_REPO,LEDGER_GIT_BRANCH' \
  '--set-secrets="${platform_secret_mappings}"' \
  'Cloud Run service is not using database runtime configuration'; do
  if [[ "$verify_step" != *"$required"* ]]; then
    echo "Cloud Run promotion is missing database runtime verification: ${required}" >&2
    exit 1
  fi
done

if [[ "$verify_step" == *'--remove-secrets='* ]]; then
  echo "Cloud Run secret cleanup must use one set-secrets replacement operation" >&2
  exit 1
fi
