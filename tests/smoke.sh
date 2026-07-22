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
run_step "bash -n doctor.sh" bash -n "$REPO/doctor.sh"
run_step "bash -n locate.sh" bash -n "$REPO/locate.sh"
run_step "bash -n lib/common.sh" bash -n "$REPO/lib/common.sh"
run_step "validate --quiet" "$REPO/validate.sh" --quiet
run_step "locate --json" "$REPO/locate.sh" --json
run_step "signature" "$REPO/signature.sh"
run_step "fix --dry-run" "$REPO/fix.sh" --dry-run
run_step "cleanup --dry-run" "$REPO/cleanup.sh" --dry-run
run_step "setup --check" "$REPO/setup.sh" --check
run_step "doctor --quick" "$REPO/doctor.sh" --quick

# doctor --json schema (machine summary for heal/check tooling)
if "$REPO/doctor.sh" --quick --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
need=("ok","ready","critical","optional","soft","verdict","version","repo")
missing=[k for k in need if k not in d]
if missing: raise SystemExit(1)
if d.get("critical", 1) != 0: raise SystemExit(2)
if d.get("verdict") not in ("ready", "core_ready"): raise SystemExit(3)
'; then
  ok "doctor --json schema"
else
  bad "doctor --json schema"
fi

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

# /goal disabled + no ralph_loop + footgun doc (OmO 4.19.0 breaks /start-work when goal is on)
if [[ -f "$REPO/prompts/goal.md" ]] \
  && grep -q 'prompts/goal.md' "$REPO/opencode.json" \
  && python3 -c '
import json,sys
omo=json.load(open(sys.argv[1]))
g=omo.get("goal") or {}
dm=omo.get("default_mode") or {}
ok=(g.get("enabled") is False and g.get("auto_start") is False
    and dm.get("goal") is False and "ralph_loop" not in omo)
sys.exit(0 if ok else 1)
' "$REPO/oh-my-openagent.json" \
  && grep -q 'plugins' "$REPO/.gitignore" \
  && grep -qE '^/\*$' "$REPO/.gitignore" \
  && grep -q '!prompts/' "$REPO/.gitignore" \
  && ! grep -qE '/Users/Shared/(lm-agents|test-speed)' "$REPO/zshrc.snippet" \
  && grep -q 'plugins' "$REPO/lib/common.sh"; then
  ok "goal off + ralph removed + plugins scrubbed + deny-all gitignore + no host paths"
else
  bad "goal/ralph/plugins hygiene incomplete (goal must be off; ralph_loop must be gone)"
fi

# Team mode schema + ~/.omo/teams symlinks (not directory copies)
if python3 - "$REPO" <<'PY'
import json, os, sys
repo = sys.argv[1]
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
tm = omo.get("team_mode") or {}
need = [
    "enabled", "tmux_visualization", "max_parallel_members", "max_members",
    "max_messages_per_run", "max_wall_clock_minutes", "max_member_turns",
    "base_dir", "message_payload_max_bytes", "recipient_unread_max_bytes",
    "mailbox_poll_interval_ms",
]
if tm.get("enabled") is not True or any(k not in tm for k in need):
    sys.exit(1)
tx = omo.get("tmux") or {}
if tx.get("enabled") is not True or tx.get("layout") != "main-vertical":
    sys.exit(2)
base = tm.get("base_dir") or "~/.omo"
if base.startswith("~/"):
    base = os.path.join(os.path.expanduser("~"), base[2:])
ldir = os.path.join(base, "teams")
tdir = os.path.join(repo, "teams")
for name in os.listdir(tdir):
    if not os.path.isfile(os.path.join(tdir, name, "config.json")):
        continue
    link = os.path.join(ldir, name)
    if not os.path.islink(link):
        sys.exit(3)
    if os.path.realpath(link) != os.path.realpath(os.path.join(tdir, name)):
        sys.exit(4)
sys.exit(0)
PY
then
  ok "team mode schema + ~/.omo/teams symlinks"
else
  bad "team mode incomplete — run: oc fix && oc setup"
fi

printf "\n${c_bold}Result:${c_0} %d passed · %d failed\n\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
