#!/usr/bin/env bash
# diagnose.sh — Deep, AI-assisted diagnostician for OpenConfig.
#
# Collects live signals from opencode (version, debug config, plugin cache,
# default-agent resolution) and OpenRouter (key usage/limits, per-model live
# routing), then asks an OpenRouter model to root-cause anything wrong and
# propose fixes. Can apply the fixes, or hand the whole repo to the opencode
# coding agent to fix autonomously. Interactive: it asks when it can't decide.
#
# Usage:
#   ./diagnose.sh               collect signals + AI diagnosis
#   ./diagnose.sh --no-ai       signals only, skip the model call
#   ./diagnose.sh --fix         apply the AI's ./fix.sh suggestions (asks each)
#   ./diagnose.sh --agent-fix   dispatch the opencode coding agent to fix the repo
#   ./diagnose.sh --model ID    diagnose with a specific OpenRouter model
#   ./diagnose.sh --yes         non-interactive (assume yes to safe prompts)
#
# Secrets are never sent to the model — the config is redacted first.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
OC_BIN="$(command -v opencode 2>/dev/null || echo "$OC_CLI_BIN")"
ENV_FILE="$REPO/.env"

AI=1; DOFIX=0; AGENTFIX=0; YES=0; AIMODEL=""
while [[ $# -gt 0 ]]; do case "$1" in
  --no-ai) AI=0; shift ;;
  --fix) DOFIX=1; shift ;;
  --agent-fix) AGENTFIX=1; shift ;;
  --yes|-y) YES=1; shift ;;
  --model) AIMODEL="$2"; shift 2 ;;
  -h|--help) oc_print_script_help "$0"; exit 0 ;;
  *) echo "Unknown flag: $1"; exit 2 ;;
