#!/usr/bin/env bash
# tests/smoke.sh — Structural + dry-run verification (no destructive writes).
#
# Proves the stack can check itself: validate, locate, fix --dry-run,
# cleanup --dry-run, setup --check. Safe on a live machine.
#
# Usage: ./tests/smoke.sh   |   oc test
#        OC_CI=1 ./tests/smoke.sh   hermetic (no live install / no API keys)
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

for arg in "$@"; do
  case "$arg" in
    --ci) export OC_CI=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown flag: $arg (try --ci)"; exit 2 ;;
  esac
done

# GitHub Actions / OC_CI=1: skip doctor, setup, key-backed probes.
if [[ "${OC_CI:-}" == "1" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  export OC_CI=1
  export OC_VALIDATE_OFFLINE="${OC_VALIDATE_OFFLINE:-1}"
  export OC_VALIDATE_REPO="${OC_VALIDATE_REPO:-$REPO}"
fi

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
if "    │oc │──── OpenConfig\n    ╰───╯     Pinned stack for vanilla OpenCode" not in readme:
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
run_step "oc secrets --help" "$REPO/oc" secrets --help
run_step "versions --local" "$REPO/versions.sh" --local
run_step "bash -n models.sh" bash -n "$REPO/models.sh"

if [[ "${OC_CI:-}" == "1" ]]; then
  ok "skipped setup/doctor/models probes (OC_CI=1 hermetic)"
else
  run_step "setup --check" "$REPO/setup.sh" --check
  run_step "doctor --quick" "$REPO/doctor.sh" --quick
  run_step "models --moderation" "$REPO/models.sh" --moderation

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
for fn in oc_set_env_key_if_unset oc_ensure_env_file oc_link_points_to oc_ensure_symlink oc_verify_signature oc_secrets_sync oc_export_vault_allowlist oc_vault_merged_json oc_vault_op_refs oc_live_config_root oc_is_live_config oc_runtime_conf_ok oc_banner oc_section oc_infisical_dir oc_openrouter_key_configured oc_telemetry_off; do
  if grep -q "${fn}()" "$REPO/lib/common.sh"; then
    ok "helper $fn"
  else
    bad "helper $fn missing"
  fi
done

# Vanilla stack: no plugin pin, no OmO config, deny-all gitignore, no host paths
if python3 - "$REPO" <<'PY'
import json, os, sys
repo = sys.argv[1]
for name in ("opencode.json", "tui.json"):
    if any("oh-my-" in str(p) for p in (json.load(open(os.path.join(repo, name))).get("plugin") or [])):
        raise SystemExit(f"{name}: oh-my plugin pinned")
if os.path.exists(os.path.join(repo, "oh-my-openagent.json")):
    raise SystemExit("oh-my-openagent.json still present")
if not open(os.path.join(repo, ".gitignore")).read().count("/*"):
    raise SystemExit(".gitignore default deny missing")
PY
then
  ok "no OmO plugin or config + deny-all gitignore"
else
  bad "OmO plugin or config still present — run: oc fix"
fi

# Content-aware is Venice-only (agent md + profile + quarantine skip)
if python3 - "$REPO" <<'PY'
import json, os, re, sys
repo = sys.argv[1]
want = {
    "content-aware-research": "venice/deepseek-v4-pro-0813",
    "content-aware-fast": "venice/deepseek-v4-1-flash-1017-uncensored",
    "content-aware-deep": "venice/abliteration-abliterated-model-large-v2",
    "context-aware-hermes": "openrouter/nousresearch/hermes-4-405b",
}
for name, model in want.items():
    md = open(os.path.join(repo, "agents", f"{name}.md"), encoding="utf-8").read()
    if f"model: {model}" not in md:
        raise SystemExit(f"{name}: expected {model}")
    if not re.search(r"^\s+edit: deny", md, re.M):
        raise SystemExit(f"{name}: edit must be denied")
gp = json.load(open(os.path.join(repo, "profiles", "content-aware.json"), encoding="utf-8"))
if not str(gp.get("model") or "").startswith("venice/") or not str(gp.get("small_model") or "").startswith("venice/"):
    raise SystemExit("content-aware profile must stay on venice")
PY
then
  ok "content-aware Venice-only (agents + profile)"
else
  bad "content-aware left Venice — restore agents/ or profiles/content-aware.json"
fi

# No duplicate agent definitions between opencode.json and agents/*.md (TUI crash)
if python3 - "$REPO" <<'PY'
import glob, json, os, sys
repo = sys.argv[1]
md = {os.path.basename(p)[:-3] for p in glob.glob(os.path.join(repo, "agents", "*.md"))}
dupes = md & set(json.load(open(os.path.join(repo, "opencode.json"))).get("agent") or {})
if dupes or os.path.exists(os.path.join(repo, "cursor.sh")):
    raise SystemExit(f"duplicate agents: {sorted(dupes)}")
PY
then
  ok "no duplicate native agent definitions"
else
  bad "duplicate native agents or leftover oc cursor files"
fi

# OpenRouter attribution (marketplace categories are hyphenated; cli,agent is dropped)
if python3 -c '
import json, sys
oc=json.load(open(sys.argv[1]))
h=((oc.get("provider") or {}).get("openrouter") or {}).get("options") or {}
hdrs=h.get("headers") or {}
ok=(hdrs.get("X-OpenRouter-Title")=="OpenConfig"
    and hdrs.get("X-Title")=="OpenConfig"
    and hdrs.get("X-OpenRouter-Categories")=="cli-agent"
    and str(hdrs.get("HTTP-Referer") or "").endswith("jesseoue/opencode-configs"))
sys.exit(0 if ok else 1)
' "$REPO/opencode.json"; then
  ok "openrouter attribution (cli-agent + OpenConfig title)"
else
  bad "openrouter attribution headers — run: oc fix"
fi

# signature.version must match versions.json (heal/test identity)
if python3 - "$REPO" <<'PY'
import json, sys
repo = sys.argv[1]
sig = json.load(open(f"{repo}/signature.json", encoding="utf-8"))
ver = json.load(open(f"{repo}/versions.json", encoding="utf-8"))
s, v = str(sig.get("version") or "").strip(), str(ver.get("opencode_configs") or "").strip()
if not s or s != v:
    raise SystemExit(f"{s!r} != {v!r}")
PY
then
  ok "signature.version == versions.json"
else
  bad "signature.version drift — run: oc signature --refresh"
fi

# .env.example assignment names ⊆ OC_ENV_ALLOWLIST; allowlist names documented
if python3 - "$REPO" <<'PY'
import re, sys
repo = sys.argv[1]
common = open(f"{repo}/lib/common.sh", encoding="utf-8").read()
m = re.search(r"OC_ENV_ALLOWLIST=\((.*?)\)", common, re.S)
if not m:
    raise SystemExit("allowlist missing")
allow = set(re.findall(r"\b[A-Z][A-Z0-9_]+\b", m.group(1)))
ex = open(f"{repo}/.env.example", encoding="utf-8").read()
assigned = set()
for raw in ex.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    if "=" in line:
        assigned.add(line.split("=", 1)[0].strip())
unknown = sorted(assigned - allow)
if unknown:
    raise SystemExit("example keys not in allowlist: " + ",".join(unknown))
missing = sorted(k for k in allow if k not in ex)
if missing:
    raise SystemExit("allowlist names missing from .env.example: " + ",".join(missing))
PY
then
  ok ".env.example names match OC_ENV_ALLOWLIST"
else
  bad ".env.example / allowlist mismatch"
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
