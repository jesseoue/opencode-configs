#!/usr/bin/env bash
# doctor.sh — Full OpenConfig readiness check.
# Covers CLI, config link, signature, plugin, LSP, formatters, keys, prompts,
# colors, models, MCP, permissions, concurrency/loops, teams, content-aware,
# terminal, telemetry, compaction, and external-source hardening.
#
# Usage: ./doctor.sh [--quick] [--fix] [--harden] [--ai-fix]
#   --quick   skip live model-routing probes (still checks OpenRouter key + latency)
#   --fix     run fix.sh (colors, footguns, skills lock) then re-check
#   --harden  remove opencode-owned external junk + disable external loading
#   --ai-fix  use OpenCode AI to diagnose and fix issues
#
# Related: oc check · oc validate · oc heal · oc diagnose

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
OC_BIN="$(command -v opencode 2>/dev/null || echo "$OC_CLI_BIN")"
LINK="${OC_CONFIG_LINK}"

DO_QUICK=0 DO_FIX=0 DO_HARDEN=0 DO_AI=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) DO_QUICK=1; shift ;;
    --fix) DO_FIX=1; shift ;;
    --harden) DO_HARDEN=1; shift ;;
    --ai-fix) DO_AI=1; shift ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $1 (try --quick --fix --harden --ai-fix)"; exit 2 ;;
  esac
done

# Colors: ok=green, info=dim cyan, tip=bold cyan, warn=yellow, bad=red
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"
  c_dim="\033[2m"; c_bold="\033[1m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_dim=""; c_bold=""; c_0=""
fi
crit=0; miss=0
sec(){ printf "\n${c_b}${c_bold}== %s ==${c_0}\n" "$*"; }
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
info(){ printf "  ${c_dim}•${c_0} %s\n" "$*"; }
tip(){ printf "  ${c_b}${c_bold}↳${c_0} ${c_dim}%s${c_0}\n" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; miss=$((miss+1)); }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; crit=$((crit+1)); }

_OC_VER="$(oc_versions_get opencode_configs 2>/dev/null || echo "?")"
printf "\n${c_b}${c_bold}OpenConfig doctor${c_0} ${c_dim}v%s · %s%s${c_0}\n" \
  "$_OC_VER" "$REPO" "$([[ $DO_QUICK -eq 1 ]] && echo ' · --quick' || true)"
unset _OC_VER

# ─── CLI ─────────────────────────────────────────────────────────────
sec "OpenCode CLI"
if [[ -x "$OC_BIN" ]]; then
  ver="$("$OC_BIN" --version 2>/dev/null | head -1)"
  ok "installed: $ver ($OC_BIN)"
else
  bad "opencode CLI not found"
  tip "full install: curl -fsSL https://opencode.ai/install | bash"
  tip "or: bash \"$REPO/install.sh\"   # installs CLI + this config stack"
fi

# ─── Config link ─────────────────────────────────────────────────────
sec "Config location (single source of truth)"
if [[ -L "$LINK" ]]; then
  tgt="$(readlink "$LINK")"
  [[ "$tgt" == "$REPO" ]] && ok "$LINK -> $REPO" || opt "$LINK -> $tgt (expected $REPO; run: ln -sfn \"$REPO\" \"$LINK\")"
elif [[ -e "$LINK" ]]; then
  opt "$LINK is a real dir, not a symlink to this repo (run: ln -sfn \"$REPO\" \"$LINK\")"
else
  bad "$LINK does not exist (run: ln -sfn \"$REPO\" \"$LINK\")"
fi
# Leftover copies (exclude ~/.opencode CLI install dir)
for d in "$HOME/.opencode" "$HOME/opencode-configs" /usr/local/opencode; do
  [[ "$d" == "$REPO" ]] && continue
  [[ ! -d "$d" ]] && continue
  if [[ "$d" == "$HOME/.opencode" ]] && oc_is_cli_install_dir "$d"; then
    continue
  fi
  opt "leftover config copy at $d (safe to remove after verifying backups in ~/.opencode-backups)"
done
# This repo must stay config-only — OpenCode may drop install artifacts when ~/.config/opencode → here
_strays=()
for s in "${OC_CONFIG_STRAYS[@]}"; do
  [[ -e "$REPO/$s" || -L "$REPO/$s" ]] && _strays+=("$s")
done
if [[ ${#_strays[@]} -gt 0 ]]; then
  opt "config dir has install/runtime strays: ${_strays[*]} — run ./cleanup.sh (repo is config-only)"
else
  ok "config dir is clean (no node_modules/package.json/.omo/.sisyphus/command)"
fi

# Project identity (OpenConfig — not a random clone)
if command -v oc_verify_signature >/dev/null 2>&1 || declare -F oc_verify_signature >/dev/null 2>&1; then
  _sig_out="$(oc_verify_signature "$REPO" 2>/dev/null || true)"
  if [[ "$_sig_out" == ok\|* ]]; then
    ok "signature: ${_sig_out#ok|} (OpenConfig identity)"
  else
    bad "signature: ${_sig_out#fail|}"
    tip "wrong project? clone OpenConfig (signature.json → github_b64) or run: oc signature --refresh"
    tip "intentional edit? oc signature --refresh"
  fi
  unset _sig_out
fi

# ─── Runtimes ────────────────────────────────────────────────────────
sec "Runtimes"
for c in node bun python3 git curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c ($("$c" --version 2>/dev/null | head -1 | tr -d '\n'))"; else
    [[ "$c" == "bun" ]] && opt "$c not found (needed for plugin doctor)" || bad "$c not found"
  fi
done

# ─── JSON validity (delegate) ────────────────────────────────────────
sec "Config validity"
if [[ -x "$REPO/validate.sh" ]]; then
  if VALIDATE_QUIET=1 "$REPO/validate.sh" >/dev/null 2>&1; then ok "all JSON valid, no footguns (see ./validate.sh for detail)"
  else bad "validation errors — run ./validate.sh"; fi
else opt "validate.sh missing"; fi

# ─── Plugin ──────────────────────────────────────────────────────────
sec "oh-my-openagent plugin"
pin="$(python3 -c "import json;p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my' in x];print(p[0] if p else '')" 2>/dev/null)"
if command -v bunx >/dev/null 2>&1; then
  dout="$(bunx "${pin:-oh-my-openagent@latest}" doctor 2>/dev/null)"
  if printf '%s' "$dout" | grep -q "System OK"; then
    ok "plugin doctor: $(printf '%s' "$dout" | grep -iE 'System OK' | head -1 | sed 's/^[^A-Za-z]*//')"
  elif printf '%s' "$dout" | grep -qi "outdated"; then
    info "plugin doctor: reports outdated — check npm view oh-my-openagent version vs pin $pin"
  else
    opt "plugin doctor: $(printf '%s' "$dout" | grep -iE 'issue' | head -1)"
  fi
else opt "bun missing — cannot verify plugin version"; fi
# The pin must resolve to a NON-EMPTY cache, else the plugin silently loads no agents.
cdir="$HOME/.cache/opencode/packages/$pin"
if [[ -n "$pin" ]]; then
  if [[ -d "$cdir" && -n "$(ls -A "$cdir" 2>/dev/null)" ]]; then ok "plugin cache populated ($pin)"
  elif [[ -d "$cdir" ]]; then bad "plugin cache EMPTY for $pin — install failed; agents will NOT load (check the pin exists on npm)"
  else info "plugin cache not built yet for $pin (populated on first launch)"; fi
fi

# ─── default_agent will resolve (static: defined in config + cache populated) ──
# Note: `opencode agent list` registers plugin agents lazily/async and is racy,
# so we check deterministically — the agent must be DEFINED and the plugin that
# provides it must be installed (cache non-empty, checked above).
sec "Default agent"
default_agent="$(python3 -c "import json;print(json.load(open('$REPO/opencode.json')).get('default_agent',''))" 2>/dev/null)"
if [[ -z "$default_agent" ]]; then
  info "no default_agent set (opencode uses 'build')"
else
  defined="$(python3 -c "
import json
omo=json.load(open('$REPO/oh-my-openagent.json'))
native={'build','plan','general','atlas','sisyphus','hephaestus','prometheus'}
print('yes' if ('$default_agent' in (omo.get('agents') or {}) or '$default_agent' in native) else 'no')
" 2>/dev/null)"
  cache_ok=0
  cdir="$HOME/.cache/opencode/packages/$pin"
  [[ -n "$pin" && -d "$cdir" && -n "$(ls -A "$cdir" 2>/dev/null)" ]] && cache_ok=1
  if [[ "$defined" == "yes" && "$cache_ok" -eq 1 ]]; then
    ok "default_agent '$default_agent' is defined and its plugin is installed → will resolve"
  elif [[ "$defined" != "yes" ]]; then
    bad "default_agent '$default_agent' is not defined in oh-my-openagent.json — opencode will fall back to 'build'"
  else
    bad "default_agent '$default_agent' defined but plugin cache empty — it will NOT load until the plugin installs"
  fi
fi

# ─── LSP servers (derived from opencode.json) ────────────────────────
sec "LSP servers (code intelligence)"
_lsp_miss=0
while IFS='|' read -r name cmd; do
  if [[ "$name" == META ]]; then
    info "$cmd"
    continue
  fi
  [[ -z "$cmd" ]] && continue
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ${c_g}✓${c_0} %s: %s\n" "$name" "$cmd"
  else
    printf "  ${c_y}⚠${c_0} %s: %s NOT installed (LSP tools disabled for this language)\n" "$name" "$cmd"
    _lsp_miss=$((_lsp_miss+1))
    case "$name" in
      typescript) tip "install: npm i -g typescript-language-server typescript" ;;
      python) tip "install: pipx install basedpyright   # or: pip install basedpyright" ;;
      go) tip "install: go install golang.org/x/tools/gopls@latest" ;;
      *) tip "install '$cmd' and ensure it is on PATH" ;;
    esac
  fi
