#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-backend-artifact.sh <environment> <port> <artifact-dir>

Deploy the Go API artifact on a self-hosted runner.

Arguments:
  environment   prod | preview
  port          Public app port to bind, e.g. 3001 or 3002
  artifact-dir  Directory containing ledger-web and optional examples/.agents

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
REQUESTED_PORT="$PORT"

case "$ENVIRONMENT" in
  prod|preview) ;;
  *) echo "environment must be prod or preview" >&2; exit 2 ;;
esac

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "artifact directory does not exist: $ARTIFACT_DIR" >&2
  exit 2
fi
if [[ ! -f "$ARTIFACT_DIR/ledger-web" ]]; then
  echo "artifact does not contain ledger-web: $ARTIFACT_DIR" >&2
  exit 1
fi

DEPLOY_BASE="${DEPLOY_BASE:-$HOME/beancount-ledger-web-deploy}"
ENV_DIR="$DEPLOY_BASE/$ENVIRONMENT"
BACKEND_DIR="$ENV_DIR/backend"
RELEASES_DIR="$BACKEND_DIR/releases"
SHA="${GITHUB_SHA:-manual-$(date +%Y%m%d%H%M%S)}"
RELEASE_DIR="$RELEASES_DIR/${SHA:0:12}"
CURRENT_LINK="$BACKEND_DIR/current"
DEFAULT_LEDGER_ROOT="$ENV_DIR/ledger-root"
DEFAULT_RUNTIME_DIR="$ENV_DIR/runtime"
APP_NAME="beancount-ledger-api-$ENVIRONMENT"
LEGACY_APP_NAME="beancount-web-$ENVIRONMENT"
DEFAULT_AUTH_DISABLED=false
if [[ "$ENVIRONMENT" == "preview" ]]; then
  DEFAULT_AUTH_DISABLED=true
fi
SERVICE_USER_EFFECTIVE="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
SERVICE_GROUP_EFFECTIVE="${SERVICE_GROUP:-$(id -gn "$SERVICE_USER_EFFECTIVE")}"
SERVICE_HOME_EFFECTIVE="$(getent passwd "$SERVICE_USER_EFFECTIVE" | cut -d: -f6)"
if [[ -z "$SERVICE_HOME_EFFECTIVE" ]]; then
  SERVICE_HOME_EFFECTIVE="$HOME"
fi

mkdir -p "$RELEASES_DIR" "$DEFAULT_LEDGER_ROOT" "$DEFAULT_RUNTIME_DIR"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cp -a "$ARTIFACT_DIR/ledger-web" "$RELEASE_DIR/ledger-web"
chmod +x "$RELEASE_DIR/ledger-web"

if [[ -d "$ARTIFACT_DIR/examples" ]]; then
  cp -a "$ARTIFACT_DIR/examples" "$RELEASE_DIR/examples"
fi
if [[ -d "$ARTIFACT_DIR/.agents" ]]; then
  cp -a "$ARTIFACT_DIR/.agents" "$RELEASE_DIR/.agents"
fi
if [[ -f "$ARTIFACT_DIR/DEPLOYMENT.txt" ]]; then
  cp -a "$ARTIFACT_DIR/DEPLOYMENT.txt" "$RELEASE_DIR/DEPLOYMENT.txt"
fi

if [[ -n "${APP_ENV_FILE:-}" ]]; then
  if [[ -f "$APP_ENV_FILE" ]]; then
    install -m 600 "$APP_ENV_FILE" "$RELEASE_DIR/.env.local"
  elif [[ "$APP_ENV_FILE" == *"="* ]]; then
    umask 077
    printf '%s\n' "$APP_ENV_FILE" > "$RELEASE_DIR/.env.local"
  else
    echo "APP_ENV_FILE points to a missing env file: $APP_ENV_FILE" >&2
    exit 1
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

