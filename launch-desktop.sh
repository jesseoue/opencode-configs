#!/bin/bash
# Inject opencode API keys into the GUI (launchd) environment so that
# desktop apps (T3 Code, etc.) can resolve {env:...} placeholders.
# Sourced keys come from ~/.config/opencode/.env (allowlisted only).

set -euo pipefail

ENV_FILE="$HOME/.config/opencode/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

# Allowlist of keys to expose to the GUI environment (T3 Code, etc.).
for KEY in OPENROUTER_API_KEY VENICE_API_KEY EXA_API_KEY CONTEXT7_API_KEY; do
  if [[ -n "${!KEY:-}" ]]; then
    launchctl setenv "$KEY" "${!KEY}"
  fi
done

# GUI apps (T3 Code) don't inherit shell PATH — expose opencode binary dir.
launchctl setenv PATH "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
