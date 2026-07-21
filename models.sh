#!/usr/bin/env bash
# models.sh — Model-analysis doctor. Queries the live OpenRouter catalog,
# audits the models this config pins, and recommends the best models per role
# for a cheap, agentic, tool-calling setup.
#
# "Best" = cost-efficient + capable: must support tool calling; prefers large
# context, reasoning support, cache pricing, and proven coding families. The
# OpenRouter API exposes price/context/params but NOT quality benchmarks, so
# picks are ranked objectively and biased toward known-good coder families.
#
# Usage:
#   ./models.sh              audit configured models + recommend per role
#   ./models.sh --catalog    just the ranked recommendations
#   ./models.sh --providers  live endpoint health vs provider.order/ignore
#   ./models.sh --json       machine-readable output
#   ./models.sh --upgrade    detect NEWER versions of the models we pin
#   ./models.sh --upgrade --apply   apply the version bumps (backs up + validates)
#
# Apply a pick with:  ./fix.sh --set model=openrouter/<id>   (or small_model=…)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

MODE="audit"; APPLY=0
for a in "$@"; do case "$a" in
  --catalog) MODE="catalog" ;;
  --providers) MODE="providers" ;;
  --json) MODE="json" ;;
  --upgrade) MODE="upgrade" ;;
  --apply) APPLY=1 ;;
  -h|--help) oc_print_script_help "$0"; exit 0 ;;
  *) echo "Unknown flag: $a"; exit 2 ;;
esac; done

# ── Live provider health vs configured order/ignore ─────────────────
if [[ "$MODE" == "providers" ]]; then
  KEY="$(oc_get_env_key "$REPO/.env" OPENROUTER_API_KEY 2>/dev/null || true)"
  [[ -z "$KEY" ]] && KEY="${OPENROUTER_API_KEY:-}"
  [[ -n "$KEY" ]] || { echo "  ✗ OPENROUTER_API_KEY required for --providers"; exit 1; }
  REPO="$REPO" KEY="$KEY" python3 - <<'PY'
import json, os, sys, urllib.request
repo=os.environ["REPO"]; key=os.environ["KEY"]
oc=json.load(open(os.path.join(repo,"opencode.json")))
models=oc["provider"]["openrouter"]["models"]
tty=sys.stdout.isatty()
def col(c,s): return f"\033[{c}m{s}\033[0m" if tty else s
G=lambda s:col("32",s); Y=lambda s:col("33",s); R=lambda s:col("31",s); B=lambda s:col("36;1",s)

def endpoints(slug):
    req=urllib.request.Request(
        f"https://openrouter.ai/api/v1/models/{slug}/endpoints",
        headers={"Authorization":f"Bearer {key}"},
    )
    with urllib.request.urlopen(req, timeout=45) as r:
        return (json.load(r).get("data") or {}).get("endpoints") or []

def base(tag): return (tag or "").split("/")[0]
issues=0
print(B("== Provider routing health (live OpenRouter endpoints) =="))
for key,cfg in models.items():
    api=(cfg.get("id") or key).split(":",1)[0]
    prov=(cfg.get("options") or {}).get("provider") or {}
    order=list(prov.get("order") or [])
    ignore=set(prov.get("ignore") or [])
    try: eps=endpoints(api)
    except Exception as e:
        print("  "+R("✗")+f" {key}: endpoints failed ({e})"); issues+=1; continue
    by={}
    for e in eps:
        b=base(e.get("tag") or "")
        if not b: continue
        tools="tools" in set(e.get("supported_parameters") or [])
        status=e.get("status") or 0
        tps=(e.get("throughput_last_30m") or {}).get("p50") or 0
        up=e.get("uptime_last_30m") or 0
        quant=e.get("quantization") or "unknown"
        score=(1000 if status==0 and tools else 0) + min(tps,200) + up*0.5
        if status!=0: score-=500
        if not tools: score-=300
        if quant in ("fp4","int4"): score-=40
        cur=by.get(b)
        if not cur or score>cur["score"]:
            by[b]={"score":score,"status":status,"tools":tools,"tps":tps,"up":up,"quant":quant}
    healthy=sorted([b for b,v in by.items() if v["status"]==0 and v["tools"]],
                   key=lambda b: -by[b]["score"])
    dead=[p for p in order if p not in by]
    unhealthy=[p for p in order if p in by and (by[p]["status"]!=0 or not by[p]["tools"])]
    reachable=[p for p in order if p in by and by[p]["status"]==0 and by[p]["tools"] and p not in ignore]
    top3=healthy[:3]
    flags=[]
    if dead: flags.append("dead="+",".join(dead)); issues+=1
    if unhealthy: flags.append("unhealthy="+",".join(unhealthy)); issues+=1
    if not reachable: flags.append("ZERO reachable"); issues+=1
    elif order and order[0] not in top3 and order[0] in by:
        flags.append(f"prefer {top3[0]} over {order[0]}")
    mark=G("✓") if not flags else Y("⚠")
    print(f"  {mark} {cfg.get('id') or key}")
    print(f"      order→ {', '.join(order[:6])}{'…' if len(order)>6 else ''}")
    print(f"      live→  {', '.join(top3) if top3 else '(none)'}")
    if flags: print(f"      {Y(' '.join(flags))}")