# The deploy workflow owns the public port. Runner-side env files may still contain
# PORT from the legacy combined service; ignore that value so the app keeps the
# externally routed port selected by GitHub Actions variables.
PORT_EFFECTIVE="$REQUESTED_PORT"

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
STATIC_DIR_EFFECTIVE="$ENV_DIR/frontend/current/dist"
DEFAULT_SERVICE_PATH="$SERVICE_HOME_EFFECTIVE/.local/share/uv/tools/beancount/bin:$SERVICE_HOME_EFFECTIVE/go/bin:$SERVICE_HOME_EFFECTIVE/.local/bin:$SERVICE_HOME_EFFECTIVE/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin"
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
PDFTOTEXT_BIN_EFFECTIVE="${PDFTOTEXT_BIN:-}"
if [[ -z "$PDFTOTEXT_BIN_EFFECTIVE" ]]; then
  PDFTOTEXT_BIN_EFFECTIVE="$(PATH="$PATH_EFFECTIVE" command -v pdftotext || true)"
fi
if [[ -z "$PDFTOTEXT_BIN_EFFECTIVE" ]] && command -v apt-get >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  echo "==> Installing poppler-utils for PDF statement import"
  sudo apt-get update
  sudo apt-get install -y poppler-utils
  PDFTOTEXT_BIN_EFFECTIVE="$(PATH="$PATH_EFFECTIVE" command -v pdftotext || true)"
fi

git_ledger() {
  git -c "safe.directory=$LEDGER_ROOT_EFFECTIVE" -C "$LEDGER_ROOT_EFFECTIVE" "$@"
}
if [[ "$ENVIRONMENT" == "preview" ]]; then
  test -f "$LEDGER_ROOT_EFFECTIVE/main.bean"
  if ! git_ledger rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_ledger init
    git_ledger config user.name "Preview Ledger"
    git_ledger config user.email "preview@example.invalid"
    git_ledger add .
    git_ledger commit -m "Initialize preview ledger"
  fi
else
  mkdir -p "$LEDGER_ROOT_EFFECTIVE"
fi
mkdir -p "$RUNTIME_DIR_EFFECTIVE"

cat > "$BACKEND_DIR/systemd.env" << SYSEOF
PORT=$PORT_EFFECTIVE
GIN_MODE=release
HOME=$SERVICE_HOME_EFFECTIVE
PATH=$PATH_EFFECTIVE
LEDGER_ROOT=$LEDGER_ROOT_EFFECTIVE
RUNTIME_DIR=$RUNTIME_DIR_EFFECTIVE
STATIC_DIR=$STATIC_DIR_EFFECTIVE
SERVE_STATIC=true
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
WEB_PUSH_VAPID_PRIVATE_KEY=${WEB_PUSH_VAPID_PRIVATE_KEY:-}
WEB_PUSH_SUBJECT=${WEB_PUSH_SUBJECT:-}
BEAN_CHECK_BIN=${BEAN_CHECK_BIN:-}
DOUBLE_ENTRY_GENERATOR_BIN=$DOUBLE_ENTRY_GENERATOR_BIN_EFFECTIVE
PYTHON_BIN=$PYTHON_BIN_EFFECTIVE
PDFTOTEXT_BIN=$PDFTOTEXT_BIN_EFFECTIVE
LEDGER_GIT_AUTHOR_NAME=${LEDGER_GIT_AUTHOR_NAME:-}
LEDGER_GIT_AUTHOR_EMAIL=${LEDGER_GIT_AUTHOR_EMAIL:-}
LEDGER_GIT_SCHEDULER=$LEDGER_GIT_SCHEDULER_EFFECTIVE
LEDGER_GIT_REMOTE_DISABLED=$LEDGER_GIT_REMOTE_DISABLED_EFFECTIVE
LEDGER_GIT_PULL_INTERVAL_MINUTES=${LEDGER_GIT_PULL_INTERVAL_MINUTES:-15}
LEDGER_GIT_COMMIT_INTERVAL_MINUTES=${LEDGER_GIT_COMMIT_INTERVAL_MINUTES:-60}
SYSEOF

