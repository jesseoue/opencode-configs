#!/usr/bin/env bash
# run.sh — Headless OpenCode runner (non-interactive) with completion enforcement.
#
# Wraps `oh-my-openagent run`: starts/attaches an OpenCode server, runs one
# message to completion, and exits ONLY when every todo is done/cancelled and
# all background child sessions are idle. Secrets are loaded from allowlisted
# .env keys only (never `source .env`, never Infisical process wrap), telemetry
# is off, and the plugin version is taken from opencode.json so the CLI matches
# the loaded plugin.
#
# Because `run` just takes a message, this also runs slash commands headlessly,
# e.g.  ./run.sh "/init-deep"   or   ./run.sh "/handoff".
#
# Usage:
#   ./run.sh "Fix the failing tests in apps/api"
#   ./run.sh -a hephaestus -d ~/my-repo "Implement the plan in .omo/plans/x.md"
#   ./run.sh --json --on-complete './doctor.sh' "Refactor the payment module"
#   ./run.sh "/init-deep --max-depth=3"
#
# Flags (passed through to `oh-my-openagent run`):
#   -a, --agent <name>        agent (default: default_run_agent from config → sisyphus)
#   -m, --model <prov/model>  model override
#   -d, --directory <path>    working directory (default: $PWD)
#   --json                    structured JSON result
#   --on-complete <cmd>       shell command to run after completion
#   --session-id <id>         resume an existing session
#   --                        everything after is the message (use if it starts with -)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
ENV_FILE="${REPO}/.env"

[[ "${1:-}" =~ ^(-h|--help)$ ]] && { oc_print_script_help "$0"; exit 0; }

# ── Resolve the pinned plugin so the CLI matches the loaded plugin. ──
PIN="$(python3 -c "import json;p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my' in x];print(p[0] if p else '')" 2>/dev/null)"
CLI_PKG="${PIN:-oh-my-openagent@latest}"

# ── Split our flags from the trailing message. ──
declare -a RUN_ARGS=()
MSG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)        RUN_ARGS+=(--agent "$2"); shift 2 ;;
    -m|--model)        RUN_ARGS+=(--model "$2"); shift 2 ;;
    -d|--directory)    RUN_ARGS+=(--directory "$2"); shift 2 ;;
    --json)            RUN_ARGS+=(--json); shift ;;
    --on-complete)     RUN_ARGS+=(--on-complete "$2"); shift 2 ;;
    --session-id)      RUN_ARGS+=(--session-id "$2"); shift 2 ;;
    --)                shift; MSG="$*"; break ;;
    *)                 MSG="$*"; break ;;
  esac
done
[[ -z "$MSG" ]] && { echo "run.sh: no message. See ./run.sh --help"; exit 2; }

# Default working directory to a safe project path (never the config repo).
# Under `set -u`, empty `${RUN_ARGS[*]}` unbound-errors on bash 3.2 / nounset —
# use `${arr[*]-}` so a zero-flag invocation (`oc run "msg"`) still works.
case " ${RUN_ARGS[*]-} " in
  *" --directory "*) ;;
  *)
    _run_dir="$(oc_resolve_launch_dir 2>/dev/null || pwd -P)"
    RUN_ARGS+=(--directory "$_run_dir")
    unset _run_dir
    ;;
esac

oc_telemetry_off
oc_export_env_file "$ENV_FILE"

# bunx writes package.json/node_modules into cwd — never run it from the
# config repo (or a user project). Use a dedicated cache dir instead.
OMO_BUNX_CWD="${XDG_CACHE_HOME:-${HOME}/.cache}/opencode/omo-cli-runner"
mkdir -p "$OMO_BUNX_CWD"

run_cli() {
  # nounset-safe empty RUN_ARGS under `set -u`
  if ((${#RUN_ARGS[@]})); then
    (cd "$OMO_BUNX_CWD" && bunx "$CLI_PKG" run "${RUN_ARGS[@]}" "$MSG")
  else
    (cd "$OMO_BUNX_CWD" && bunx "$CLI_PKG" run "$MSG")
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