done < <(python3 -c "
import json
lsp=json.load(open('$REPO/opencode.json')).get('lsp',{})
enabled=[(k,(v.get('command') or [''])[0]) for k,v in lsp.items() if isinstance(v,dict) and not v.get('disabled')]
disabled=sum(1 for v in lsp.values() if isinstance(v,dict) and v.get('disabled'))
print(f'META|{len(enabled)} enabled, {disabled} builtins disabled')
for k,cmd in enabled:
    print(f'{k}|{cmd}')
" 2>/dev/null)
miss=$((miss+_lsp_miss))

# ─── CodeGraph ───────────────────────────────────────────────────────
sec "CodeGraph (OmO)"
CG_BIN="$HOME/.omo/codegraph/bin/codegraph"
if [[ -x "$CG_BIN" ]]; then
  ok "binary: $CG_BIN ($($CG_BIN --version 2>/dev/null | head -1 | tr -d '\r'))"
else
  opt "binary missing — first OmO session should auto_provision to ~/.omo/codegraph"
  tip "or run: oc setup   # provisions codegraph + teams + LSP"
fi
cg_line="$(python3 -c "
import json
cg=json.load(open('$REPO/oh-my-openagent.json')).get('codegraph') or {}
id=cg.get('install_dir')
if cg.get('enabled') is False:
    print('BAD enabled=false')
elif id and 'cache/opencode/codegraph' in str(id):
    print('BAD install_dir='+str(id))
else:
    print('enabled=%s auto_init=%s auto_provision=%s telemetry=%s' % (
        cg.get('enabled', True), cg.get('auto_init', True),
        cg.get('auto_provision', True), cg.get('telemetry')))
" 2>/dev/null)"
if [[ "$cg_line" == BAD* ]]; then bad "codegraph config: $cg_line"
else ok "config: $cg_line"; fi

# ─── Formatters ──────────────────────────────────────────────────────
sec "Formatters"
_fmt_miss=0
while read -r name cmd; do
  [[ -z "$cmd" ]] && continue
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ${c_g}✓${c_0} %s: %s\n" "$name" "$cmd"
  else
    printf "  ${c_y}⚠${c_0} %s: %s not on PATH (auto-format skipped)\n" "$name" "$cmd"
    _fmt_miss=$((_fmt_miss+1))
    case "$name" in
      prettier) tip "install: npm i -g prettier" ;;
      ruff) tip "install: brew install ruff   # or: pipx install ruff" ;;
      *) tip "install '$cmd' and ensure it is on PATH" ;;
    esac
  fi
done < <(python3 -c "import json;[print(k,(v.get('command') or [''])[0]) for k,v in json.load(open('$REPO/opencode.json')).get('formatter',{}).items() if not v.get('disabled')]" 2>/dev/null)
miss=$((miss+_fmt_miss))

# ─── API keys ────────────────────────────────────────────────────────
sec "API keys (.env)"
ENV_FILE="$REPO/.env"
getkey(){ oc_get_env_key "${ENV_FILE:-$REPO/.env}" "$1"; }
if [[ -f "$ENV_FILE" ]]; then
  for k in OPENROUTER_API_KEY; do
    if [[ -n "$(getkey $k)" ]]; then ok "$k set"
    else
      bad "$k MISSING — required to run any model"
      tip "get a key: https://openrouter.ai/keys"
      tip "then: edit $ENV_FILE  (or: bash \"$REPO/install.sh\")"
    fi
  done
  for k in OPENAI_API_KEY CONTEXT7_API_KEY EXA_API_KEY; do
    if [[ -n "$(getkey $k)" ]]; then ok "$k set"
    else
      case "$k" in
        OPENAI_API_KEY)
          opt "$k unset (GPT lane falls back to OpenRouter)"
          tip "https://platform.openai.com/api-keys → add OPENAI_API_KEY=… to $ENV_FILE"
          ;;
        CONTEXT7_API_KEY)
          opt "$k unset (Context7 docs MCP unauthenticated)"
          tip "https://context7.com/dashboard → add CONTEXT7_API_KEY=… to $ENV_FILE"
          ;;
        EXA_API_KEY)
          opt "$k unset (Exa web search unavailable)"
          tip "https://exa.ai → add EXA_API_KEY=… to $ENV_FILE"
          ;;
      esac
    fi
  done
  # Foreign (non-allowlisted) keys — never print names/values; count only.
  # Company vault dumps in this tree are a leak risk for a public config repo.
  _foreign="$(oc_env_foreign_key_count "$ENV_FILE" 2>/dev/null || echo 0)"
  if [[ "${_foreign:-0}" -gt 0 ]]; then
    opt ".env has $_foreign non-allowlisted key(s) (company secrets don't belong here)"
    tip "scrub: oc env --scrub   · full backup stays under ~/.opencode-backups/"
  else
    ok ".env allowlist-clean (OpenConfig keys only)"
  fi
  # Live OpenRouter key check + latency (healthy is typically ~100–300ms)
  ork="$(getkey OPENROUTER_API_KEY)"
  if [[ -n "$ork" ]] && command -v curl >/dev/null; then
    _or_out="$(curl -s -o /tmp/oc-doctor-or-key.json -w '%{http_code} %{time_total}' \
      -H "Authorization: Bearer $ork" https://openrouter.ai/api/v1/key 2>/dev/null || echo "000 0")"
    code="${_or_out%% *}"
    secs="${_or_out##* }"
    ms="$(python3 -c "print(int(round(float('$secs')*1000)))" 2>/dev/null || echo "?")"
    if [[ "$code" == "200" ]]; then
      if [[ "$ms" != "?" && "$ms" -le 200 ]]; then
        ok "OpenRouter key live (HTTP 200, ${ms}ms)"
      elif [[ "$ms" != "?" && "$ms" -le 800 ]]; then
        ok "OpenRouter key live (HTTP 200, ${ms}ms)"
        info "latency >200ms — usually fine; check network if this stays high"
      else
        opt "OpenRouter key live but slow (HTTP 200, ${ms}ms) — expected ~200ms"
      fi
    else
      opt "OpenRouter key check returned HTTP $code (${ms}ms)"
      tip "verify key at https://openrouter.ai/keys and credits via: oc admin credits"
    fi
  fi
  # Direct OpenAI key ping (cheap)
  oai="$(getkey OPENAI_API_KEY)"
  if [[ -n "$oai" ]] && command -v curl >/dev/null; then
    _oa_out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
      -H "Authorization: Bearer $oai" https://api.openai.com/v1/models 2>/dev/null || echo "000 0")"
    oacode="${_oa_out%% *}"
    oasecs="${_oa_out##* }"
    oams="$(python3 -c "print(int(round(float('$oasecs')*1000)))" 2>/dev/null || echo "?")"
    if [[ "$oacode" == "200" ]]; then
      ok "OpenAI key live (HTTP 200, ${oams}ms)"
    else
      opt "OpenAI key check returned HTTP $oacode (${oams}ms)"
      tip "https://platform.openai.com/api-keys — GPT lane needs a valid direct key"
    fi
  fi
else
  bad ".env missing — copy .env.example and add OPENROUTER_API_KEY"
  tip "cp \"$REPO/.env.example\" \"$REPO/.env\" && chmod 600 \"$REPO/.env\""
  tip "or full stack: bash \"$REPO/install.sh\""
fi