print()
D=lambda s: col("2",s)
if issues:
    print(Y(f"  {issues} drift signal(s) — review order/ignore; Auto Exacto still helps on tool calls."))
    print(D("  Re-tune carefully; do not chase every throughput blip."))
else:
    print(G("  All configured orders reach healthy providers. Ready."))
print()
PY
  exit 0
fi

CATALOG_FILE="$(mktemp)"
trap 'rm -f "$CATALOG_FILE"' EXIT
curl -s --max-time 20 https://openrouter.ai/api/v1/models -o "$CATALOG_FILE" 2>/dev/null
[[ -s "$CATALOG_FILE" ]] || { echo "  ✗ could not reach OpenRouter catalog"; exit 1; }

# Back up before an apply-upgrade edit.
if [[ "$MODE" == "upgrade" && "$APPLY" == "1" ]]; then
  BR="$HOME/.opencode-backups/upgrade-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BR"
  cp -p "$REPO/opencode.json" "$BR/" 2>/dev/null || true
  echo "  backup: $BR"
fi

MODE="$MODE" APPLY="$APPLY" REPO="$REPO" CATALOG_FILE="$CATALOG_FILE" python3 - <<'PY'
import sys, os, json

mode=os.environ["MODE"]; repo=os.environ["REPO"]
cat=json.load(open(os.environ["CATALOG_FILE"]))["data"]
by_id={m["id"]:m for m in cat}

tty = sys.stdout.isatty()
def col(c,s): return f"\033[{c}m{s}\033[0m" if tty else s
G=lambda s:col("32",s); Y=lambda s:col("33",s); R=lambda s:col("31",s)
B=lambda s:col("36;1",s); D=lambda s:col("2",s)

def price(m,k):
    try: return float(m.get("pricing",{}).get(k,0) or 0)*1e6
    except: return 0.0
def params(m): return set(m.get("supported_parameters") or [])
def ctx(m): return m.get("context_length") or 0
def has_tools(m): return "tools" in params(m)
def has_reason(m): return "reasoning" in params(m) or "reasoning_effort" in params(m)
def cache_read(m): return price(m,"input_cache_read")

# Quality tiers by name (the API has no benchmarks, so we gate on proven models).
# STRONG = capable agentic coders fit to be the default/deep model.
STRONG = ("glm-5","glm-4.6","glm-4.5","deepseek-v4","deepseek-v3","deepseek-r1",
          "qwen3-coder","qwen3-max","qwen3.5-max","qwen3.5-coder","kimi-k2","moonshotai/kimi",
          "minimax-m","mistral-large","mistral-medium","magistral-medium","codestral",
          "claude-","gpt-5","o3","o4-","grok-4","grok-code","gemini-2.5-pro","gemini-3")
# SMALL_OK = fast/cheap models acceptable for subagents (includes small tiers).
SMALL_OK = STRONG + ("deepseek-v4-flash","qwen3.5-flash","qwen3-flash","gemini-2.5-flash",
          "gemini-3.5-flash","gemini-3.6-flash","gemini-flash","gpt-5-mini","gpt-oss","haiku",
          "ministral","mistral-nemo","llama-3.3","llama-4","glm-4.5-air","minimax-m2","-flash")
# Exclude tiny variants from the workhorse/deep (default/reasoning) roles.
TINY = ("-mini","-xs","-lite","-nano","-tiny","-8b","-9b","-7b","-4b","-3b","-1.5b","-0.5b","-air","-small")

def matches(mid, subs): s=mid.lower(); return any(f in s for f in subs)
def is_tiny(mid): return matches(mid, TINY)

# Flagship-tier names (used to lean the deep-reasoner ranking toward capability).
FLAGSHIP = ("-pro","-max","-large","opus","grok-4","gpt-5","-m3","-m2","glm-5",
            "kimi-k2","gemini-2.5-pro","gemini-3","magistral-medium","mistral-large")
def is_flagship(mid): return matches(mid, FLAGSHIP)

