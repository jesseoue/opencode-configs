#!/usr/bin/env bash
# tests/smoke.sh — Structural + dry-run verification (no destructive writes).
#
# Proves the stack can check itself: validate, locate, fix --dry-run,
# cleanup --dry-run, setup --check. Safe on a live machine.
#
# Usage: ./tests/smoke.sh   |   oc test
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_g="\033[32m"; c_r="\033[31m"; c_b="\033[36m"; c_bold="\033[1m"; c_0="\033[0m"
else
  c_g=""; c_r=""; c_b=""; c_bold=""; c_0=""
fi

pass=0; fail=0
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; pass=$((pass+1)); }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; fail=$((fail+1)); }

printf "\n${c_bold}${c_b}OpenConfig smoke tests${c_0} (read-mostly)\n\n"

run_step() {
  local name="$1"; shift
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set +e
  if [[ $rc -eq 0 ]]; then
    ok "$name"
  else
    bad "$name (exit $rc)"
    printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
  fi
}

run_step "bash -n oc" bash -n "$REPO/oc"
run_step "bash -n locate.sh" bash -n "$REPO/locate.sh"
run_step "bash -n lib/common.sh" bash -n "$REPO/lib/common.sh"
run_step "validate --quiet" "$REPO/validate.sh" --quiet
run_step "locate --json" "$REPO/locate.sh" --json
run_step "signature" "$REPO/signature.sh"
run_step "fix --dry-run" "$REPO/fix.sh" --dry-run
run_step "cleanup --dry-run" "$REPO/cleanup.sh" --dry-run
run_step "setup --check" "$REPO/setup.sh" --check

# locate JSON schema basics
if "$REPO/locate.sh" --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
need=("repo","config_link","opencode_cli","env","projects_dir")
missing=[k for k in need if k not in d]
sys.exit(1 if missing else 0)
'; then
  ok "locate --json schema"
else
  bad "locate --json schema"
fi

# Helpers exist
for fn in oc_set_env_key_if_unset oc_ensure_env_file oc_link_points_to oc_ensure_symlink oc_verify_signature; do
  if grep -q "${fn}()" "$REPO/lib/common.sh"; then
    ok "helper $fn"
  else
    bad "helper $fn missing"
  fi
done

printf "\n${c_bold}Result:${c_0} %d passed · %d failed\n\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