# ─── Projects directory ──────────────────────────────────────────────
sec "Projects directory"
_pd="$(oc_projects_dir 2>/dev/null || true)"
if [[ -n "$_pd" ]]; then
  if [[ -d "$_pd" ]]; then
    ok "projects home: $_pd"
  else
    opt "projects home missing: $_pd"
    tip "create: oc projects --ensure   # or: mkdir -p \"$_pd\""
  fi
  info "default profile: $(oc_default_profile 2>/dev/null || echo high)  ·  scaffold: oc new <name>"
else
  opt "could not resolve projects dir"
fi

# ─── Prompts ─────────────────────────────────────────────────────────
sec "Prompts"
prompt_report="$(python3 - "$REPO" <<'PY'
import json, os, sys
repo = sys.argv[1]
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))

def resolve_file_uri(uri: str):
    if not isinstance(uri, str):
        return None
    u = uri.strip()
    if u.startswith("file://"):
        u = u[7:]
    if u.startswith("~/"):
        u = os.path.join(os.path.expanduser("~"), u[2:])
    elif not os.path.isabs(u):
        u = os.path.join(repo, u)
    return u

missing = []
empty = []
checked = 0
for section in ("agents", "categories"):
    for name, cfg in (omo.get(section) or {}).items():
        if not isinstance(cfg, dict):
            continue
        pa = (cfg.get("prompt_append") or cfg.get("prompt") or "").strip()
        if not pa:
            empty.append(f"{section}.{name}")
            continue
        checked += 1
        if pa.startswith("file://") or pa.endswith(".md"):
            path = resolve_file_uri(pa)
            alt = os.path.join(repo, "prompts", section, f"{name}.md")
            if path and not os.path.isfile(path) and not os.path.isfile(alt):
                missing.append(f"{section}.{name} -> {pa}")

for pj in sorted(os.listdir(os.path.join(repo, "profiles"))):
    if not pj.endswith(".json"):
        continue
    name = pj[:-5]
    pmd = os.path.join(repo, "prompts", "profiles", f"{name}.md")
    checked += 1
    if not os.path.isfile(pmd):
        missing.append(f"profiles/{name} -> prompts/profiles/{name}.md")

core = os.path.join(repo, "prompts", "core.md")
print(("OK" if os.path.isfile(core) else "BAD") + "|prompts/core.md " + ("present" if os.path.isfile(core) else "missing"))
agents_md = os.path.join(repo, "AGENTS.md")
print(("OK" if os.path.isfile(agents_md) else "BAD") + "|AGENTS.md " + ("present" if os.path.isfile(agents_md) else "missing"))
if empty:
    print("BAD|empty prompt_append: " + ", ".join(empty))
if missing:
    shown = ", ".join(missing[:8]) + ("…" if len(missing) > 8 else "")
    print("BAD|missing prompt files: " + shown)
if not empty and not missing:
    print(f"OK|{checked} prompt refs resolve (agents/categories/profiles)")
PY
)"
while IFS='|' read -r st msg; do
  [[ -z "$msg" ]] && continue
  case "$st" in
    OK) ok "$msg" ;;
    BAD) bad "$msg"; tip "restore from repo or run: oc fix / oc cleanup --yes" ;;
  esac
done <<< "$prompt_report"

# ─── Agent / category colors ─────────────────────────────────────────
sec "Agent & category colors"
color_report="$(python3 - "$REPO" <<'PY'
import json, os, sys, re
repo = sys.argv[1]
hexre = re.compile(r"^#[0-9A-Fa-f]{6}$")
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
miss_a, bad_a, ok_a = [], [], 0
for n, a in (omo.get("agents") or {}).items():
    c = (a or {}).get("color")
    if c is None:
        miss_a.append(n)
    elif not hexre.match(str(c)):
        bad_a.append(f"{n}={c}")
    else:
        ok_a += 1
miss_c, bad_c, ok_c = [], [], 0
for n, a in (omo.get("categories") or {}).items():
    if not isinstance(a, dict):
        continue
    c = a.get("color")
    if c is None:
        miss_c.append(n)
    elif not hexre.match(str(c)):
        bad_c.append(f"{n}={c}")
    else:
        ok_c += 1
if bad_a or bad_c:
    print("BAD|non-hex colors: " + ", ".join(bad_a + bad_c))
if miss_a or miss_c:
    ma = ",".join(miss_a) if miss_a else "—"
    mc = ",".join(miss_c[:6]) + ("…" if len(miss_c) > 6 else "") if miss_c else "—"
    print(f"OPT|missing colors (TUI tabs dull): agents={ma} categories={mc}")
    print("TIP|restore: oc fix   # assigns Tokyonight hex colors")
if ok_a or ok_c:
    print(f"OK|{ok_a} agents + {ok_c} categories have valid #RRGGBB colors")
if not (miss_a or miss_c or bad_a or bad_c):
    print("OK|all agent/category colors set")
PY
)"
while IFS='|' read -r st msg; do
  [[ -z "$msg" ]] && continue
  case "$st" in
    OK) ok "$msg" ;;
    OPT) opt "$msg" ;;
    BAD) bad "$msg" ;;
    TIP) tip "$msg" ;;
  esac
done <<< "$color_report"

# ─── Model routing (live probe: would catch "all providers ignored") ──
# Sends a 1-token request per model with its EXACT configured provider block.
# Catches over-tight max_price / ignore combos that route to zero providers.
sec "Model routing (live)"
if [[ $DO_QUICK -eq 1 ]]; then
  info "skipped (--quick) — run: oc doctor   or   oc admin health"
elif [[ -f "$ENV_FILE" ]] && [[ -n "$(getkey OPENROUTER_API_KEY)" ]] && command -v curl >/dev/null; then
  probe="$(ORK="$(getkey OPENROUTER_API_KEY)" python3 - "$REPO" <<'PY'
import json, os, sys, time, urllib.request, urllib.error
repo=sys.argv[1]; key=os.environ["ORK"]
models=json.load(open(os.path.join(repo,"opencode.json")))["provider"]["openrouter"]["models"]
for mid,m in models.items():
    if m.get("family")=="claude": continue  # premium escalation-only; skip to save cost
    body={"model":m.get("id",mid),"messages":[{"role":"user","content":"hi"}],"max_tokens":16}
    prov=(m.get("options") or {}).get("provider")
    if prov: body["provider"]=prov
    rq=urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    t0=time.time()
    try:
        d=json.load(urllib.request.urlopen(rq,timeout=20))
        ms=int(round((time.time()-t0)*1000))
        print(f"OK|{mid}|{d.get('provider','?')} {ms}ms")
    except urllib.error.HTTPError as e:
        try: msg=json.load(e).get("error",{}).get("message","")[:70]
        except Exception: msg=f"HTTP {e.code}"
        print(f"ERR|{mid}|{msg}")
    except Exception as e:
        print(f"ERR|{mid}|{str(e)[:60]}")
PY
)"
  while IFS='|' read -r st mid msg; do
    [[ -z "$mid" ]] && continue
    if [[ "$st" == OK ]]; then ok "$mid routes ($msg)"; else bad "$mid → $msg"; fi
  done <<< "$probe"
else
  opt "skipped (no OPENROUTER_API_KEY)"
  tip "add OPENROUTER_API_KEY to $REPO/.env then re-run: oc doctor"
fi

# ─── MCP ─────────────────────────────────────────────────────────────
sec "MCP servers"
python3 -c "
import json
m=json.load(open('$REPO/opencode.json')).get('mcp',{})
for n,c in m.items(): print(n, c.get('enabled',True), c.get('url') or (c.get('command') or [''])[0])
" 2>/dev/null | while read -r n en url; do
  [[ "$en" == "True" ]] && printf "  ${c_g}✓${c_0} %s enabled (%s)\n" "$n" "$url" || printf "  ${c_y}⚠${c_0} %s disabled\n" "$n"
done

# ─── Reference workspaces ────────────────────────────────────────────
sec "Reference workspaces"
_ref_lines="$(python3 -c "import json;d=json.load(open('$REPO/opencode.json')).get('references') or {};
[print(k,v.get('path','')) for k,v in d.items()]" 2>/dev/null || true)"
if [[ -z "$_ref_lines" ]]; then
  info "none configured (optional)"
else
  while read -r name path; do
    [[ -z "$name" ]] && continue
    ep="${path/#\~/$HOME}"
    if [[ -d "$ep" ]]; then ok "$name: $path"
    else opt "$name: $path (path not found)"; fi
  done <<< "$_ref_lines"
fi

