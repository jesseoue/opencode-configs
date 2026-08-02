#!/usr/bin/env bash
# Cost-safe regression fixtures for team/runtime diagnostics. No agent is
# started and no provider/model endpoint is called.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

pass=0 fail=0
ok(){ printf '  ✓ %s\n' "$*"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n' "$*"; fail=$((fail+1)); }
expect_text(){
  local name="$1" text="$2" pattern="$3"
  if printf '%s\n' "$text" | grep -qF "$pattern"; then ok "$name"; else
    bad "$name (missing: $pattern)"
  fi
}

printf '\nOpenConfig runtime diagnostic fixtures (no model calls)\n\n'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oc-runtime-fixtures.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Build a fixture from the working tree, including uncommitted content but no .git.
FIX="$TMP/repo"
mkdir -p "$FIX"
while IFS= read -r rel; do
  [[ -f "$REPO/$rel" || -L "$REPO/$rel" ]] || continue
  mkdir -p "$FIX/$(dirname "$rel")"
  cp -P "$REPO/$rel" "$FIX/$rel"
done < <(git -C "$REPO" ls-files)

python3 - "$FIX" <<'PY'
import json, os, sys
repo=sys.argv[1]
op=os.path.join(repo,"oh-my-openagent.json")
omo=json.load(open(op))
omo["disabled_agents"]=sorted(set(omo.get("disabled_agents") or [])|{"sisyphus"})
json.dump(omo,open(op,"w"),indent=2)
for name in ("debug-team","ship-feature"):
    path=os.path.join(repo,"teams",name,"config.json")
    team=json.load(open(path))
    if name=="debug-team":
        team["version"]=2
        team["unexpected"]=True
        team["members"][1]["prompt"]=team["members"][1]["prompt"].replace("DEPENDENCY:","GATE:")
    else:
        common=("ROLE: edit. METHOD: focused. OWNERSHIP: same files. "
                "Mailbox the lead. VERIFY: targeted fixture. "
                "SHUTDOWN: request shutdown and await approval.")
        team["members"][0]["prompt"]=common
        team["members"][1]["prompt"]=common
        team["members"][2]["prompt"]=(
            "ROLE: verify. DELIVERABLE: evidence. OWNERSHIP: no edits. "
            "Mailbox the lead. VERIFY: targeted fixture. DEPENDENCY: wait for forge."
        )
    json.dump(team,open(path,"w"),indent=2)
PY

out="$(OC_VALIDATE_REPO="$FIX" OC_VALIDATE_OFFLINE=1 "$REPO/validate.sh" --quiet 2>&1 || true)"
expect_text "disabled Sisyphus rejected" "$out" "sisyphus must not appear in disabled_agents"
expect_text "team version rejected" "$out" "version must be 1"
expect_text "unknown team key rejected" "$out" "unknown top-level keys"
expect_text "overlapping ownership rejected" "$out" "overlapping edit ownership"
expect_text "dependency gate required" "$out" "member 'root-cause' must include DEPENDENCY:"
expect_text "shutdown lifecycle required" "$out" "prompt missing team contract clauses: SHUTDOWN:"

python3 - "$FIX/oh-my-openagent.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["disabled_agents"]=[x for x in d.get("disabled_agents",[]) if x!="sisyphus"]
d["agents"].pop("sisyphus",None)
json.dump(d,open(p,"w"),indent=2)
PY
out="$(OC_VALIDATE_REPO="$FIX" OC_VALIDATE_OFFLINE=1 "$REPO/validate.sh" --quiet 2>&1 || true)"
expect_text "missing Sisyphus rejected" "$out" "agents.sisyphus missing"
expect_text "missing lead route rejected" "$out" "lead subagent_type 'sisyphus' is not declared"

# Custom XDG cache readiness requires matching main + platform package versions
# and an executable native launcher.
XDG="$TMP/custom-cache"
PIN="oh-my-openagent@4.19.4"
CDIR="$XDG/opencode/packages/$PIN"
suffix="$(python3 - <<'PY'
import platform
s=platform.system().lower(); m=platform.machine().lower()
print(("darwin-" if s=="darwin" else "linux-")+("arm64" if m in ("arm64","aarch64") else "x64"))
PY
)"
mkdir -p "$CDIR/node_modules/oh-my-openagent" "$CDIR/node_modules/oh-my-openagent-$suffix/bin"
printf '{"version":"4.19.4"}\n' >"$CDIR/node_modules/oh-my-openagent/package.json"
printf '{"version":"4.19.4"}\n' >"$CDIR/node_modules/oh-my-openagent-$suffix/package.json"
printf '#!/bin/sh\nexit 0\n' >"$CDIR/node_modules/oh-my-openagent-$suffix/bin/omo"
chmod +x "$CDIR/node_modules/oh-my-openagent-$suffix/bin/omo"
if XDG_CACHE_HOME="$XDG" oc_omo_plugin_cache_ok "$PIN"; then ok "custom XDG cache accepted"; else bad "custom XDG cache rejected"; fi
printf '{"version":"0.0.0"}\n' >"$CDIR/node_modules/oh-my-openagent-$suffix/package.json"
if XDG_CACHE_HOME="$XDG" oc_omo_plugin_cache_ok "$PIN"; then bad "mismatched native cache accepted"; else ok "mismatched native cache rejected"; fi

# Agent-list fixtures exercise success, missing visibility, and timeout paths.
FAKE="$TMP/fake-opencode"
cat >"$FAKE" <<'SH'
#!/bin/sh
case "${FAKE_AGENT_MODE:-ok}" in
  timeout) sleep 2 ;;
  missing) printf 'Sisyphus - ultraworker (primary)\n' ;;
  *) printf 'Sisyphus - ultraworker (primary)\nHephaestus - Deep Agent (primary)\nSisyphus-Junior (subagent)\n' ;;
esac
SH
chmod +x "$FAKE"
out="$(FAKE_AGENT_MODE=ok oc_agent_visibility_report "$FAKE" "$REPO" 1)"
if ! printf '%s\n' "$out" | grep -q '^BAD|' && printf '%s\n' "$out" | grep -q 'without starting a model'; then
  ok "bounded runtime visibility success"
else bad "runtime visibility success fixture"; fi
out="$(FAKE_AGENT_MODE=missing oc_agent_visibility_report "$FAKE" "$REPO" 1)"
expect_text "runtime-visible gap reported" "$out" "declared/cache-ready but not runtime-visible"
out="$(FAKE_AGENT_MODE=timeout oc_agent_visibility_report "$FAKE" "$REPO" 0.1)"
expect_text "runtime probe timeout bounded" "$out" "timed out"

LOG="$TMP/opencode.log"
cat >"$LOG" <<'EOF'
level=ERROR message="Expected a string starting with 'ses'"
level=ERROR tool=background_output message="Expected a string starting with 'bg'"
level=WARN tool=background_output block=true duration=712.7s
EOF
out="$(oc_log_misuse_report "$LOG")"
expect_text "ses misuse remediation" "$out" "requires the real ses_…"
expect_text "bg misuse remediation" "$out" "accepts only real bg_…"
expect_text "blocking poll remediation" "$out" "consume the completion notification"

printf '\nResult: %d passed · %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
