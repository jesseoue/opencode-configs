#!/usr/bin/env bash
# Keep a warm opencode serve for T3 Code (and other GUIs) on the pinned
# port from opencode.json server.port (4097). Allowlisted keys only.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

PORT=4097
HOST=127.0.0.1
LOG_DIR="${HOME}/.t3/userdata/logs"
LOG_FILE="${LOG_DIR}/opencode-serve.log"

mkdir -p "$LOG_DIR"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

oc_export_env_file "$REPO/.env"
oc_export_vault_allowlist

if [[ -x "${REPO}/launch-desktop.sh" ]]; then
  "${REPO}/launch-desktop.sh" >/dev/null 2>&1 || true
fi

exec "${HOME}/.local/bin/opencode" serve --hostname="$HOST" --port="$PORT" >>"$LOG_FILE" 2>&1