# ─── Skills paths ────────────────────────────────────────────────────
sec "Skills sources"
_sk_lines="$(python3 -c "
import json
paths=set(json.load(open('$REPO/opencode.json')).get('skills',{}).get('paths',[]) or [])
for s in json.load(open('$REPO/oh-my-openagent.json')).get('skills',{}).get('sources',[]) or []:
    if isinstance(s, dict) and s.get('path'): paths.add(s['path'])
    elif isinstance(s, str): paths.add(s)
print(chr(10).join(sorted(paths)))
" 2>/dev/null || true)"
if [[ -z "$_sk_lines" ]]; then
  ok "skills fence active (./skills) — no external sources"
else
  while read -r p; do
    [[ -z "$p" ]] && continue
    ep="${p/#\~/$HOME}"
    if [[ -d "$ep" ]]; then ok "$p"
    else
      opt "$p (not present)"
      tip "mkdir -p \"$ep\"  # or lock to ./skills via: oc fix"
    fi
  done <<< "$_sk_lines"
fi

# ─── Permissions audit ───────────────────────────────────────────────
sec "Permissions"
perm_report="$(python3 - "$REPO" <<'PY'
import json, sys
oc=json.load(open(sys.argv[1]+"/opencode.json"))
p=oc.get("permission",{})
bash=p.get("bash",{}) if isinstance(p.get("bash"),dict) else {}
def denied(pat): return bash.get(pat)=="deny"
# This setup runs allow-everything (no prompts) on a trusted local box.
# We only insist the irreversible MACHINE-destroying commands stay denied.
must_deny=["rm -rf /","rm -rf ~","mkfs*","sudo *","git push --force*","gh repo delete*"]
for pat in must_deny:
    print(("OK" if denied(pat) else "BAD")+f"|'{pat}' denied (catastrophic-action guard)")
ndeny=sum(1 for v in bash.values() if v=="deny")
star=bash.get("*")
print((("OK" if star=="allow" else "WARN"))+f"|bash default '*' = {star}  ({ndeny} catastrophic denies kept)")
print("OK|allow-everything mode: no interactive permission prompts (by design)")
ed=p.get("external_directory")
if isinstance(ed,dict): print(f"OK|external_directory scoped ({len(ed)} rules)")
else: print(f"OK|external_directory = {ed} (allow-everything)")
print((("OK" if "edit" in p else "WARN"))+"|edit permission set (covers edit/write/patch)")
PY
)"
while IFS='|' read -r st msg; do
  [[ -z "$msg" ]] && continue
  case "$st" in
    OK) ok "$msg" ;;
    WARN) opt "$msg" ;;
    BAD) bad "$msg" ;;
  esac
done <<< "$perm_report"

# ─── Runtime log health (recent errors from real sessions) ──────────
# Informational only — does not affect the ready/not-ready verdict.
sec "Runtime log health"
LOG="${XDG_DATA_HOME}/opencode/log/opencode.log"
if [[ -f "$LOG" ]]; then
  tailn="$(tail -n 20000 "$LOG" 2>/dev/null)"
  errc="$(printf '%s\n' "$tailn" | grep -c 'level=ERROR' 2>/dev/null || true)"
  if [[ "${errc:-0}" -eq 0 ]]; then
    ok "no ERROR lines in the last 20k log lines"
  else
    info "$errc ERROR line(s) in last 20k lines of $LOG — top signatures:"
    printf '%s\n' "$tailn" | grep 'level=ERROR' \
      | sed -E 's/.*message=//; s/^"([^"]*)".*/\1/; s/ (ref|error|cause|sessionID|session\.id|messageID|stack|small|agent|providerID|modelID)=.*$//; s/ses_[A-Za-z0-9]+/ses_…/g; s/[0-9]+/N/g' \
      | sort | uniq -c | sort -rn | head -3 \
      | while read -r n rest; do printf "      %6dx %s\n" "$n" "$(printf '%s' "$rest" | cut -c1-88)"; done
    # Known runaway: an agent passed a descriptive LABEL as task_id instead of a ses_ id.
    loop="$(printf '%s\n' "$tailn" | grep -c 'Expected a string starting with .ses' 2>/dev/null || true)"
    if [[ "${loop:-0}" -gt 0 ]]; then
      info "invented-task_id loop seen ($loop hits) — an agent used a label as task_id, not a ses_ id."
      tip "Sisyphus RECOVERY forbids inventing task_id; if it recurs, harden the offending worker prompt"
    fi
    fmt_hits="$(printf '%s\n' "$tailn" | grep -c 'failed to format file' 2>/dev/null || true)"
    if [[ "${fmt_hits:-0}" -gt 5 ]]; then
      tip "formatter noise (${fmt_hits} hits) — ensure prettier/ruff on PATH (Formatters section) or disable unused formatters"
    fi
  fi
else
  info "no opencode log yet ($LOG)"
fi

# ─── Team mode ───────────────────────────────────────────────────────
# Parallel multi-agent coordination. Optional: a warn here never blocks the
# ready verdict, it just means team_* tools have nothing to spawn yet.
sec "Team mode"
tm_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo = sys.argv[1]
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
tm = omo.get("team_mode") or {}
if not tm.get("enabled"):
    print("OPT|team_mode disabled — set team_mode.enabled=true to use team_* tools"); sys.exit()
print("OK|enabled (%d parallel / %d max)" % (tm.get("max_parallel_members", 4), tm.get("max_members", 8)))
# team_* + core tools permissioned in opencode.json
REQUIRED_TEAM = (
    "team_create", "team_delete", "team_list", "team_status", "team_send_message",
    "team_shutdown_request", "team_approve_shutdown", "team_reject_shutdown",
    "team_task_create", "team_task_get", "team_task_list", "team_task_update",
)
try:
    oc = json.load(open(os.path.join(repo, "opencode.json")))
    perms = (oc.get("permission") or {})
    missing = [t for t in REQUIRED_TEAM if perms.get(t) != "allow"]
    if not missing: print("OK|%d team_* tools allowed" % len(REQUIRED_TEAM))
    else: print("BAD|team_* not allow: %s — run: oc fix" % ", ".join(missing))
    for t in ("task", "call_omo_agent", "edit", "external_directory", "doom_loop"):
        if perms.get(t) != "allow":
            print("BAD|permission.%s must be allow (got %r) — run: oc fix" % (t, perms.get(t)))
        else:
            print("OK|%s = allow" % t)
except Exception as e:
    print("BAD|could not read opencode.json permissions (%s)" % e)
# eligible agents present
agents = omo.get("agents") or {}
eligible = [a for a in ("sisyphus", "atlas", "sisyphus-junior", "hephaestus") if a in agents]
print("OK|eligible agents: %s" % ", ".join(eligible) if eligible else "OPT|no eligible team agents defined")
heph = agents.get("hephaestus") or {}
if heph and (heph.get("permission") or {}).get("teammate") != "allow":
    print("BAD|hephaestus lacks permission.teammate=allow — cannot be a team member — run: oc fix")
else:
    print("OK|hephaestus.permission.teammate = allow")
# declared specs
base = (tm.get("base_dir") or "~/.omo").replace("~", os.path.expanduser("~"))
tracked = []
tdir = os.path.join(repo, "teams")
if os.path.isdir(tdir):
    tracked = [d for d in os.listdir(tdir) if os.path.isfile(os.path.join(tdir, d, "config.json"))]
live = []
ldir = os.path.join(base, "teams")
if os.path.isdir(ldir):
    live = [d for d in os.listdir(ldir) if os.path.isfile(os.path.join(ldir, d, "config.json"))]
if tracked: print("OK|%d team spec(s) tracked in repo/teams: %s" % (len(tracked), ", ".join(sorted(tracked))))
else: print("OPT|no team specs in repo/teams — nothing for team_create to spawn")
missing = [t for t in tracked if t not in live]
if missing: print("OPT|tracked but not provisioned to %s/teams: %s — symlink them: ln -sfn $REPO/teams/{name} %s/teams/{name}" % (base, ", ".join(sorted(missing)), base))
elif tracked: print("OK|specs provisioned to %s/teams" % base)

# hyperplan readiness (inline team — no repo team spec; uses category members + plan handoff)
kd = (omo.get("keyword_detector") or {}).get("enabled_expansions") or []
if "hyperplan" in kd:
    disabled = {str(a).lower() for a in (omo.get("disabled_agents") or [])}
    cats = omo.get("categories") or {}
    sa = omo.get("sisyphus_agent") or {}
    req = ["unspecified-low", "unspecified-high", "ultrabrain", "artistry"]
    missing_cats = [c for c in req if c not in cats]
    if missing_cats:
        print("FAIL|hyperplan missing categories: %s" % ", ".join(missing_cats))
    else:
        print("OK|hyperplan categories present%s" % (" (+deep)" if "deep" in cats else " (no deep)"))
    if "plan" in disabled:
        print("FAIL|plan is in disabled_agents — hyperplan Phase 6 handoff will fail")
    elif sa.get("replace_plan") is not False and sa.get("planner_enabled") is not False:
        print("OK|plan demoted for hyperplan handoff (replace_plan + not disabled)")
    else:
        print("OPT|plan callable but replace_plan/planner_enabled off — check sisyphus_agent")
    if "hyperplan-ultrawork" in kd:
        print("OK|hyperplan-ultrawork combo expansion enabled")
    print("OK|trigger: say hyperplan / hpp, or /hyperplan (from sisyphus, not prometheus)")
