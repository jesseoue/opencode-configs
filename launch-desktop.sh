#!/usr/bin/env bash
# Inject allowlisted API keys into the GUI (launchd) environment so
# desktop apps (T3 Code, etc.) can resolve {env:...} placeholders.
# Never `source .env`. Never `op run` / `infisical run`.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

oc_export_env_file "$REPO/.env"
oc_export_vault_allowlist

for KEY in OPENROUTER_API_KEY VENICE_API_KEY EXA_API_KEY CONTEXT7_API_KEY; do
  if [[ -n "${!KEY:-}" ]]; then
    launchctl setenv "$KEY" "${!KEY}"
  fi
done

launchctl setenv PATH "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
