#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-frontend-artifact.sh <environment> <artifact-dir>

Deploy the Vite static artifact on a self-hosted runner.

Arguments:
  environment   prod | preview
  artifact-dir  Directory containing dist/

Environment:
  DEPLOY_BASE              Base directory for app releases (default: $HOME/beancount-ledger-web-deploy)
  FRONTEND_RELOAD_COMMAND  Optional shell command run after the symlink is updated,
                           for example: sudo systemctl reload nginx
  GITHUB_SHA               Commit SHA, provided by GitHub Actions
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="${1:?environment is required}"
ARTIFACT_DIR="${2:?artifact directory is required}"

case "$ENVIRONMENT" in
  prod|preview) ;;
  *) echo "environment must be prod or preview" >&2; exit 2 ;;
esac

if [[ ! -d "$ARTIFACT_DIR/dist" ]]; then
  echo "artifact does not contain dist/: $ARTIFACT_DIR" >&2
  exit 1
fi

DEPLOY_BASE="${DEPLOY_BASE:-$HOME/beancount-ledger-web-deploy}"
FRONTEND_DIR="$DEPLOY_BASE/$ENVIRONMENT/frontend"
RELEASES_DIR="$FRONTEND_DIR/releases"
SHA="${GITHUB_SHA:-manual-$(date +%Y%m%d%H%M%S)}"
RELEASE_DIR="$RELEASES_DIR/${SHA:0:12}"
CURRENT_LINK="$FRONTEND_DIR/current"

mkdir -p "$RELEASES_DIR"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cp -a "$ARTIFACT_DIR/dist" "$RELEASE_DIR/dist"
if [[ -f "$ARTIFACT_DIR/DEPLOYMENT.txt" ]]; then
  cp -a "$ARTIFACT_DIR/DEPLOYMENT.txt" "$RELEASE_DIR/DEPLOYMENT.txt"
fi
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

if [[ -n "${FRONTEND_RELOAD_COMMAND:-}" ]]; then
  echo "==> Reloading frontend service"
  bash -lc "$FRONTEND_RELOAD_COMMAND"
fi

find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 \
  | xargs -0 ls -dt 2>/dev/null \
  | tail -n +6 \
  | xargs -r rm -rf

echo "==> Deployed frontend $ENVIRONMENT"
echo "    Release: $RELEASE_DIR"
echo "    Static root: $CURRENT_LINK/dist"