else:
    print("OPT|hyperplan keyword expansion not enabled")
PY
)"
if [[ -z "$tm_report" ]]; then
  info "could not evaluate team-mode config (python3?)"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OK) ok "$msg" ;; OPT) opt "$msg" ;; FAIL|BAD) bad "$msg" ;; *) info "$msg" ;; esac
  done <<< "$tm_report"
fi

# ─── Concurrency, loops, content-aware ───────────────────────────
sec "Concurrency & loops"
conc_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo = sys.argv[1]
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
bt = omo.get("background_task") or {}
pc = bt.get("providerConcurrency") or {}
mc = bt.get("modelConcurrency") or {}
tm = omo.get("team_mode") or {}
rl = omo.get("ralph_loop") or {}
goal = omo.get("goal") or {}
exp = omo.get("experimental") or {}

def bad(m): print("BAD|" + m)
def ok(m): print("OK|" + m)
def opt(m): print("OPT|" + m)

dc = bt.get("defaultConcurrency")
if not isinstance(dc, int) or dc < 1:
    bad("background_task.defaultConcurrency missing/invalid")
elif dc > 4:
    bad("defaultConcurrency=%s (>4) — runaway risk; run: oc fix" % dc)
else:
    ok("defaultConcurrency=%s" % dc)

for prov, cap in (("openrouter", 6), ("openai", 4), ("anthropic", 2)):
    v = pc.get(prov)
    if not isinstance(v, int):
        bad("providerConcurrency.%s missing" % prov)
    elif v > cap:
        bad("providerConcurrency.%s=%s (cap %s) — run: oc fix" % (prov, v, cap))
    else:
        ok("providerConcurrency.%s=%s" % (prov, v))

# Every referenced model should have a modelConcurrency entry
ids = set()
for section in ("agents", "categories"):
    for cfg in (omo.get(section) or {}).values():
        if isinstance(cfg, dict) and isinstance(cfg.get("model"), str):
            ids.add(cfg["model"])
        if isinstance(cfg, dict):
            for fb in cfg.get("fallback_models") or cfg.get("fallbacks") or []:
                if isinstance(fb, str): ids.add(fb)
                elif isinstance(fb, dict) and isinstance(fb.get("model"), str): ids.add(fb["model"])
missing_mc = sorted(i for i in ids if i not in mc)
orphan_mc = sorted(k for k in mc if k not in ids)
if missing_mc:
    shown = ", ".join(missing_mc[:6]) + ("…" if len(missing_mc) > 6 else "")
    opt("modelConcurrency missing for: %s" % shown)
else:
    ok("modelConcurrency covers %d referenced models" % len(ids))
if orphan_mc:
    shown = ", ".join(orphan_mc[:4]) + ("…" if len(orphan_mc) > 4 else "")
    opt("modelConcurrency orphans (unused): %s" % shown)

mp = tm.get("max_parallel_members")
mm = tm.get("max_members")
if not isinstance(mp, int) or mp < 1 or mp > 4:
    bad("team_mode.max_parallel_members=%s (want 1–4)" % mp)
else:
    ok("team parallel=%s / members=%s" % (mp, mm if isinstance(mm, int) else "?"))
if isinstance(mm, int) and mm < 5:
    bad("team_mode.max_members=%s (<5 hyperplan floor)" % mm)

rmi = rl.get("default_max_iterations")
if rl.get("enabled") is True:
    if not isinstance(rmi, int) or rmi > 8:
        bad("ralph_loop.default_max_iterations=%s (cap 8)" % rmi)
    else:
        ok("ralph_loop enabled (max %s)" % rmi)
else:
    opt("ralph_loop disabled")

if goal.get("enabled") is True:
    gmi = goal.get("default_max_iterations", 24)
    auto = goal.get("auto_start")
    ok("goal enabled (max %s, auto_start=%s)" % (gmi, auto))
    tip("OmO /goal objective hard-cap is 2000 chars — keep ≤1800; never paste .omo/plans/*.md (prompts/goal.md)")
    if auto is True:
        opt("goal.auto_start=true — prefer false so /goal is explicit")
else:
    opt("goal disabled")

mt = exp.get("max_tools")
if isinstance(mt, int) and mt <= 48:
    ok("experimental.max_tools=%s" % mt)
elif isinstance(mt, int):
    opt("experimental.max_tools=%s (high; 48 is the OpenConfig default)" % mt)

# MCP / stream timeouts (opencode.json)
oc = json.load(open(os.path.join(repo, "opencode.json")))
mcp_t = (oc.get("experimental") or {}).get("mcp_timeout")
if isinstance(mcp_t, (int, float)) and mcp_t >= 12000:
    ok("experimental.mcp_timeout=%sms" % int(mcp_t))
else:
    opt("experimental.mcp_timeout unset/low (want ≥12000)")
for pname in ("openrouter", "openai"):
    opts = ((oc.get("provider") or {}).get(pname) or {}).get("options") or {}
    to = opts.get("timeout")
    if isinstance(to, (int, float)) and to >= 600000:
        ok("provider.%s timeout=%ss" % (pname, int(to / 1000)))
    elif to is not None:
        opt("provider.%s timeout=%s (want ≥600s for long streams)" % (pname, to))
PY
)"
if [[ -z "$conc_report" ]]; then
  opt "could not evaluate concurrency config"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OK) ok "$msg" ;; OPT) opt "$msg" ;; BAD|FAIL) bad "$msg"; tip "oc fix   # re-applies concurrency ceilings" ;; *) info "$msg" ;; esac
  done <<< "$conc_report"
fi

sec "Content-aware research"
ca_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys, re
repo = sys.argv[1]
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
agents = omo.get("agents") or {}
cats = omo.get("categories") or {}
ca = agents.get("content-aware-research")
if not isinstance(ca, dict):
    print("BAD|agents.content-aware-research missing")
else:
    print("OK|agent content-aware-research defined")
    if (ca.get("permission") or {}).get("edit") != "deny":
        print("BAD|content-aware-research.permission.edit must be deny")
    else:
        print("OK|OmO agent edit=deny")
md = os.path.join(repo, "agents", "content-aware-research.md")
if not os.path.isfile(md):
    print("BAD|agents/content-aware-research.md missing")
else:
    text = open(md).read()
    if re.search(r"(?m)^\s*edit:\s*deny\s*$", text) or "edit: deny" in text:
        print("OK|OpenCode-native agent MD (edit deny)")
    else:
        print("BAD|agents/content-aware-research.md must set edit: deny")
for name in ("content-aware-fast", "content-aware-deep"):
    if name in cats:
        print("OK|category %s" % name)
    else:
        print("BAD|category %s missing" % name)
prof = os.path.join(repo, "profiles", "content-aware.json")
if not os.path.isfile(prof):
    print("BAD|profiles/content-aware.json missing")
else:
    gp = json.load(open(prof))
    if gp.get("default_agent") != "content-aware-research":
        print("BAD|profile default_agent=%r (want content-aware-research)" % gp.get("default_agent"))
    else:
        print("OK|profile content-aware → content-aware-research")
team = os.path.join(repo, "teams", "content-aware-audit", "config.json")
print(("OK" if os.path.isfile(team) else "BAD") + "|team content-aware-audit " + ("present" if os.path.isfile(team) else "missing"))
# stale names
blob = json.dumps(omo)
if "grayhat" in blob.lower() or "security-audit" in blob:
    print("BAD|stale grayhat/security-audit strings still in oh-my-openagent.json")
else:
    print("OK|no grayhat leftovers in OmO config")
PY
)"
if [[ -z "$ca_report" ]]; then
  opt "could not evaluate content-aware wiring"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OK) ok "$msg" ;; OPT) opt "$msg" ;; BAD|FAIL) bad "$msg"; tip "restore content-aware agent/profile/team from repo" ;; *) info "$msg" ;; esac
  done <<< "$ca_report"
fi

