#!/bin/bash
# launch-desktop.sh — Launch OpenCode desktop app with allowlisted keys from .env
# Ensures OPENROUTER_API_KEY (and other allowlisted keys) are in the app's
# environment so the ai-sdk runtime can authenticate to OpenRouter.
#
# Usage: ~/.config/opencode/launch-desktop.sh
#   (also wired as a LaunchAgent so the app always gets the keys)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

ENV_FILE="${REPO}/.env"

# Export allowlisted keys (OPENROUTER_API_KEY, EXA_API_KEY, CONTEXT7_API_KEY, etc.)
oc_export_env_file "$ENV_FILE"

# Telemetry off
oc_telemetry_off

# `open -a` launches via LaunchServices, which does NOT inherit the shell's
# exported env vars — the app starts fresh and misses OPENROUTER_API_KEY,
# causing "Missing Authentication header". Push the allowlisted keys into the
# LaunchServices environment with `launchctl setenv` so the app inherits them.
for _key in "${OC_ENV_ALLOWLIST[@]}"; do
  if [[ -n "${!_key:-}" ]]; then
    launchctl setenv "$_key" "${!_key}"
  else
    launchctl unsetenv "$_key" 2>/dev/null || true
  fi
done

# Launch the desktop app. It now inherits the keys from the LaunchServices env.
open -a OpenCode

echo "launch-desktop.sh: OpenCode launched with allowlisted keys from .env"
