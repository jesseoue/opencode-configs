#!/usr/bin/env bash
# run.sh — Headless OpenCode runner (non-interactive).
#
# Wraps `opencode run`: runs one message to completion. Secrets are loaded from
# allowlisted .env keys only (never `source .env`, never Infisical process wrap)
# and telemetry is off.
#
# Usage:
#   ./run.sh "Fix the failing tests in apps/api"
#   ./run.sh -a build -d ~/my-repo "Implement the plan in .opencode/plans/x.md"
#   ./run.sh --json "Refactor the payment module"
#
# Flags:
#   -a, --agent <name>        agent (default: default_agent from config)
#   -m, --model <prov/model>  model override
#   -d, --directory <path>    working directory (default: resolved launch dir)
#   --json                    raw JSON event output
#   --session-id <id>         resume an existing session
#   --                        everything after is the message (use if it starts with -)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
ENV_FILE="${REPO}/.env"

[[ "${1:-}" =~ ^(-h|--help)$ ]] && { oc_print_script_help "$0"; exit 0; }

# ── Split our flags from the trailing message. ──
declare -a RUN_ARGS=()
RUN_DIR=""
MSG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)        RUN_ARGS+=(--agent "$2"); shift 2 ;;
    -m|--model)        RUN_ARGS+=(--model "$2"); shift 2 ;;
    -d|--directory)    RUN_DIR="$2"; shift 2 ;;
    --json)            RUN_ARGS+=(--format json); shift ;;
    --session-id)      RUN_ARGS+=(--session "$2"); shift 2 ;;
    --)                shift; MSG="$*"; break ;;
    *)                 MSG="$*"; break ;;
  esac
done
[[ -z "$MSG" ]] && { echo "run.sh: no message. See ./run.sh --help"; exit 2; }

[[ -n "$RUN_DIR" ]] || RUN_DIR="$(oc_resolve_launch_dir 2>/dev/null || pwd -P)"

oc_telemetry_off
oc_export_env_file "$ENV_FILE"
oc_export_vault_allowlist

run_cli() {
  # nounset-safe empty RUN_ARGS under `set -u`
  if ((${#RUN_ARGS[@]})); then
    (cd "$RUN_DIR" && opencode run "${RUN_ARGS[@]}" "$MSG" </dev/null)
  else
    (cd "$RUN_DIR" && opencode run "$MSG" </dev/null)
  fi
}

# OpenCode may still drop package.json/node_modules into the config dir while
# loading plugins — scrub before and after so the repo stays config-only.
scrub() { oc_scrub_config_strays "$REPO" >/dev/null; }
scrub

# ── Allowlisted .env keys only (never Infisical/Doppler process wrap). ──
RC=0
[[ -z "${OPENROUTER_API_KEY:-}" ]] && echo "run.sh: warning — OPENROUTER_API_KEY not set" >&2
run_cli || RC=$?

scrub
exit "$RC"
