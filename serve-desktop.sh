#!/bin/bash
# Keep a warm opencode serve for T3 Code (and other GUIs) on the pinned port
# from opencode.json server.port (4097). Loads API keys from .env.

set -euo pipefail

REPO="${HOME}/.config/opencode"
ENV_FILE="${REPO}/.env"
PORT=4097
HOST=127.0.0.1
LOG_DIR="${HOME}/.t3/userdata/logs"
LOG_FILE="${LOG_DIR}/opencode-serve.log"

mkdir -p "$LOG_DIR"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Mirror keys into launchd so other GUI apps still resolve {env:...}.
if [[ -x "${REPO}/launch-desktop.sh" ]]; then
  "${REPO}/launch-desktop.sh" >/dev/null 2>&1 || true
fi

exec "${HOME}/.local/bin/opencode" serve --hostname="$HOST" --port="$PORT" >>"$LOG_FILE" 2>&1