esac; done

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[38;5;42m'; Y=$'\033[38;5;220m'; R=$'\033[38;5;203m'; B=$'\033[38;5;39m'
  M=$'\033[38;5;213m'; D=$'\033[2m'; BD=$'\033[1m'; Z=$'\033[0m'
else G=""; Y=""; R=""; B=""; M=""; D=""; BD=""; Z=""; fi
sec(){ printf "\n${B}${BD}▎%s${Z}\n" "$*"; }
ok(){ printf "  ${G}✓${Z} %s\n" "$*"; }
warn(){ printf "  ${Y}▲${Z} %s\n" "$*"; }
bad(){ printf "  ${R}✗${Z} %s\n" "$*"; }
tty(){ [[ -t 0 && -t 1 ]]; }
ask(){ [[ $YES -eq 1 ]] && return 0; tty || return 1; local r; read -r -p "  ${M}? $1 [y/N] ${Z}" r; [[ "$r" =~ ^[Yy]$ ]]; }
askval(){ tty || { echo ""; return; }; local r; read -r -p "  ${M}? $1 ${Z}" r; echo "$r"; }
getkey(){ oc_get_env_key "${ENV_FILE:-$REPO/.env}" "$1"; }

printf "\n${B}${BD}┌─ OpenConfig deep diagnostics ───────────────────────┐${Z}\n"
printf "${B}${BD}│${Z} %-51s ${B}${BD}│${Z}\n" "$REPO"
printf "${B}${BD}└─────────────────────────────────────────────────────┘${Z}\n"

ORKEY="$(getkey OPENROUTER_API_KEY)"; [[ -z "$ORKEY" ]] && ORKEY="${OPENROUTER_API_KEY:-}"
if [[ -z "$ORKEY" ]]; then
  warn "no OPENROUTER_API_KEY in .env or environment"
  [[ $YES -eq 0 ]] && tty && ORKEY="$(askval 'Paste an OpenRouter key for live checks (or blank to skip):')"
fi

FIXFILE="$(mktemp)"; ISSUEFILE="$(mktemp)"; HEALTHYFILE="$(mktemp)"; trap 'rm -f "$FIXFILE" "$ISSUEFILE" "$HEALTHYFILE"' EXIT

AI="$AI" AIMODEL="$AIMODEL" ORKEY="$ORKEY" OC_BIN="$OC_BIN" REPO="$REPO" \
FIXOUT="$FIXFILE" ISSUEOUT="$ISSUEFILE" HEALTHYOUT="$HEALTHYFILE" TTY="$([[ -t 1 ]] && echo 1 || echo 0)" NO_COLOR="${NO_COLOR:-}" \
python3 - <<'PY'
import json, os, subprocess, urllib.request, urllib.error, re

repo=os.environ["REPO"]; oc=os.environ["OC_BIN"]; key=os.environ["ORKEY"]
ai_on=os.environ["AI"]=="1"; aimodel=os.environ["AIMODEL"]
color=os.environ["TTY"]=="1" and not os.environ.get("NO_COLOR")
def c(code,s): return f"\033[{code}m{s}\033[0m" if color else s
G=lambda s:c("38;5;42",s); Y=lambda s:c("38;5;220",s); R=lambda s:c("38;5;203",s)
Bd=lambda s:c("38;5;39;1",s); D=lambda s:c("2",s)
def sec(t): print("\n"+Bd("▎"+t))
def li(sym,msg,cf): print(f"  {cf(sym)} {msg}")

conf=json.load(open(repo+"/opencode.json"))
omo=json.load(open(repo+"/oh-my-openagent.json"))
sig={}          # authoritative signals for the AI
info={}         # non-authoritative context (not treated as problems)

def run(*a,timeout=25):
    try:
        p=subprocess.run(a,capture_output=True,text=True,timeout=timeout); return p.returncode,p.stdout.strip()
    except Exception as e: return 1,str(e)

# ── opencode ──
sec("opencode")
rc,out=run(oc,"--version"); ver=out.splitlines()[0] if out else "?"; sig["opencode_version"]=ver
li("✓" if rc==0 else "✗", f"CLI {ver}", G if rc==0 else R)
pin=next((p for p in conf.get("plugin",[]) if "oh-my" in p),""); sig["plugin_pin"]=pin
cdir=os.path.expanduser(f"~/.cache/opencode/packages/{pin}")
cache_ok=os.path.isdir(cdir) and bool(os.listdir(cdir)); sig["plugin_cache_populated"]=cache_ok
li("✓" if cache_ok else "✗", f"plugin {pin} cache {'populated' if cache_ok else 'EMPTY → agents will NOT load'}", G if cache_ok else R)
da=conf.get("default_agent",""); da_def = da in (omo.get("agents") or {}) or da in {"build","plan","general"}
sig["default_agent"]=da; sig["default_agent_defined"]=da_def
sig["agents_will_load"]= bool(cache_ok and da_def)
li("✓" if da_def else "✗", f"default_agent '{da}' {'defined' if da_def else 'NOT defined → falls back to build'}", G if da_def else R)
rc,out=run(oc,"debug","config")
try: cnt=len(json.loads(out).get("agent") or {}) if out else 0
except: cnt=0
info["debug_config_agent_count_RACY"]=cnt
li("✓","authoritative: agents will load = "+("yes" if sig['agents_will_load'] else "NO")+D(f"  (debug-config count {cnt} is async-racy, ignored)"), G if sig['agents_will_load'] else R)

# ── OpenRouter account ──
def orget(p):
    rq=urllib.request.Request("https://openrouter.ai/api/v1"+p,headers={"Authorization":f"Bearer {key}"})
    return json.load(urllib.request.urlopen(rq,timeout=15))
if key:
    sec("OpenRouter account")
    try:
        d=orget("/key")["data"]
        sig["usage_total"]=round(d.get("usage") or 0,2); sig["usage_daily"]=round(d.get("usage_daily") or 0,2)
        sig["credit_limit"]=d.get("limit"); sig["is_free_tier"]=d.get("is_free_tier")
        li("✓", f"key valid · ${sig['usage_total']} total, ${sig['usage_daily']} today", G)
        lim=d.get("limit")
        if lim is None: li("✓","no hard credit limit", G)
        else:
            rem=d.get("limit_remaining") or 0
            li("▲" if rem<5 else "✓", f"limit ${lim}, remaining ${rem}", Y if rem<5 else G)
    except Exception as e:
        sig["or_key_error"]=str(e); li("✗", f"key check failed: {e}", R)
else:
    sec("OpenRouter account"); li("▲","skipped (no key)", Y)

# ── model routing (live) ──
route={}
if key:
    sec("Model routing (live)")
    for mid,m in conf["provider"]["openrouter"]["models"].items():
        if m.get("family")=="claude": continue
        body={"model":m.get("id",mid),"messages":[{"role":"user","content":"hi"}],"max_tokens":16}
        prov=(m.get("options") or {}).get("provider")
        if prov: body["provider"]=prov
        rq=urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
            data=json.dumps(body).encode(),headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
        try:
            d=json.load(urllib.request.urlopen(rq,timeout=20)); route[mid]="OK"; li("✓", f"{mid} routes ({d.get('provider','?')})", G)
        except urllib.error.HTTPError as e:
            try: msg=json.load(e).get("error",{}).get("message","")[:70]
            except: msg=f"HTTP {e.code}"
            route[mid]="ERR: "+msg; li("✗", f"{mid} → {msg}", R)
        except Exception as e:
            route[mid]="ERR: "+str(e)[:50]; li("✗", f"{mid} → {e}", R)
sig["routing"]=route

# ── validate ──
sec("Config validation")
rc,out=run(repo+"/validate.sh"); vlast=(out.splitlines() or ["?"])[-1].strip()
sig["validate_ok"]=rc==0; sig["validate_summary"]=vlast
li("✓" if rc==0 else "✗", f"validate.sh: {vlast}", G if rc==0 else R)

# ── issue synthesis (authoritative only) ──
issues=[]
if not cache_ok: issues.append(f"plugin cache empty for {pin} → agents not loading (pin a version that exists on npm under oh-my-openagent)")
if not da_def: issues.append(f"default_agent '{da}' not defined")
for mid,r in route.items():
    if r.startswith("ERR"): issues.append(f"model {mid} not routing ({r}) — likely max_price too low or all providers ignored")
if not sig["validate_ok"]: issues.append("config validation failing (run ./validate.sh)")
open(os.environ["ISSUEOUT"],"w").write("\n".join(issues))
# healthy (routing) models — so --agent-fix can run even if the default model is broken
open(os.environ["HEALTHYOUT"],"w").write("\n".join(m for m,r in route.items() if r=="OK"))

# ── AI diagnosis ──
if ai_on and key:
    sec("AI diagnosis")
    model=(aimodel or conf.get("model","z-ai/glm-5.2")).replace("openrouter/","")
    red=json.loads(json.dumps(conf))
    try: red["provider"]["openrouter"]["options"]["apiKey"]="<redacted>"
    except: pass
    sysmsg=("You are an expert diagnostician for OpenCode (opencode.ai), the oh-my-openagent/oh-my-opencode plugin, and "
      "OpenRouter provider routing. Trust the AUTHORITATIVE signals; ignore async-racy fields. Known failure modes: "
      "(1) experimental.primary_tools DENIES those tools to subagents; (2) oh-my-openagent agent 'color' must be hex or the "
      "whole agents section is dropped; (3) the plugin pin must be oh-my-openagent@<ver> that exists on npm (currently 4.19.0); "
      "empty cache means agents will not load; (4) a max_price cap that excludes every non-ignored provider "
      "causes 'All providers have been ignored'; (5) require_parameters:true + temperature blackholes Claude; (6) plugin agents "
      "register asynchronously so CLI agent listing is racy — use agents_will_load. If ISSUES is empty, say the setup is HEALTHY. "
      "Otherwise output PROBLEMS (root-caused), FIXES as exact ./fix.sh commands, and QUESTIONS only if info is missing. Be terse.")
    user=f"ISSUES={json.dumps(issues)}\nAUTHORITATIVE_SIGNALS={json.dumps(sig,indent=1)}\nCONFIG(redacted, truncated)={json.dumps(red)[:5000]}"
    payload={"model":model,"temperature":0.1,"max_tokens":700,
             "messages":[{"role":"system","content":sysmsg},{"role":"user","content":user}]}
    rq=urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",data=json.dumps(payload).encode(),
        headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    try:
        d=json.load(urllib.request.urlopen(rq,timeout=90)); txt=d["choices"][0]["message"]["content"].strip()
        print("  "+D(f"model: {model}"))
        for ln in txt.splitlines(): print("  "+ln)
        cmds=re.findall(r"\./fix\.sh --set [^\n`\"']+", txt)
        open(os.environ["FIXOUT"],"w").write("\n".join(dict.fromkeys(x.strip() for x in cmds)))
    except Exception as e:
        li("✗", f"AI call failed: {e}", R)
elif ai_on:
    sec("AI diagnosis"); li("▲","skipped (no key)", Y)

sec("Summary")
if not issues: print("  "+G("✓ No blocking issues — setup is healthy."))
else:
    print("  "+R(f"✗ {len(issues)} issue(s):"))
    for i in issues: print("    - "+i)
PY

# ── Apply fixes: always normalize footguns first, then AI --set picks ──
if [[ $DOFIX -eq 1 ]]; then
  sec "Apply fixes"
  if ask "run ./fix.sh (repair footguns + clean-format)?"; then
    ( cd "$REPO" && ./fix.sh ) >/dev/null 2>&1 && ok "./fix.sh applied" || bad "./fix.sh failed"
  fi
  if [[ -s "$FIXFILE" ]]; then
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      case "$cmd" in ./fix.sh\ --set\ *) ;; *) continue ;; esac
      if ask "run: $cmd ?"; then ( cd "$REPO" && eval "$cmd" ) && ok "applied" || bad "failed"; fi
    done < "$FIXFILE"
  fi
elif [[ -s "$FIXFILE" ]]; then
  sec "Suggested fixes (re-run with --fix to apply)"; sed 's/^/  → /' "$FIXFILE"
fi

# ── Hand the repo to the opencode coding agent to fix autonomously ──
if [[ $AGENTFIX -eq 1 ]]; then
  sec "Agent fix (opencode coding agent)"
  issues="$(cat "$ISSUEFILE" 2>/dev/null)"
  if [[ -z "$issues" ]]; then
    ok "no issues to fix — skipping agent dispatch"
  elif [[ -z "$ORKEY" ]]; then
    bad "no OpenRouter key — cannot run the coding agent"
  else
    agent="hephaestus"
    # Pick a model that VERIFIABLY routes (the broken model may be the default the
    # agent would otherwise use). Prefer a cheap healthy one; fall back to flash.
    healthy="$(head -1 "$HEALTHYFILE" 2>/dev/null)"
    fixmodel="openrouter/${healthy:-deepseek/deepseek-v4-flash}"
    prompt="You are working in the OpenCode config repo at ${REPO} (this IS ~/.config/opencode). These issues were detected by ./diagnose.sh:
${issues}

Fix them by editing opencode.json / oh-my-openagent.json. Rules: keep it cheap+agentic; the plugin pin must be oh-my-openagent@4.19.0; every model's max_price cap must admit at least one non-ignored provider (raise the cap if routing fails). After editing, run ./fix.sh then ./validate.sh then ./doctor.sh, and report exactly what you changed plus the final doctor summary."
    ok "using healthy model for the fixer: $fixmodel"
    if ask "dispatch 'opencode run --agent $agent --model $fixmodel' to fix ${REPO}?"; then
      ( set +u; cd "$REPO"; oc_export_env_file "$ENV_FILE"; "$OC_BIN" run --agent "$agent" --model "$fixmodel" "$prompt" ) \
        && ok "agent run complete — re-run ./doctor.sh to confirm" || bad "agent run failed"
    else
      warn "skipped agent dispatch"
    fi
  fi
fi
echo ""
