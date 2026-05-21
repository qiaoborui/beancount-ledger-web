#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-web-artifact.sh <environment> <port> <artifact-dir>

Deploy a GitHub-built Next.js standalone artifact on a Raspberry Pi/self-hosted runner.

Arguments:
  environment   prod | preview
  port          Port to bind, e.g. 3001 or 3002
  artifact-dir  Directory containing the downloaded artifact

Environment:
  DEPLOY_BASE       Base directory for app releases (default: $HOME/beancount-ledger-web-deploy)
  APP_ENV_FILE      Optional env file copied into the release as .env.local.
                    Variables inside it override script defaults.
                    In production this should set LEDGER_ROOT to your private ledger repo.
  GITHUB_SHA        Commit SHA, provided by GitHub Actions
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="${1:?environment is required}"
PORT="${2:?port is required}"
ARTIFACT_DIR="${3:?artifact directory is required}"

case "$ENVIRONMENT" in
  prod|preview) ;;
  *) echo "environment must be prod or preview" >&2; exit 2 ;;
esac

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "artifact directory does not exist: $ARTIFACT_DIR" >&2
  exit 2
fi

DEPLOY_BASE="${DEPLOY_BASE:-$HOME/beancount-ledger-web-deploy}"
ENV_DIR="$DEPLOY_BASE/$ENVIRONMENT"
RELEASES_DIR="$ENV_DIR/releases"
SHA="${GITHUB_SHA:-manual-$(date +%Y%m%d%H%M%S)}"
RELEASE_DIR="$RELEASES_DIR/${SHA:0:12}"
CURRENT_LINK="$ENV_DIR/current"
DEFAULT_LEDGER_ROOT="$ENV_DIR/ledger-root"
DEFAULT_RUNTIME_DIR="$ENV_DIR/runtime"
APP_NAME="beancount-web-$ENVIRONMENT"
DEFAULT_AUTH_DISABLED=false
if [[ "$ENVIRONMENT" == "preview" ]]; then
  DEFAULT_AUTH_DISABLED=true
fi

mkdir -p "$RELEASES_DIR" "$DEFAULT_LEDGER_ROOT" "$DEFAULT_RUNTIME_DIR"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

if [[ -d "$ARTIFACT_DIR/standalone" ]]; then
  cp -a "$ARTIFACT_DIR/standalone/." "$RELEASE_DIR/"
elif [[ -f "$ARTIFACT_DIR/server.js" ]]; then
  cp -a "$ARTIFACT_DIR/." "$RELEASE_DIR/"
else
  echo "artifact does not look like a Next.js standalone bundle: $ARTIFACT_DIR" >&2
  exit 1
fi

# Static files must sit next to the standalone server's .next directory.
if [[ -d "$ARTIFACT_DIR/static" ]]; then
  mkdir -p "$RELEASE_DIR/.next"
  cp -a "$ARTIFACT_DIR/static" "$RELEASE_DIR/.next/static"
fi
if [[ -d "$ARTIFACT_DIR/public" ]]; then
  cp -a "$ARTIFACT_DIR/public" "$RELEASE_DIR/public"
fi
if [[ -d "$ARTIFACT_DIR/examples" ]]; then
  cp -a "$ARTIFACT_DIR/examples" "$RELEASE_DIR/examples"
fi

# Agent skills live at the repository root, outside the Next.js standalone bundle.
# Copy them into the release so agent runtimes using this release as their
# workspace can discover project-local skills.
if [[ -d "$ARTIFACT_DIR/.agents" ]]; then
  cp -a "$ARTIFACT_DIR/.agents" "$RELEASE_DIR/.agents"
fi

if [[ -n "${APP_ENV_FILE:-}" ]]; then
  if [[ -f "$APP_ENV_FILE" ]]; then
    install -m 600 "$APP_ENV_FILE" "$RELEASE_DIR/.env.local"
  else
    umask 077
    printf '%s\n' "$APP_ENV_FILE" > "$RELEASE_DIR/.env.local"
  fi
fi

ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

echo "==> Starting/reloading $APP_NAME on port $PORT"
cd "$CURRENT_LINK"
set -a
if [[ -f .env.local ]]; then
  # shellcheck disable=SC1091
  source .env.local
fi
set +a

LEDGER_ROOT_EFFECTIVE="${LEDGER_ROOT:-$DEFAULT_LEDGER_ROOT}"
LEDGER_GIT_SCHEDULER_EFFECTIVE="${LEDGER_GIT_SCHEDULER:-false}"
LEDGER_AUTH_DISABLED_EFFECTIVE="${LEDGER_AUTH_DISABLED:-$DEFAULT_AUTH_DISABLED}"
LEDGER_GIT_REMOTE_DISABLED_EFFECTIVE="${LEDGER_GIT_REMOTE_DISABLED:-false}"
if [[ "$ENVIRONMENT" == "preview" ]]; then
  LEDGER_ROOT_EFFECTIVE="$CURRENT_LINK/examples/preview-ledger"
  LEDGER_GIT_SCHEDULER_EFFECTIVE=false
  LEDGER_AUTH_DISABLED_EFFECTIVE=true
  LEDGER_GIT_REMOTE_DISABLED_EFFECTIVE=true