# ─── Shell integration ───────────────────────────────────────────
sec "Shell integration"
if [ -f "$HOME/.zshrc" ] && grep -qF 'source ~/.config/opencode/zshrc.snippet' "$HOME/.zshrc" 2>/dev/null; then
  if grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$HOME/.zshrc" 2>/dev/null; then
    opt "zshrc sources snippet AND defines inline opencode() — run: oc setup (strips duplicate)"
  else
    ok "zshrc.snippet sourced in ~/.zshrc"
  fi
elif oc_zshrc_inline_stale "$HOME/.zshrc" 2>/dev/null; then
  bad "stale inline opencode() in ~/.zshrc (missing telemetry kill switches)"
  tip "fix: oc setup   # migrates to: source ~/.config/opencode/zshrc.snippet"
elif [ -f "$HOME/.zshrc" ] && grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$HOME/.zshrc" 2>/dev/null; then
  ok "opencode() function in ~/.zshrc (inline, telemetry present)"
elif [ -f "$HOME/.zshrc" ] && grep -q 'zshrc.snippet' "$HOME/.zshrc" 2>/dev/null; then
  ok "zshrc.snippet sourced in ~/.zshrc"
else
  opt "opencode() not in ~/.zshrc — add: source \"$REPO/zshrc.snippet\""
fi
echo ""

# ─── Supported versions (versions.json) ───────────────────────────
sec "Supported versions"
if [[ ! -f "$REPO/versions.json" ]]; then
  bad "versions.json missing"
  tip "restore from repo — pins OpenCode / OmO / Ghostty / tmux minima"
else
  _omo_pin="$(python3 -c "import json;p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my-openagent@' in x];print(p[0].split('@',1)[1] if p else '')" 2>/dev/null || true)"
  _omo_want="$(oc_versions_get oh_my_openagent.pin 2>/dev/null || true)"
  if [[ -n "$_omo_pin" && -n "$_omo_want" ]]; then
    if [[ "$_omo_pin" == "$_omo_want" ]]; then ok "oh-my-openagent pin $_omo_pin (matches versions.json)"
    else opt "oh-my-openagent pin $_omo_pin ≠ versions.json $_omo_want — update opencode.json or versions.json"; fi
  fi

  _check_ver() {
    local label="$1" tool="$2" key="$3" required="${4:-1}"
    local want have
    want="$(oc_versions_get "$key" 2>/dev/null || true)"
    have="$(oc_tool_version "$tool" 2>/dev/null || true)"
    if [[ -z "$want" ]]; then return 0; fi
    if [[ -z "$have" ]]; then
      if [[ "$required" == "1" ]]; then
        bad "$label not found (need ≥ $want)"
      else
        opt "$label not found (optional; supported ≥ $want)"
      fi
      case "$tool" in
        opencode) tip "full install: curl -fsSL https://opencode.ai/install | bash" ;;
        tmux) tip "install: brew install tmux" ;;
        ghostty) tip "install: https://ghostty.org (macOS app) — need ≥ $want for notify-on-command-finish" ;;
        bun) tip "install: curl -fsSL https://bun.sh/install | bash" ;;
        go) tip "install: brew install go   # for gopls" ;;
      esac
      return 0
    fi
    if oc_version_ge "$have" "$want"; then
      ok "$label $have (≥ $want)"
    else
      if [[ "$required" == "1" ]]; then
        bad "$label $have < supported min $want"
      else
        opt "$label $have < supported min $want"
      fi
      case "$tool" in
        opencode) tip "upgrade: curl -fsSL https://opencode.ai/install | bash" ;;
        tmux) tip "upgrade: brew upgrade tmux" ;;
        ghostty) tip "upgrade Ghostty via app auto-update (or https://ghostty.org)" ;;
        node) tip "upgrade: brew upgrade node   # or nvm/fnm" ;;
        python|python3) tip "upgrade: brew upgrade python" ;;
        bun) tip "upgrade: bun upgrade" ;;
        go) tip "upgrade: brew upgrade go" ;;
      esac
    fi
  }

  _check_ver "OpenCode CLI" opencode opencode.min 1
  _check_ver "tmux" tmux tmux.min 1
  _check_ver "Ghostty" ghostty ghostty.min 0
  _check_ver "node" node node.min 1
  _check_ver "python3" python3 python.min 1
  _check_ver "bun" bun bun.min 0
  _check_ver "go" go go.min 0

  _tmux_rec="$(oc_versions_get tmux.recommended 2>/dev/null || true)"
  _tmux_have="$(oc_tool_version tmux 2>/dev/null || true)"
  if [[ -n "$_tmux_rec" && -n "$_tmux_have" ]] && ! oc_version_ge "$_tmux_have" "$_tmux_rec"; then
    info "tmux $_tmux_have — recommended ≥ $_tmux_rec (brew upgrade tmux)"
  fi
fi

# ─── Terminal configs (tmux + Ghostty) ────────────────────────────
sec "Terminal configs"
# tmux binary + conf symlink + load-test + OmO-critical options
if command -v tmux >/dev/null 2>&1; then
  if [[ -L "$HOME/.tmux.conf" ]] && [[ "$(readlink "$HOME/.tmux.conf")" = "$REPO/tmux.conf" ]]; then
    ok "tmux.conf → $REPO/tmux.conf"
  elif [[ -f "$HOME/.tmux.conf" || -L "$HOME/.tmux.conf" ]]; then
    opt "tmux.conf exists but not symlinked to repo"
    tip "link: ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf   # or: oc setup --force"
  else
    opt "tmux.conf not linked"
    tip "link: ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf   # or: oc setup"
  fi
  # Syntax / load check in an isolated server (does not touch your sessions)
  _sock="ocdoctor$$"
  if tmux -L "$_sock" -f "$REPO/tmux.conf" new-session -d -s _ocdoctor 'sleep 30' 2>/tmp/oc-tmux-doctor.err; then
    ok "tmux.conf loads clean (isolated server)"
    _pt="$(tmux -L "$_sock" show -gv prefix 2>/dev/null || true)"
    _ap="$(tmux -L "$_sock" show -gv allow-passthrough 2>/dev/null || true)"
    _fe="$(tmux -L "$_sock" show -gv focus-events 2>/dev/null || true)"
    _ms="$(tmux -L "$_sock" show -gv mouse 2>/dev/null || true)"
    _hl="$(tmux -L "$_sock" show -gv history-limit 2>/dev/null || true)"
    [[ "$_pt" == "C-b" ]] && ok "prefix C-b (OpenCode Ctrl+X leader free)" || opt "prefix=$_pt (expected C-b so OpenCode Ctrl+X stays free)"
    [[ "$_ap" == "on" || "$_ap" == "all" ]] && ok "allow-passthrough $_ap (Ghostty/OpenCode OSC)" || opt "allow-passthrough=$_ap (want on — Ghostty/OpenCode)"
    [[ "$_fe" == "on" ]] && ok "focus-events on" || opt "focus-events=$_fe (want on)"
    [[ "$_ms" == "on" ]] && ok "mouse on" || info "mouse=$_ms"
    [[ -n "$_hl" && "$_hl" -ge 100000 ]] && ok "history-limit $_hl" || opt "history-limit $_hl (want ≥100000 for long sessions)"
    if tmux -L "$_sock" list-keys -T prefix 2>/dev/null | grep -q 'select-layout main-vertical'; then
      ok "OmO layout bind: prefix+M → main-vertical"
    else
      opt "missing prefix+M main-vertical bind (OmO team layout)"
      tip "restore: oc setup --force   # or copy $REPO/tmux.conf"
    fi
    tmux -L "$_sock" kill-server 2>/dev/null || true
  else
    bad "tmux.conf failed to load"
    tip "see /tmp/oc-tmux-doctor.err · restore: ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf"
    [[ -s /tmp/oc-tmux-doctor.err ]] && info "$(head -2 /tmp/oc-tmux-doctor.err | tr '\n' ' ')"
    tmux -L "$_sock" kill-server 2>/dev/null || true
  fi
  # OmO tmux / team visualization flags
  _omo_tmux="$(python3 -c "
import json
o=json.load(open('$REPO/oh-my-openagent.json'))
t=o.get('tmux') or {}
tm=o.get('team_mode') or {}
print('enabled=%s layout=%s isolation=%s viz=%s' % (
  t.get('enabled'), t.get('layout'), t.get('isolation'),
  tm.get('tmux_visualization')))
" 2>/dev/null || true)"
  if [[ -n "$_omo_tmux" ]]; then
    info "OmO tmux: $_omo_tmux"
    if [[ "$_omo_tmux" == *'enabled=True'* || "$_omo_tmux" == *'enabled=true'* ]]; then
      ok "OmO tmux integration enabled"
    else
      opt "OmO tmux.enabled is off — team pane layout disabled"
    fi
  fi
else
  bad "tmux not installed (OmO team visualization needs it)"
  tip "install: brew install tmux && ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf"