SERVICE_SCOPE="${SERVICE_SCOPE:-}"
if [[ -z "$SERVICE_SCOPE" ]]; then
  if sudo -n true >/dev/null 2>&1; then
    SERVICE_SCOPE=system
  else
    SERVICE_SCOPE=user
  fi
fi

case "$SERVICE_SCOPE" in
  system)
    SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
    SYSTEMCTL=(sudo systemctl)
    SERVICE_INSTALL_TARGET=multi-user.target
    SERVICE_USER_LINES=$'User='"$SERVICE_USER_EFFECTIVE"$'\nGroup='"$SERVICE_GROUP_EFFECTIVE"
    ;;
  user)
    USER_SYSTEMD_DIR="$SERVICE_HOME_EFFECTIVE/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD_DIR"
    SERVICE_FILE="$USER_SYSTEMD_DIR/$APP_NAME.service"
    SYSTEMCTL=(systemctl --user)
    SERVICE_INSTALL_TARGET=default.target
    SERVICE_USER_LINES=""
    ;;
  *) echo "SERVICE_SCOPE must be system or user" >&2; exit 2 ;;
esac

if [[ "$SERVICE_SCOPE" == "system" ]]; then
  sudo tee "$SERVICE_FILE" >/dev/null << SERVICEEOF
[Unit]
Description=Beancount Ledger API ($ENVIRONMENT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
$SERVICE_USER_LINES
WorkingDirectory=$CURRENT_LINK
EnvironmentFile=$BACKEND_DIR/systemd.env
ExecStart=$CURRENT_LINK/ledger-web
Restart=always
RestartSec=5

[Install]
WantedBy=$SERVICE_INSTALL_TARGET
SERVICEEOF
else
  cat > "$SERVICE_FILE" << SERVICEEOF
[Unit]
Description=Beancount Ledger API ($ENVIRONMENT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$CURRENT_LINK
EnvironmentFile=$BACKEND_DIR/systemd.env
ExecStart=$CURRENT_LINK/ledger-web
Restart=always
RestartSec=5

[Install]
WantedBy=$SERVICE_INSTALL_TARGET
SERVICEEOF
fi
"${SYSTEMCTL[@]}" daemon-reload
"${SYSTEMCTL[@]}" enable "$APP_NAME" >/dev/null
if "${SYSTEMCTL[@]}" list-unit-files "$LEGACY_APP_NAME.service" >/dev/null 2>&1; then
  "${SYSTEMCTL[@]}" disable --now "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
fi
"${SYSTEMCTL[@]}" restart "$APP_NAME"
if "${SYSTEMCTL[@]}" is-active --quiet "$APP_NAME"; then
  echo "==> $APP_NAME restarted successfully"
else
  echo "==> WARNING: $APP_NAME failed to start, checking logs..." >&2
  if [[ "$SERVICE_SCOPE" == "system" ]]; then
    sudo journalctl -u "$APP_NAME" --no-pager -n 10 >&2
  else
    journalctl --user -u "$APP_NAME" --no-pager -n 10 >&2
  fi
  exit 1
fi

find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 \
  | xargs -0 ls -dt 2>/dev/null \
  | tail -n +6 \
  | xargs -r rm -rf

echo "==> Deployed $APP_NAME"
echo "    Port: $PORT_EFFECTIVE"
echo "    Release: $RELEASE_DIR"
echo "    LEDGER_ROOT: $LEDGER_ROOT_EFFECTIVE"
echo "    RUNTIME_DIR: $RUNTIME_DIR_EFFECTIVE"
echo "    STATIC_DIR: $STATIC_DIR_EFFECTIVE"
echo "    SERVICE_SCOPE: $SERVICE_SCOPE"
