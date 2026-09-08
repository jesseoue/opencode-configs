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
  c_g=$'\033[32m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_0=$'\033[0m'
else
  c_g=""; c_r=""; c_b=""; c_dim=""; c_bold=""; c_0=""
fi

pass=0; fail=0
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; pass=$((pass+1)); }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; fail=$((fail+1)); }

oc_section "oc test"
printf "  ${c_dim}smoke (read-mostly)${c_0}\n\n"

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

# oc aliases dispatch to the right handlers (no full doctor run — help only)
if "$REPO/oc" health --help 2>&1 | grep -q 'oc check'; then
  ok "oc health → check"
else
  bad "oc health alias broken"
fi
if "$REPO/oc" repair --help 2>&1 | grep -q 'oc heal'; then
  ok "oc repair → heal"
else
  bad "oc repair alias broken"
fi
if "$REPO/oc" verify --help 2>&1 | grep -q 'validate'; then
  ok "oc verify → validate"
else
  bad "oc verify alias broken"
fi
if "$REPO/oc" help 2>&1 | grep -q 'health, ready'; then
  ok "oc help lists aliases"
else
  bad "oc help missing aliases section"
fi
if NO_COLOR=1 "$REPO/oc" help 2>&1 | grep -q $'\033'; then
  bad "oc help leaks ANSI under NO_COLOR"
else
  ok "oc help respects NO_COLOR"
fi
if python3 - "$REPO" <<'PY'
import os, subprocess, sys
repo = sys.argv[1]
env = {**os.environ, "NO_COLOR": "1"}
help_out = subprocess.check_output([os.path.join(repo, "oc"), "help"], env=env, text=True)
mark = [l for l in help_out.splitlines() if l.startswith("    ╭") or l.startswith("    │oc") or l.startswith("    ╰")]
if len(mark) != 3:
    raise SystemExit("mark lines != 3")
if any(len(l) > 72 for l in mark):
    raise SystemExit("mark wider than 72")
if mark[1].find("OpenConfig") != 14 or mark[2].find("Pinned") != 14:
    raise SystemExit("wordmark misaligned")
readme = open(os.path.join(repo, "README.md"), encoding="utf-8").read()
if "    │oc │──── OpenConfig\n    ╰───╯     Pinned stack for OpenCode · OpenRouter · OmO" not in readme:
    raise SystemExit("README mark != CLI")
PY
then
  ok "brand mark aligned · ≤72 cols · README match"
else
  bad "brand mark width/align/README"
fi

run_step "bash -n doctor.sh" bash -n "$REPO/doctor.sh"
run_step "bash -n locate.sh" bash -n "$REPO/locate.sh"
run_step "bash -n versions.sh" bash -n "$REPO/versions.sh"
run_step "bash -n lib/common.sh" bash -n "$REPO/lib/common.sh"
run_step "validate --quiet" "$REPO/validate.sh" --quiet
run_step "locate --json" "$REPO/locate.sh" --json
run_step "signature" "$REPO/signature.sh"
run_step "fix --dry-run" "$REPO/fix.sh" --dry-run
run_step "cleanup --dry-run" "$REPO/cleanup.sh" --dry-run
run_step "setup --check" "$REPO/setup.sh" --check
run_step "oc secrets --help" "$REPO/oc" secrets --help
run_step "doctor --quick" "$REPO/doctor.sh" --quick
run_step "versions --local" "$REPO/versions.sh" --local

run_step "bash -n models.sh" bash -n "$REPO/models.sh"
run_step "models --moderation" "$REPO/models.sh" --moderation >/dev/null

# doctor --json schema (machine summary for heal/check tooling)
if "$REPO/doctor.sh" --quick --json 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read()
if "──" in raw: raise SystemExit(4)
d=json.loads(raw)
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
if ! "$REPO/validate.sh" --quiet 2>/dev/null | grep -q '──'; then
  ok "validate --quiet no chrome"