fi

# Ghostty
_gbin=""
if command -v ghostty >/dev/null 2>&1; then _gbin="$(command -v ghostty)"
elif [[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]]; then
  _gbin="/Applications/Ghostty.app/Contents/MacOS/ghostty"
fi
if [[ -n "$_gbin" ]]; then
  if [[ -L "$HOME/.config/ghostty/config" ]] && [[ "$(readlink "$HOME/.config/ghostty/config")" = "$REPO/ghostty.conf" ]]; then
    ok "ghostty.conf → $REPO/ghostty.conf"
  elif [[ -d "$HOME/.config/ghostty" ]]; then
    if [[ -f "$HOME/.config/ghostty/config" || -L "$HOME/.config/ghostty/config" ]]; then
      opt "ghostty config exists but not symlinked to repo"
      tip "link: mkdir -p ~/.config/ghostty && ln -sfn \"$REPO/ghostty.conf\" ~/.config/ghostty/config"
    else
      opt "Ghostty present but no config linked"
      tip "link: mkdir -p ~/.config/ghostty && ln -sfn \"$REPO/ghostty.conf\" ~/.config/ghostty/config"
    fi
  else
    info "Ghostty binary found; ~/.config/ghostty not created yet"
    tip "link: mkdir -p ~/.config/ghostty && ln -sfn \"$REPO/ghostty.conf\" ~/.config/ghostty/config"
  fi
  if "$_gbin" +validate-config --config-file="$REPO/ghostty.conf" >/tmp/oc-ghostty-doctor.out 2>&1; then
    ok "ghostty.conf validates"
  else
    # older ghostty may lack +validate-config
    if grep -qi 'unknown\|invalid\|error' /tmp/oc-ghostty-doctor.out 2>/dev/null; then
      opt "ghostty.conf validation reported issues"
      tip "see /tmp/oc-ghostty-doctor.out · or: oc doctor --ai-fix"
    else
      info "ghostty +validate-config unavailable — skipped"
    fi
  fi
  if grep -q 'notify-on-command-finish' "$REPO/ghostty.conf" 2>/dev/null; then
    ok "ghostty: notify-on-command-finish configured"
  fi
else
  opt "Ghostty not found (optional but recommended)"
  tip "install: https://ghostty.org  (≥ $(oc_versions_get ghostty.min 2>/dev/null || echo 1.3.0))"
fi
echo ""

# ─── Telemetry / phone-home ───────────────────────────────────────
sec "Telemetry (must be off)"
tel_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo = sys.argv[1]
oc = json.load(open(os.path.join(repo, "opencode.json")))
omo = json.load(open(os.path.join(repo, "oh-my-openagent.json")))
checks = []
checks.append(("OK" if oc.get("share") == "disabled" else "BAD", "share=%s" % oc.get("share")))
checks.append(("OK" if oc.get("autoupdate") is False else "BAD", "autoupdate=%s" % oc.get("autoupdate")))
checks.append(("OK" if (oc.get("experimental") or {}).get("openTelemetry") is False else "BAD",
               "openTelemetry=%s" % (oc.get("experimental") or {}).get("openTelemetry")))
checks.append(("OK" if (oc.get("server") or {}).get("mdns") is False else "BAD",
               "server.mdns=%s" % (oc.get("server") or {}).get("mdns")))
checks.append(("OK" if omo.get("telemetry") is False else "BAD", "omo.telemetry=%s" % omo.get("telemetry")))
checks.append(("OK" if (omo.get("codegraph") or {}).get("telemetry") is False else "BAD",
               "codegraph.telemetry=%s" % (omo.get("codegraph") or {}).get("telemetry")))
checks.append(("OK" if (omo.get("git_master") or {}).get("include_co_authored_by") is False else "BAD",
               "co_authored_by=%s" % (omo.get("git_master") or {}).get("include_co_authored_by")))
checks.append(("OK" if (omo.get("experimental") or {}).get("disable_omo_env") is True else "BAD",
               "disable_omo_env=%s" % (omo.get("experimental") or {}).get("disable_omo_env")))
dmcps = set(omo.get("disabled_mcps") or [])
checks.append(("OK" if "posthog:posthog" in dmcps and "sentry:sentry" in dmcps else "BAD",
               "posthog/sentry MCPs disabled"))
for kind, msg in checks:
    print("%s|%s" % (kind, msg))
PY
)"
if [[ -z "$tel_report" ]]; then
  opt "could not read telemetry config"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      OK) ok "$msg" ;;
      BAD) bad "$msg"; tip "run: oc fix   # enforces telemetry kill switches" ;;
      *) info "$msg" ;;
    esac
  done <<< "$tel_report"
fi
# Live env kill switches (from .env / process)
_tel_env_ok=1
for _kv in DO_NOT_TRACK=1 OMO_DISABLE_POSTHOG=1 OMO_SEND_ANONYMOUS_TELEMETRY=0 CODEGRAPH_TELEMETRY=0; do
  _k="${_kv%%=*}"; _want="${_kv#*=}"
  _got="$(oc_get_env_key "$REPO/.env" "$_k" 2>/dev/null || true)"
  if [[ "$_got" != "$_want" && -n "$_got" ]]; then
    # allow empty (will be forced at launch) but warn if explicitly wrong
    if [[ -n "$_got" && "$_got" != "$_want" ]]; then
      opt ".env $_k=$_got (launch forces $_want)"
    fi
  elif [[ -z "$_got" ]]; then
    info ".env $_k unset — launch/oc_telemetry_off will force $_want"
  else
    ok ".env $_k=$_want"
  fi
done
unset _kv _k _want _got _tel_env_ok
echo ""

# ─── Compaction optimizations ─────────────────────────────────────
sec "Compaction optimizations"
# Compaction is JSON-config (opencode.json compaction.* + experimental.compaction.autocontinue).
# Fake OPENCODE_EXPERIMENTAL_COMPACTION_* env vars do not exist in OpenCode 1.17.x.
comp_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo=sys.argv[1]
oc=json.load(open(os.path.join(repo,"opencode.json")))
comp=oc.get("compaction") or {}
exp=(oc.get("experimental") or {}).get("compaction") or {}
omo=json.load(open(os.path.join(repo,"oh-my-openagent.json")))
oexp=omo.get("experimental") or {}
if comp.get("auto"): print("OK|compaction.auto")
else: print("OPT|compaction.auto not enabled")
if comp.get("preserve_recent_tokens"):
    print("OK|preserve_recent_tokens=%s" % comp.get("preserve_recent_tokens"))
if exp.get("autocontinue") is True: print("OK|experimental.compaction.autocontinue")
else: print("OPT|set experimental.compaction.autocontinue=true so sessions keep going after compact")
if oexp.get("preemptive_compaction"): print("OK|omo preemptive_compaction")
if (oexp.get("dynamic_context_pruning") or {}).get("enabled"): print("OK|omo dynamic_context_pruning")
PY
)"
if [[ -z "$comp_report" ]]; then
  opt "could not read compaction config"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OK) ok "$msg" ;; OPT) opt "$msg" ;; FAIL) bad "$msg" ;; esac
  done <<< "$comp_report"
fi
echo ""

# ─── External sources & stray installs (hardening) ────────────────
# Everything that makes opencode load code/config from OUTSIDE this repo, plus
# opencode-owned junk that should not exist (desktop app, stale caches/procs).
# Detection is read-only; `./doctor.sh --harden` removes the opencode-owned
# artifacts and disables external loading (it never deletes your skill dirs).
sec "External sources & stray installs"
HARDEN_REMOVE=()   # opencode-owned paths safe to delete
HARDEN_KILL=()     # stale pids to kill

# 1. Desktop app + its Library data (opencode-owned → removable)
desktop_hits=()
for p in "/Applications/OpenCode.app" "$HOME/Applications/OpenCode.app" \
         "$HOME/Library/Application Support/ai.opencode.desktop" \
         "$HOME/Library/Application Support/@opencode-ai" \
         "$HOME/Library/Caches/ai.opencode.desktop" \
         "$HOME/Library/Caches/ai.opencode.desktop.ShipIt" \
         "$HOME/Library/Logs/ai.opencode.desktop" \
         "$HOME/Library/Logs/@opencode-ai" \
         "$HOME/Library/WebKit/ai.opencode.desktop" \
         "$HOME/Library/HTTPStorages/ai.opencode.desktop" \
         "$HOME/Library/Preferences/ai.opencode.desktop.plist"; do
  if [[ -e "$p" ]]; then desktop_hits+=("$p"); HARDEN_REMOVE+=("$p"); fi
