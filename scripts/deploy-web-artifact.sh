#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-web-artifact.sh <environment> <port> <artifact-dir>

Compatibility wrapper for older combined Go/Vite artifacts. New deployments
should call deploy-backend-artifact.sh and deploy-frontend-artifact.sh directly.

Arguments:
  environment   prod | preview
  port          Backend API port to bind
  artifact-dir  Directory containing ledger-web and optionally web/dist or dist
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="${1:?environment is required}"
PORT="${2:?port is required}"
ARTIFACT_DIR="${3:?artifact directory is required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/deploy-backend-artifact.sh" "$ENVIRONMENT" "$PORT" "$ARTIFACT_DIR"

if [[ -d "$ARTIFACT_DIR/dist" ]]; then
  "$SCRIPT_DIR/deploy-frontend-artifact.sh" "$ENVIRONMENT" "$ARTIFACT_DIR"
elif [[ -d "$ARTIFACT_DIR/web/dist" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -a "$ARTIFACT_DIR/web/dist" "$tmp/dist"
  if [[ -f "$ARTIFACT_DIR/DEPLOYMENT.txt" ]]; then
    cp -a "$ARTIFACT_DIR/DEPLOYMENT.txt" "$tmp/DEPLOYMENT.txt"
  fi
  "$SCRIPT_DIR/deploy-frontend-artifact.sh" "$ENVIRONMENT" "$tmp"
else
  echo "==> No frontend dist/ found in artifact; backend deployed only"
fi
