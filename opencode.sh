#!/bin/bash
# opencode.sh — Launch OpenCode with allowlisted keys from .env
# Usage: ~/.config/opencode/opencode.sh [directory]
#
# Loads allowlisted keys from ~/.config/opencode/.env (never `source`s the file —
# values with & in DB URLs break shell source). Does NOT wrap Infisical/Doppler
# (that injects vault-wide secrets into the agent). Sync keys with:
#   oc setup --sync-env

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

OPENCODE_BIN=""
if [[ -x "${OC_CLI_BIN:-}" ]]; then
  OPENCODE_BIN="$OC_CLI_BIN"
elif [[ -x "$HOME/.opencode/bin/opencode" ]]; then
  OPENCODE_BIN="$HOME/.opencode/bin/opencode"
else
  OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
fi
[[ -n "$OPENCODE_BIN" && -x "$OPENCODE_BIN" ]] || {
  echo "opencode.sh: OpenCode CLI not found" >&2
  exit 1
}
FORCE=""
TARGET_RAW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --here|--force-cwd) FORCE=force; shift ;;
    -h|--help)
      echo "Usage: opencode.sh [--here] [directory]"
      echo "  Starts OpenCode in [directory] (default: cwd)."
      echo "  Config repo / bare ~/Projects → ~/Projects/workspace."
      echo "  --here  allow starting inside the config repo"
      exit 0 ;;
    -*)
      echo "opencode.sh: unknown flag: $1" >&2
      exit 2 ;;
    *)
      TARGET_RAW="$1"; shift; break ;;
  esac
done
TARGET_DIR="$(oc_resolve_launch_dir "${TARGET_RAW:-}" "${FORCE}")" || exit 1
ENV_FILE="${REPO}/.env"

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "opencode.sh: need an interactive terminal (tty)" >&2
  exit 1
fi

oc_telemetry_off
oc_export_env_file "$ENV_FILE"
# Live OpenCode may drop package.json/node_modules into the config symlink target
oc_scrub_config_strays "$REPO" >/dev/null

cd "$TARGET_DIR" || {
  echo "opencode.sh: cannot cd to $TARGET_DIR" >&2
  exit 1
}

echo "Launching OpenCode from $TARGET_DIR..." >&2
export TERM=xterm-256color
export DO_NOT_TRACK=1 OMO_DISABLE_POSTHOG=1 OMO_SEND_ANONYMOUS_TELEMETRY=0
export OMO_CODEX_DISABLE_POSTHOG=1 OMO_CODEX_SEND_ANONYMOUS_TELEMETRY=0
export CODEGRAPH_TELEMETRY=0 OTEL_SDK_DISABLED=true
exec "$OPENCODE_BIN" .