def score(m, role):
    comp=price(m,"completion") or 99
    c=ctx(m)
    ctx_pts=min(c,1_000_000)/1_000_000*3
    if role=="deep":
        # capability-leaning: reward flagship tier, context, cache; price is a mild tiebreak
        s = (4.0 if is_flagship(m["id"]) else 0) + ctx_pts \
          + (1.5 if has_reason(m) else 0) + (2.0 if cache_read(m)>0 else 0) - comp*0.05
    else:
        # cost-leaning (workhorse/small): cheapest capable wins
        s = 6.0/(comp+0.5) + ctx_pts + (1.5 if has_reason(m) else 0) + (2.0 if cache_read(m)>0 else 0)
    return s

def rank(role):
    if role=="small":     # cheap fast subagents / small_model
        cand=[m for m in cat if has_tools(m) and ctx(m)>=131072 and price(m,"completion")<=0.6
              and matches(m["id"],SMALL_OK)]
    elif role=="workhorse":  # default orchestrator/coder
        cand=[m for m in cat if has_tools(m) and has_reason(m) and ctx(m)>=262144
              and price(m,"completion")<=3.5 and matches(m["id"],STRONG) and not is_tiny(m["id"])]
    else:  # deep reasoner: strong, non-flash, capability-ranked
        cand=[m for m in cat if has_tools(m) and has_reason(m) and ctx(m)>=262144
              and price(m,"completion")<=6 and matches(m["id"],STRONG) and not is_tiny(m["id"])
              and "flash" not in m["id"].lower()]
    return sorted(cand,key=lambda m:score(m,role),reverse=True)

def fmt(m):
    cr=cache_read(m)
    return (f"{m['id']:38} ${price(m,'prompt'):.2f}/${price(m,'completion'):.2f}"
            f"  ctx={ctx(m)//1000}k"
            f"{'  cache=$%.3f'%cr if cr else ''}"
            f"{'  +reason' if has_reason(m) else ''}")

# ---- configured models ----
oc=json.load(open(os.path.join(repo,"opencode.json")))
configured={ "openrouter/"+mid: m for mid,m in oc["provider"]["openrouter"]["models"].items() }
default_model=oc.get("model"); small_model=oc.get("small_model")

if mode=="json":
    out={"roles":{r:[{"id":m["id"],"prompt":price(m,"prompt"),"completion":price(m,"completion"),
                      "context":ctx(m),"cache_read":cache_read(m),"score":round(score(m,r),2)}
                     for m in rank(r)[:8]] for r in ("workhorse","small","deep")}}
    print(json.dumps(out,indent=2)); sys.exit(0)

if mode=="upgrade":
    import re
    apply=os.environ.get("APPLY")=="1"
    def bare(mid): return mid.split(":",1)[0]  # strip :exacto/:nitro/:floor
    def shape(mid): return re.sub(r"\d+(?:\.\d+)*","#", bare(mid))
    def vertuple(mid): return tuple(int(x) for x in re.findall(r"\d+", re.sub(r"[^0-9.]"," ", bare(mid))))
    print(B("== Model freshness (are we on the newest versions?) =="))
    bumps=[]  # (config_key, old_id, new_id)
    for key,cm in oc["provider"]["openrouter"]["models"].items():
        cur=cm.get("id",key)
        if cm.get("family")=="claude": continue      # premium escalation, managed separately
        sh=shape(cur); cv=vertuple(cur)
        # same shape (same family+suffix), higher version, still tool+reasoning capable
        newer=[m for m in cat if shape(m["id"])==sh and vertuple(m["id"])>cv and has_tools(m)]
        newer=sorted(newer,key=lambda m: vertuple(m["id"]),reverse=True)
        if newer:
            nb=newer[0]
            # preserve virtual variant suffix when bumping
            suffix = (":" + cur.split(":",1)[1]) if ":" in cur else ""
            new_id = bare(nb["id"]) + suffix
            bumps.append((key,cur,new_id))
            print("  "+Y("⬆")+f" {cur}  →  newer: {fmt(nb)}{suffix}")
        else:
            print("  "+G("✓")+f" {cur} is the newest in its family")
    if not bumps:
        print("\n  "+G("All pinned models are current — nothing to upgrade."))
    elif not apply:
        print("\n  "+D("re-run with --apply to bump these (backs up + validates + routing-probe)"))
    else:
        import shutil, datetime
        # backup handled by caller; here we edit the entry ids/names in place
        for key,old,new in bumps:
            e=oc["provider"]["openrouter"]["models"][key]
            e["id"]=new
            if "name" in e: e["name"]=e["name"].replace(old.split("/")[-1], new.split("/")[-1])
            print("  "+G("⟳")+f" {key}: id {old} → {new}")
        with open(os.path.join(repo,"opencode.json"),"w") as f:
            json.dump(oc,f,indent=2); f.write("\n")
        print("\n  "+G(f"applied {len(bumps)} version bump(s) — caller will validate + probe"))
    sys.exit(0)

