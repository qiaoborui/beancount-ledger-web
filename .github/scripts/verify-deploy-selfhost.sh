#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub and shell expressions below are literal guard strings.
set -euo pipefail

workflow="${1:-.github/workflows/deploy-selfhost.yml}"
ci="${2:-.github/workflows/ci.yml}"
compose="${3:-docker/docker-compose.selfhost.yml}"
dockerfile="${4:-docker/Dockerfile}"
runbook="${5:-docs/headscale-local-cicd.md}"
observability_compose="${6:-docker/docker-compose.selfhost-observability.yml}"
observability_env="${7:-docker/selfhost-observability.env}"

for file in "$workflow" "$ci" "$compose" "$dockerfile" "$runbook" "$observability_compose" "$observability_env"; do
  if [[ ! -f "$file" ]]; then
    echo "required self-host deployment file is missing: ${file}" >&2
    exit 1
  fi
done

observability_config="$(docker compose \
  --env-file .env.selfhost.example \
  --env-file "$observability_env" \
  -f "$compose" \
  -f "$observability_compose" \
  config --format json)"
if ! jq -e '
  .services.server.environment.METRICS_ADDR == ":9091"
  and .services.server.environment.METRICS_ALLOW_NON_LOOPBACK == "true"
  and ([.services.server.ports[] | select(.target == 9091)] | length) == 1
  and ([.services.server.ports[] | select(.target == 9091)][0]
    | .published == "9091" and .host_ip == "127.0.0.1" and .protocol == "tcp")
' >/dev/null <<< "$observability_config"; then
  echo "self-host observability override must publish enabled metrics on loopback only" >&2
  exit 1
fi
for required in \
  'METRICS_ADDR: "${METRICS_ADDR:?set METRICS_ADDR in observability.env}"' \
  'METRICS_ALLOW_NON_LOOPBACK: "${METRICS_ALLOW_NON_LOOPBACK:?set METRICS_ALLOW_NON_LOOPBACK in observability.env}"'; do
  if ! grep -Fq -- "$required" "$observability_compose"; then
    echo "self-host observability override must be self-contained: ${required}" >&2
    exit 1
  fi
done

if ! grep -Fq 'restrict,from="127.0.0.1",command="sudo -n /usr/local/sbin/beancount-ledger-deploy-submit"' "$runbook"; then
  echo "userspace Tailscale deploy SSH key must accept only the loopback handoff" >&2
  exit 1
fi
if grep -Fq 'restrict,from="100.64.0.0/10",command="sudo -n /usr/local/sbin/beancount-ledger-deploy-submit"' "$runbook"; then
  echo "tailnet source CIDR is not visible to sshd behind userspace Tailscale" >&2
  exit 1
fi

for required in \
  'branches: [main]' \
  'cancel-in-progress: false' \
  'uses: ./.github/workflows/ci.yml' \
  'environment: local-selfhost-production' \
  'name: Deployment ref guard' \
  'manual self-hosted deployment must target refs/heads/main' \
  'SELFHOST_DEPLOY_ENABLED=true only after every prerequisite is ready' \
  'name: Reject an outdated main commit' \
  'host_contract: 2' \
  'tailscale/github-action@306e68a486fd2350f2bfc3b19fcd143891a4a2d8' \
  '--login-server=${{ vars.HEADSCALE_CONTROL_URL }}' \
  'DEPLOY_PORT: ${{ vars.SELFHOST_DEPLOY_PORT }}' \
  '-p "$DEPLOY_PORT"' \
  'StrictHostKeyChecking=yes' \
  'needs: [ref-guard, checks, build-server, build-indexer, build-agent, build-frontend, build-zip-worker]'; do
  if ! grep -Fq -- "$required" "$workflow"; then
    echo "self-host deployment workflow is missing: ${required}" >&2
    exit 1
  fi
done

if ! grep -Fq 'compose "$maintenance_env" up -d --no-build database zip-worker server indexer frontend' scripts/selfhost/beancount-ledger-deploy-run; then
  echo "maintenance validation must start only services that can run behind the 503 guard" >&2
  exit 1
fi
for required in \
  'observability_compose_file="${config_dir}/compose.observability.yml"' \
  'observability_env="${config_dir}/observability.env"' \
  '--env-file "$observability_env"' \
  '-f "$observability_compose_file"' \
  'observability override files must be installed together' \
  'observability override files have unsafe ownership or modes'; do
  if ! grep -Fq -- "$required" scripts/selfhost/beancount-ledger-deploy-run; then
    echo "self-host deployer does not preserve the optional observability override: ${required}" >&2
    exit 1
  fi
done
if grep -Fq 'compose "$maintenance_env" up -d --no-build database server agent indexer frontend' scripts/selfhost/beancount-ledger-deploy-run \
  || grep -Fq 'wait_for_healthy_service "$maintenance_env" agent' scripts/selfhost/beancount-ledger-deploy-run; then
  echo "agent cannot become ready while the server is in deployment maintenance mode" >&2
  exit 1
fi
if ! grep -Fq 'compose "$release_env" up -d --no-build database zip-worker server agent indexer frontend' scripts/selfhost/beancount-ledger-deploy-run \
  || ! grep -Fq 'wait_for_healthy_service "$release_env" zip-worker' scripts/selfhost/beancount-ledger-deploy-run; then
  echo "active releases must start and verify the internal ZIP Worker" >&2
  exit 1