else
  bad "validate --quiet leaked section chrome"
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
for fn in oc_set_env_key_if_unset oc_ensure_env_file oc_link_points_to oc_ensure_symlink oc_verify_signature oc_secrets_sync oc_export_vault_allowlist oc_vault_merged_json oc_vault_op_refs oc_live_config_root oc_is_live_config oc_omo_teams_canonical oc_omo_teams_ok oc_runtime_conf_ok oc_banner oc_section; do
  if grep -q "${fn}()" "$REPO/lib/common.sh"; then
    ok "helper $fn"
  else
    bad "helper $fn missing"
  fi
done

# /goal disabled + no ralph_loop + footgun doc (OmO 4.19.x breaks /start-work when goal is on)
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
  && ! grep -qE '/Users/[A-Za-z0-9_-]+/' "$REPO/zshrc.snippet" \
  && grep -q 'plugins' "$REPO/lib/common.sh"; then
  ok "goal off + ralph removed + plugins scrubbed + deny-all gitignore + no host paths"
else
  bad "goal/ralph/plugins hygiene incomplete (goal must be off; ralph_loop must be gone)"
fi

# Fast concurrency pins (background_task + provider caps)
if python3 -c '
import json, sys
omo=json.load(open(sys.argv[1]))
bt=omo.get("background_task") or {}
pc=bt.get("providerConcurrency") or {}
ok=(bt.get("defaultConcurrency")==10
    and pc.get("openrouter")==12 and "openai" not in pc and "anthropic" not in pc)
sys.exit(0 if ok else 1)
' "$REPO/oh-my-openagent.json"; then
  ok "fast concurrency pins (default=10 openrouter=12 only)"
else
  bad "concurrency drift — run: oc fix"
fi

# Team mode schema + ~/.omo/teams → live ~/.config/opencode (not this checkout)
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

def is_openconfig(path):
    sig_p = os.path.join(path, "signature.json")
    if not (os.path.isfile(os.path.join(path, "opencode.json")) and os.path.isdir(os.path.join(path, "teams")) and os.path.isfile(sig_p)):
        return False
    try:
        sig = json.load(open(sig_p, encoding="utf-8"))
    except Exception:
        return False
    return sig.get("product") == "OpenConfig" and sig.get("cli") == "oc" and sig.get("id") == "jesseoue/opencode-configs"

xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
link = os.path.join(xdg, "opencode")
live = os.path.realpath(link) if os.path.lexists(link) else ""
canonical = live if live and is_openconfig(live) else os.path.realpath(repo)
base = tm.get("base_dir") or "~/.omo"
if base.startswith("~/"):
    base = os.path.join(os.path.expanduser("~"), base[2:])
ldir = os.path.join(base, "teams")
tdir = os.path.join(canonical, "teams")
for name in os.listdir(tdir):
    if not os.path.isfile(os.path.join(tdir, name, "config.json")):
        continue
    linkp = os.path.join(ldir, name)
    if not os.path.islink(linkp):
        sys.exit(3)
    if os.path.realpath(linkp) != os.path.realpath(os.path.join(tdir, name)):
        sys.exit(4)
sys.exit(0)
PY
then
  ok "team mode schema + ~/.omo/teams → live config"
else
  bad "team mode incomplete — run: oc setup from the live install"
fi

# Public vault.json must stay generic; personal refs live in vault.local.json
if git -C "$REPO" check-ignore -q vault.local.json \
  && grep -q 'vault.local.json' "$REPO/.gitignore" \
  && ! grep -qE '[a-z0-9.-]+\.1password\.com|op://[a-z0-9]{20,}/' "$REPO/vault.json"; then
  ok "vault.json generic + vault.local.json gitignored"
else
  bad "vault.json leaked personal 1Password ids or vault.local.json is trackable"
fi

printf "\n${c_bold}Result:${c_0} %d passed · %d failed\n\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