done
if [[ ${#desktop_hits[@]} -gt 0 ]]; then
  opt "desktop app / data present (${#desktop_hits[@]} path(s)) — CLI-only setup; run ./doctor.sh --harden to remove"
else ok "no desktop app or its Library data (CLI-only)"; fi

# 2. Stale opencode / lsp-daemon processes (orphans hold old plugin code in memory)
if command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do [[ -n "$pid" ]] && HARDEN_KILL+=("$pid"); done < <(pgrep -f "OpenCode.app|ai.opencode.desktop|lsp-daemon/dist/cli.js" 2>/dev/null)
  if [[ ${#HARDEN_KILL[@]} -gt 0 ]]; then
    opt "${#HARDEN_KILL[@]} stale opencode/lsp-daemon process(es) — run ./doctor.sh --harden to kill"
  else ok "no stale opencode/lsp-daemon processes"; fi
fi

# 3. External config file that would load alongside the repo
ext_cfg=()
for f in "$HOME/.opencode/opencode.json" "$HOME/.opencode/opencode.jsonc"; do
  [[ -f "$f" ]] && ext_cfg+=("$f")
done
if [[ ${#ext_cfg[@]} -gt 0 ]]; then
  bad "external config loads alongside repo: ${ext_cfg[*]} — move/remove it (repo is the single source)"
else ok "no external opencode.json outside the repo"; fi

# 4. External skill dirs referenced by config (should be repo-local ./skills only)
ext_skills="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo=sys.argv[1]; ext=[]
def outside(p):
    p=str(p); return p.startswith(("~","/")) or ".claude" in p or ".agents" in p
oc=json.load(open(os.path.join(repo,"opencode.json")))
ext+=[p for p in (oc.get("skills",{}) or {}).get("paths",[]) if outside(p)]
omo=json.load(open(os.path.join(repo,"oh-my-openagent.json")))
for s in (omo.get("skills",{}) or {}).get("sources",[]):
    v=s.get("path") if isinstance(s,dict) else s
    if outside(v): ext.append(v)
print("|".join(dict.fromkeys(ext)))
PY
)"
if [[ -n "$ext_skills" ]]; then
  opt "skills load from OUTSIDE the repo: ${ext_skills//|/, } — run ./doctor.sh --fix to lock to ./skills"
else ok "skills load only from repo (./skills)"; fi

# 5. Claude Code bridge — imports external MCP/commands/skills/hooks
cc_on="$(python3 -c "
import json
cc=json.load(open('$REPO/oh-my-openagent.json')).get('claude_code',{}) or {}
on=[k for k in ('mcp','commands','skills','hooks','agents','plugins') if cc.get(k) is True]
print(','.join(on))
" 2>/dev/null)"
if [[ -n "$cc_on" ]]; then
  opt "claude_code bridge imports external: $cc_on — run ./doctor.sh --fix to disable"
else ok "claude_code bridge off (no external imports)"; fi

# 6. Stale package-manager caches — the root cause of the plugin-install 404 loop.
#    Flag only when the plugin cache is EMPTY (i.e. an install is actually failing).
if [[ -n "${pin:-}" ]]; then
  pcache="$HOME/.cache/opencode/packages/$pin"
  if [[ ! -d "$pcache" || -z "$(ls -A "$pcache" 2>/dev/null)" ]]; then
    if [[ -d "$HOME/.bun/install/cache" ]]; then
      opt "plugin cache empty AND ~/.bun/install/cache present — stale manifest may 404 the install; --harden clears it"
      HARDEN_REMOVE+=("$HOME/.bun/install/cache")
    fi
  else ok "package caches healthy (plugin installed)"; fi
fi
echo ""

# ─── Harden (optional): remove opencode-owned externals + disable external loading ─
if [[ $DO_HARDEN -eq 1 ]]; then
  sec "Harden"
  info "Removing opencode-owned external artifacts (your ~/.claude & ~/.agents dirs are left untouched)..."
  # kill stale processes first so nothing holds files open
  if [[ ${#HARDEN_KILL[@]} -gt 0 ]]; then
    kill "${HARDEN_KILL[@]}" 2>/dev/null; sleep 1; kill -9 "${HARDEN_KILL[@]}" 2>/dev/null
    ok "killed ${#HARDEN_KILL[@]} stale process(es)"
  fi
  # quit desktop app cleanly if running
  osascript -e 'quit app "OpenCode"' >/dev/null 2>&1 || true
  # remove opencode-owned external paths
  removed=0
  for p in "${HARDEN_REMOVE[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ -e "$p" ]]; then rm -rf "$p" && { ok "removed $p"; removed=$((removed+1)); }; fi
  done
  # also clear opencode's regenerated deps in ~/.opencode (keep the binary in bin/)
  rm -rf "$HOME/.opencode/node_modules" "$HOME/.opencode/package.json" \
         "$HOME/.opencode/package-lock.json" "$HOME/.opencode/bun.lock" 2>/dev/null
  # omo's regenerable external caches (NOT sessions/db under ~/.local/share/opencode)
  rm -rf "$HOME/.cache/oh-my-opencode" "$HOME/.local/share/oh-my-opencode" 2>/dev/null
  ok "cleared ~/.opencode regenerated deps + omo external caches"
  [[ $removed -eq 0 ]] && info "no desktop/app artifacts to remove"
  # disable external loading via config (idempotent)
  if [[ -x "$REPO/fix.sh" ]]; then
    info "Disabling external loading in config (skills -> ./skills, claude_code bridge off)..."
    "$REPO/fix.sh" >/dev/null 2>&1 && ok "config locked to repo"
  fi
  echo ""
  info "Re-running doctor..."
  if [[ $DO_QUICK -eq 1 ]]; then exec "$REPO/doctor.sh" --quick; else exec "$REPO/doctor.sh"; fi
fi

# ─── Auto-fix (optional) ─────────────────────────────────────────
if [[ $DO_FIX -eq 1 ]]; then
  sec "Auto-fix"
  if [[ -x "$REPO/fix.sh" ]]; then
    info "Running fix.sh (colors, footguns, skills lock)..."
    "$REPO/fix.sh" 2>&1
    ok "fix.sh complete"
    echo ""
    info "Re-running doctor..."
    if [[ $DO_QUICK -eq 1 ]]; then exec "$REPO/doctor.sh" --quick; else exec "$REPO/doctor.sh"; fi
  else
    bad "fix.sh not found"
  fi
fi

# ─── AI-assisted fix (optional) ──────────────────────────────────
if [[ $DO_AI -eq 1 ]]; then
  sec "AI-assisted diagnosis"
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    # try .env
    OPENROUTER_API_KEY="$(oc_get_env_key "$REPO/.env" OPENROUTER_API_KEY 2>/dev/null || true)"
  fi
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    bad "OPENROUTER_API_KEY not set — cannot use AI fix"
    tip "add key to $REPO/.env then: oc doctor --ai-fix"
  elif [[ ! -x "$REPO/run.sh" ]]; then
    bad "run.sh not found — cannot launch AI"
  else
    info "Launching OpenCode AI to diagnose and fix issues..."
    if [[ $DO_QUICK -eq 1 ]]; then
      "$REPO/doctor.sh" --quick > /tmp/oc-doctor-output.txt 2>&1
    else
      "$REPO/doctor.sh" > /tmp/oc-doctor-output.txt 2>&1
    fi
    "$REPO/run.sh" "Read /tmp/oc-doctor-output.txt. This is the output of doctor.sh. Fix every issue marked ✗ or ⚠. Run fix.sh first (restores agent colors), then manually fix any remaining issues. Verify with validate.sh and doctor.sh after fixing." 2>&1 || true
    ok "AI fix complete — re-running doctor..."
    echo ""
    if [[ $DO_QUICK -eq 1 ]]; then exec "$REPO/doctor.sh" --quick; else exec "$REPO/doctor.sh"; fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────
sec "Summary"
if [[ $crit -eq 0 && $miss -eq 0 ]]; then
  printf "  ${c_g}${c_bold}Ready to code — everything checks out.${c_0}\n"
elif [[ $crit -eq 0 ]]; then
  printf "  ${c_g}Core is ready.${c_0} ${c_y}$miss optional item(s) missing (see ⚠ above).${c_0}\n"
  tip "full install tips above · or: bash \"$REPO/install.sh\" · oc fix · oc setup"
else
  printf "  ${c_r}$crit critical issue(s)${c_0} + ${c_y}$miss optional${c_0} — fix ✗ items before coding.\n"
  tip "bash \"$REPO/install.sh\"   # full stack"
  tip "oc fix                     # colors + config footguns"
  tip "oc validate && oc doctor   # re-check"
fi
echo ""
exit $(( crit > 0 ? 1 : 0 ))