fi
if ! grep -Fq 'pull_image_with_retry()' scripts/selfhost/beancount-ledger-deploy-run \
  || [[ "$(grep -Fc 'pull_image_with_retry "' scripts/selfhost/beancount-ledger-deploy-run)" -ne 3 ]] \
  || grep -Fq 'timeout --foreground 300 docker pull "${images[$component]}"' scripts/selfhost/beancount-ledger-deploy-run; then
  echo "immutable image pulls must use bounded retries before deployment starts" >&2
  exit 1
fi

if grep -Eq 'runs-on:[[:space:]]*\[?self-hosted|runs-on:[[:space:]]*mibook' "$workflow"; then
  echo "local production deployment must not run on a self-hosted runner" >&2
  exit 1
fi
if grep -Fq 'actions/checkout@' <(awk '/^  deploy:/{capture=1} capture{print}' "$workflow"); then
  echo "the privileged deploy job must not check out repository code" >&2
  exit 1
fi
if grep -E '^[[:space:]]*- uses:' "$workflow" \
  | grep -vF 'uses: ./.github/workflows/ci.yml' \
  | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' >/dev/null; then
  echo "every external action in the privileged workflow must use a full commit SHA" >&2
  exit 1
fi
if grep -Eq '(^|[^-])latest([^a-z-]|$)' "$workflow"; then
  echo "self-host deployment images must not use latest tags" >&2
  exit 1
fi

if [[ "$(grep -Fc 'platforms: linux/amd64' "$workflow")" -ne 5 ]]; then
  echo "all five self-hosted application images must target linux/amd64" >&2
  exit 1
fi
if [[ "$(grep -Fc "if: \${{ github.ref == 'refs/heads/main' }}" "$workflow")" -ne 5 ]]; then
  echo "every image build must refuse non-main workflow dispatches" >&2
  exit 1
fi
if [[ "$(grep -Fc 'needs: checks' "$workflow")" -ne 5 ]]; then
  echo "every image build must wait for application checks" >&2
  exit 1
fi
if [[ "$(grep -Fc 'VCS_REF=${{ github.sha }}' "$workflow")" -ne 5 ]]; then
  echo "all five self-hosted application images must carry the source SHA" >&2
  exit 1
fi
for required in 'target: selfhost-server' 'target: selfhost-indexer' 'target: zip-worker' 'LEDGER_UID=1000' 'LEDGER_GID=1000'; do
  if ! grep -Fq "$required" "$workflow"; then
    echo "host-specific image build is missing: ${required}" >&2
    exit 1
  fi
done

for required in \
  'name: Gate' \
  'needs: [plan, go, agent, web]' \
  'Require every planned check to pass'; do
  if ! grep -Fq "$required" "$ci"; then
    echo "CI is missing its stable gate: ${required}" >&2
    exit 1
  fi
done

for required in \
  'SELFHOST_SERVER_IMAGE' \
  'SELFHOST_INDEXER_IMAGE' \
  'SELFHOST_AGENT_IMAGE' \
  'SELFHOST_FRONTEND_IMAGE' \
  'SELFHOST_ZIP_WORKER_IMAGE' \
  'SELFHOST_APP_PULL_POLICY' \
  'SELFHOST_CADDYFILE_PATH' \
  'LEDGER_MAINTENANCE_MODE' \
  'LEDGER_INDEXER_STANDBY'; do
  if ! grep -Fq "$required" "$compose"; then
    echo "self-hosted Compose is missing immutable release input: ${required}" >&2
    exit 1
  fi
done

if [[ "$(grep -Fc 'org.opencontainers.image.revision=$VCS_REF' "$dockerfile")" -lt 5 ]]; then
  echo "self-hosted images must expose their source revision" >&2
  exit 1
fi

for script in .github/scripts/test-deploy-selfhost-submit.sh scripts/selfhost/beancount-ledger-deploy-submit scripts/selfhost/beancount-ledger-deploy-run scripts/selfhost/beancount-ledger-recover-pending scripts/selfhost/beancount-ledger-rollback; do
  if [[ ! -x "$script" ]]; then
    echo "host deployment helper is missing or not executable: ${script}" >&2
    exit 1
  fi
  bash -n "$script"
done

for required in \
  'backup_root="${state_dir}/backups"' \
  'GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' \
  'core.fsmonitor=false' \
  'quiesce_application' \
  'timeout --foreground' \
  'prior_env="${release_dir}/${instance}.prior.env"' \
  '.phase = "committed"' \
  'activation_file="${state_dir}/activation.json"' \
  'completion_file="${state_dir}/completion.json"' \
  'rollback_activation_file="${state_dir}/rollback-activation.json"' \
  'activate_rollback_release' \
  'activate_committed_release' \
  'finalize_completed_activation' \
  'LEDGER_MAINTENANCE_MODE=false' \
  'LEDGER_MAINTENANCE_MODE=true' \
  'LEDGER_INDEXER_STANDBY=false' \
  'LEDGER_INDEXER_STANDBY=true' \
  'systemctl show --property=ActiveState' \
  'status_file: $status_file' \
  '--confirm-deployed-sha'; do
  if ! grep -R -Fq -- "$required" scripts/selfhost; then
    echo "host deployment safety invariant is missing: ${required}" >&2
    exit 1
  fi
done