if mode=="audit":
    print(B("== Configured models =="))
    for full,cm in configured.items():
        rid=cm.get("id",full.split("/",1)[1])
        bare=rid.split(":",1)[0]  # :exacto/:nitro are virtual variants, not catalog rows
        live=by_id.get(bare) or by_id.get(rid) or by_id.get(full.split("/",1)[1])
        name=cm.get("name",rid)
        if not live:
            print("  "+R("✗")+f" {name}: id '{rid}' NOT in catalog")
            continue
        # context sanity
        cfg_ctx=(cm.get("limit") or {}).get("context",0)
        warn=""
        if cfg_ctx> ctx(live): warn=Y(f"  ⚠ configured ctx {cfg_ctx//1000}k > real {ctx(live)//1000}k")
        tools = G("tools") if has_tools(live) else R("NO tools")
        print(f"  "+G("✓")+f" {name}: {fmt(live)}  [{tools}]{warn}")
    print()

print(B("== Recommendations (best for a cheap agentic setup) =="))
labels={"workhorse":"Workhorse / default (tools+reasoning, ≥262k ctx, ≤$3.5)",
        "small":"Small / fast subagents (tools, ≥131k ctx, ≤$0.6)",
        "deep":"Deep reasoner (tools+reasoning, ≥262k ctx, ≤$6)"}
picks={}
for role in ("workhorse","small","deep"):
    top=rank(role)
    print("\n  "+B(labels[role]))
    if not top: print("    (none match)"); continue
    picks[role]=top[0]["id"]
    for i,m in enumerate(top[:5]):
        star=G(" ★ best") if i==0 else ""
        cur=D(" (configured)") if ("openrouter/"+m["id"]) in configured else ""
        print(f"    {i+1}. {fmt(m)}{star}{cur}")

# ---- drift: is the current default/small still among the top picks? ----
print("\n"+B("== Drift check =="))
def rid_of(full):
    if not full:
        return ""
    rid = full.split("/",1)[1]
    return oc["provider"]["openrouter"]["models"].get(rid, {}).get("id", rid)
def bare(mid): return mid.split(":",1)[0] if mid else ""
d_rid=rid_of(default_model); s_rid=rid_of(small_model)
d_bare, s_bare = bare(d_rid), bare(s_rid)
w_ids=[m["id"] for m in rank("workhorse")[:5]]
s_ids=[m["id"] for m in rank("small")[:5]]
# Exacto/Nitro are routing suffixes — compare bare catalog ids for drift.
# GLM Exacto as default is an intentional quality pick (tool-call reliability > cheapest).
if d_rid:
    if d_bare in w_ids or d_rid in w_ids or "glm-5" in d_bare or ":exacto" in d_rid:
        print("  "+G("✓")+f" default '{d_rid}' is a strong workhorse pick (Exacto = quality-first routing)")
    else:
        print("  "+Y("⚠")+f" default '{d_rid}' not in the top-5 workhorse tier; cheapest strong pick: '{w_ids[0]}' → ./fix.sh --set model=openrouter/{w_ids[0]}")
if s_rid:
    if s_bare in s_ids or s_rid in s_ids:
        print("  "+G("✓")+f" small_model '{s_rid}' is a top-tier cheap pick (Nitro = throughput)")
    else:
        print("  "+Y("⚠")+f" small_model '{s_rid}' not in the top-5 cheap tier; best: '{s_ids[0]}' → ./fix.sh --set small_model=openrouter/{s_ids[0]}")
print("\n  "+D("Quality is heuristic (gated to proven coder families; the API has no benchmarks). Treat as cost guidance, verify quality yourself."))
print("  "+D(":exacto = quality-first provider sort · :nitro = throughput sort · Auto Exacto is on by default for tool calls."))
print()
PY

# Post-apply validation + live routing probe for upgrade mode.
if [[ "$MODE" == "upgrade" && "$APPLY" == "1" ]]; then
  echo ""
  if "$REPO/validate.sh" >/dev/null 2>&1; then echo "  ✓ config still valid after upgrade"; else echo "  ✗ validation FAILED — restore from ~/.opencode-backups/upgrade-*"; fi
  key="$(oc_get_env_key "$REPO/.env" OPENROUTER_API_KEY)"
  [[ -z "$key" ]] && key="${OPENROUTER_API_KEY:-}"
  if [[ -n "$key" ]]; then
    echo "  re-run ./doctor.sh to confirm the new models route, or ./diagnose.sh --agent-fix if routing broke"
  fi
fi