fi
RUNTIME_DIR_EFFECTIVE="${RUNTIME_DIR:-$DEFAULT_RUNTIME_DIR}"
DEFAULT_SERVICE_PATH="/home/pi/.local/share/uv/tools/beancount/bin:/home/pi/go/bin:/home/pi/.local/bin:/home/pi/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin"
PATH_EFFECTIVE="$DEFAULT_SERVICE_PATH"
if [[ -n "${PATH:-}" ]]; then
  PATH_EFFECTIVE="$DEFAULT_SERVICE_PATH:$PATH"
fi
DOUBLE_ENTRY_GENERATOR_BIN_EFFECTIVE="${DOUBLE_ENTRY_GENERATOR_BIN:-}"
if [[ -z "$DOUBLE_ENTRY_GENERATOR_BIN_EFFECTIVE" ]]; then
  DOUBLE_ENTRY_GENERATOR_BIN_EFFECTIVE="$(PATH="$PATH_EFFECTIVE" command -v double-entry-generator || true)"
fi
PYTHON_BIN_EFFECTIVE="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN_EFFECTIVE" ]]; then
  PYTHON_BIN_EFFECTIVE="$(PATH="$PATH_EFFECTIVE" command -v python3 || true)"
fi
if [[ "$ENVIRONMENT" == "preview" ]]; then
  test -f "$LEDGER_ROOT_EFFECTIVE/main.bean"
  if ! git -C "$LEDGER_ROOT_EFFECTIVE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$LEDGER_ROOT_EFFECTIVE" init
    git -C "$LEDGER_ROOT_EFFECTIVE" config user.name "Preview Ledger"
    git -C "$LEDGER_ROOT_EFFECTIVE" config user.email "preview@example.invalid"
    git -C "$LEDGER_ROOT_EFFECTIVE" add .
    git -C "$LEDGER_ROOT_EFFECTIVE" commit -m "Initialize preview ledger"
  fi
else
  mkdir -p "$LEDGER_ROOT_EFFECTIVE"
fi
mkdir -p "$RUNTIME_DIR_EFFECTIVE"

# Write runtime env for systemd service. The service unit should reference this file
# with EnvironmentFile=<deploy-base>/<env>/systemd.env.
cat > "$ENV_DIR/systemd.env" << SYSEOF
PORT=$PORT
NODE_ENV=production
HOSTNAME=${APP_HOSTNAME:-0.0.0.0}
PATH=$PATH_EFFECTIVE
LEDGER_ROOT=$LEDGER_ROOT_EFFECTIVE
RUNTIME_DIR=$RUNTIME_DIR_EFFECTIVE
AUTH_SECRET=${AUTH_SECRET:-}
APP_PASSWORD=${APP_PASSWORD:-}
LEDGER_AUTH_DISABLED=$LEDGER_AUTH_DISABLED_EFFECTIVE
LEDGER_AI_PROVIDER=${LEDGER_AI_PROVIDER:-deepseek}
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-}
DEEPSEEK_BASE_URL=${DEEPSEEK_BASE_URL:-https://api.deepseek.com}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL:-deepseek-chat}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
OPENAI_BASE_URL=${OPENAI_BASE_URL:-https://api.openai.com}
OPENAI_MODEL=${OPENAI_MODEL:-gpt-4.1-mini}
WEB_PUSH_VAPID_PUBLIC_KEY=${WEB_PUSH_VAPID_PUBLIC_KEY:-}
NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY=${NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY:-}
WEB_PUSH_VAPID_PRIVATE_KEY=${WEB_PUSH_VAPID_PRIVATE_KEY:-}
WEB_PUSH_SUBJECT=${WEB_PUSH_SUBJECT:-}
BEAN_CHECK_BIN=${BEAN_CHECK_BIN:-}
DOUBLE_ENTRY_GENERATOR_BIN=$DOUBLE_ENTRY_GENERATOR_BIN_EFFECTIVE
PYTHON_BIN=$PYTHON_BIN_EFFECTIVE
LEDGER_GIT_SCHEDULER=$LEDGER_GIT_SCHEDULER_EFFECTIVE
LEDGER_GIT_REMOTE_DISABLED=$LEDGER_GIT_REMOTE_DISABLED_EFFECTIVE
LEDGER_GIT_PULL_INTERVAL_MINUTES=${LEDGER_GIT_PULL_INTERVAL_MINUTES:-15}
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=${LEDGER_GIT_COMMIT_INTERVAL_MINUTES:-60}
SYSEOF

# Restart via systemd (service unit must already exist on the host)
sudo systemctl restart "$APP_NAME"
if systemctl is-active --quiet "$APP_NAME"; then
  echo "==> $APP_NAME restarted successfully"
else
  echo "==> WARNING: $APP_NAME failed to start, checking logs..." >&2
  sudo journalctl -u "$APP_NAME" --no-pager -n 10 >&2
  exit 1
fi

# Keep the latest 5 releases for quick rollback, remove older ones.
find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 \
  | xargs -0 ls -dt 2>/dev/null \
  | tail -n +6 \
  | xargs -r rm -rf

echo "==> Deployed $APP_NAME at http://127.0.0.1:$PORT"
echo "    Release: $RELEASE_DIR"
echo "    LEDGER_ROOT: $LEDGER_ROOT_EFFECTIVE"
echo "    RUNTIME_DIR: $RUNTIME_DIR_EFFECTIVE"
