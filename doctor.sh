#!/usr/bin/env bash
# doctor.sh — Full OpenConfig readiness check.
# Covers CLI, config link, signature, plugin (+ peer skew), LSP, formatters,
# keys, models, MCP, permissions, content-aware + local skills, terminal,
# telemetry, compaction, runtime log WARN/ERROR signatures, and external-source
# hardening.
#
# Usage: ./doctor.sh [--quick] [--json] [--fix] [--harden] [--ai-fix]
#   --quick   skip live model-routing probes (still classifies OpenRouter key)
#   --json    machine-readable summary only (implies quiet human sections)
#   --fix     run fix.sh (colors, footguns, skills lock, goal off) then re-check
#   --harden  remove opencode-owned external junk + disable external loading
#   --ai-fix  use OpenCode AI to diagnose and fix issues
#
# Exit: 0 = no critical issues (optional/soft advisories allowed)
#       1 = critical issues present
#
# Keys: compare to the live ~/.config/opencode tree when that is
# OpenConfig. A secondary checkout is check-only (no retarget, no key-critical
# unless this tree *is* the live install). Never prints secrets.
# Related: oc check · oc validate · oc heal · oc diagnose · oc secrets

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
OC_BIN="${OC_DOCTOR_BIN:-$(command -v opencode 2>/dev/null || echo "$OC_CLI_BIN")}"
LINK="${OC_CONFIG_LINK}"
LIVE_ROOT="$(oc_live_config_root 2>/dev/null || true)"
IS_LIVE=0
oc_is_live_config "$REPO" && IS_LIVE=1
export OC_LIVE_CONFIG="${LIVE_ROOT}"

DO_QUICK=0 DO_FIX=0 DO_HARDEN=0 DO_AI=0 DO_JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) DO_QUICK=1; shift ;;
    --json) DO_JSON=1; shift ;;
    --fix) DO_FIX=1; shift ;;
    --harden) DO_HARDEN=1; shift ;;
    --ai-fix) DO_AI=1; shift ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $1 (try --quick --json --fix --harden --ai-fix)"; exit 2 ;;
  esac
done

# --json suppresses human chrome; still runs every check.
# Colors: ok=green, info=dim cyan, tip=bold cyan, soft/opt=yellow, bad=red
if [[ -t 1 && -z "${NO_COLOR:-}" && $DO_JSON -eq 0 ]]; then
  c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'
  c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_0=$'\033[0m'
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_dim=""; c_bold=""; c_0=""
fi
crit=0; miss=0; softn=0
# soft = advisory (latency blip, known npm lag) — does NOT count as "optional missing"
sec(){ [[ $DO_JSON -eq 1 ]] && return 0; oc_section "$*"; }
ok(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_g}✓${c_0} %s\n" "$*"; }
info(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_dim}•${c_0} %s\n" "$*"; }
tip(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_b}${c_bold}↳${c_0} ${c_dim}%s${c_0}\n" "$*"; }
soft(){ softn=$((softn+1)); [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_y}~${c_0} %s\n" "$*"; }
opt(){ miss=$((miss+1)); [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ crit=$((crit+1)); [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_r}✗${c_0} %s\n" "$*"; }

OC_DOCTOR_VER="$(oc_versions_get opencode_configs 2>/dev/null || echo "?")"
if [[ $DO_JSON -eq 0 ]]; then
  _flags=""
  [[ $DO_QUICK -eq 1 ]] && _flags="${_flags} · --quick"
  oc_section "oc doctor"
  if [[ $IS_LIVE -eq 1 ]]; then
    printf "  ${c_dim}v%s · live %s%s${c_0}\n" "$OC_DOCTOR_VER" "$REPO" "$_flags"
  else
    printf "  ${c_dim}v%s · %s%s${c_0}\n" "$OC_DOCTOR_VER" "$REPO" "$_flags"
    [[ -n "$LIVE_ROOT" ]] && info "live install: $LIVE_ROOT"
  fi
  unset _flags
fi

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
if [[ $IS_LIVE -eq 1 ]]; then
  ok "$LINK → $REPO (live)"
elif [[ -n "$LIVE_ROOT" ]]; then
  ok "live install: $LINK → $LIVE_ROOT"
  info "this checkout: $REPO (check-only — keys follow the live tree)"
elif [[ -L "$LINK" ]]; then
  tgt="$(readlink "$LINK")"
  opt "$LINK → $tgt (not an OpenConfig tree; run: oc setup from the intended install)"
elif [[ -e "$LINK" ]]; then
  opt "$LINK is a real dir, not a symlink (run: oc setup)"
else
  bad "$LINK does not exist (run: oc setup)"
fi
# Leftover copies (exclude ~/.opencode CLI install dir + the live install)
for d in "$HOME/.opencode" "$HOME/opencode-configs" /usr/local/opencode; do
  [[ "$d" == "$REPO" ]] && continue
  [[ -n "$LIVE_ROOT" ]] && oc_same_path "$d" "$LIVE_ROOT" && continue
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
  ok "config dir is clean (no node_modules/package.json/.omo/.sisyphus/command/plugins)"
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
    ok "$name: $cmd"
  else
    opt "$name: $cmd NOT installed (LSP tools disabled for this language)"
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
# _lsp_miss already counted via opt(); do not double-add
unset _lsp_miss

# ─── Formatters ──────────────────────────────────────────────────────
sec "Formatters"
while read -r name cmd; do
  [[ -z "$cmd" ]] && continue
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$name: $cmd"
  else
    opt "$name: $cmd not on PATH (auto-format skipped)"
    case "$name" in
      prettier) tip "install: npm i -g prettier" ;;
      ruff) tip "install: brew install ruff   # or: pipx install ruff" ;;
      *) tip "install '$cmd' and ensure it is on PATH" ;;
    esac
  fi
done < <(python3 -c "import json;[print(k,(v.get('command') or [''])[0]) for k,v in json.load(open('$REPO/opencode.json')).get('formatter',{}).items() if not v.get('disabled')]" 2>/dev/null)

# ─── API keys ────────────────────────────────────────────────────────
sec "API keys (.env)"
ENV_FILE="$REPO/.env"
getkey(){ oc_get_env_key "${ENV_FILE:-$REPO/.env}" "$1"; }
# Key severity: critical only on the live install. Secondary checkouts are
# optional/soft (clone may have no .env, a stale key, or no network).
_key_bad(){ if [[ $IS_LIVE -eq 1 ]]; then bad "$@"; else opt "$@"; fi; }
if [[ -f "$ENV_FILE" ]]; then
  for k in OPENROUTER_API_KEY; do
    if [[ -n "$(getkey $k)" ]]; then ok "$k set"
    else
      _key_bad "$k unset"
      tip "https://openrouter.ai/keys  ·  then: oc secrets sync"
    fi
  done
  for k in CONTEXT7_API_KEY EXA_API_KEY VENICE_API_KEY DEEPSEEK_API_KEY; do
    if [[ -n "$(getkey $k)" ]]; then ok "$k set"
    else
      case "$k" in
        CONTEXT7_API_KEY)
          opt "$k unset (Context7 docs MCP unauthenticated)"
          tip "https://context7.com/dashboard  ·  oc secrets sync"
          ;;
        EXA_API_KEY)
          opt "$k unset (Exa web search unavailable)"
          tip "https://exa.ai  ·  oc secrets sync"
          ;;
        VENICE_API_KEY)
          if [[ $IS_LIVE -eq 1 ]]; then
            opt "$k unset (content-aware Venice lane unavailable)"
          else
            opt "$k unset (content-aware lane; optional on clone)"
          fi
          tip "https://venice.ai  ·  oc secrets sync"
          ;;
        DEEPSEEK_API_KEY)
          opt "$k unset (native DeepSeek provider unavailable)"
          tip "https://platform.deepseek.com  ·  oc secrets sync"
          ;;
      esac
    fi
  done
  if [[ -n "$(getkey OPENAI_API_KEY)" ]]; then
    soft "OPENAI_API_KEY in .env — OpenRouter-only stack; remove it (run: oc fix)"
  else
    ok "OpenRouter-only (no OPENAI_API_KEY)"
  fi
  # Foreign (non-allowlisted) keys — never print names/values; count only.
  _foreign="$(oc_env_foreign_key_count "$ENV_FILE" 2>/dev/null || echo 0)"
  if [[ "${_foreign:-0}" -gt 0 ]]; then
    opt ".env has $_foreign non-allowlisted key(s) (company secrets don't belong here)"
    tip "scrub: oc env --scrub   · full backup stays under ~/.opencode-backups/"
  else
    ok ".env allowlist-clean (OpenConfig keys only)"
  fi
  # Live OpenRouter probe — never dump the body or the key.
  ork="$(getkey OPENROUTER_API_KEY)"
  if [[ -n "$ork" ]] && command -v curl >/dev/null; then
    _or_tmp="$(mktemp "${TMPDIR:-/tmp}/oc-doctor-or.XXXXXX")"
    _or_out="$(curl -sS -o "$_or_tmp" -w '%{http_code} %{time_total}' \
      --connect-timeout 5 --max-time 15 \
      -H "Authorization: Bearer ${ork}" https://openrouter.ai/api/v1/key 2>/dev/null || echo "000 0")"
    rm -f "$_or_tmp"
    unset ork
    code="${_or_out%% *}"
    secs="${_or_out##* }"
    ms="$(python3 -c "print(int(round(float('$secs')*1000)))" 2>/dev/null || echo "?")"
    if [[ "$code" == "200" ]]; then
      ok "OpenRouter key accepted (HTTP 200, ${ms}ms)"
      if [[ "$ms" != "?" && "$ms" -gt 800 ]]; then
        soft "OpenRouter latency ${ms}ms (typical ~200–400ms) — network blip"
      elif [[ "$ms" != "?" && "$ms" -gt 400 ]]; then
        info "OpenRouter latency ${ms}ms — usually fine"
      fi
    elif [[ "$code" == "401" || "$code" == "403" ]]; then
      _key_bad "OpenRouter key rejected (HTTP $code)"
      if [[ $IS_LIVE -eq 1 ]]; then
        tip "rotate at https://openrouter.ai/keys  ·  oc secrets sync  ·  oc admin credits"
      else
        info "this checkout's .env; live install is authoritative"
        tip "oc secrets sync   ·  or ignore if you only run OpenCode from the live tree"
      fi
    elif [[ "$code" == "000" ]]; then
      soft "OpenRouter key check unreachable (network) — retry or oc admin health"
    else
      soft "OpenRouter key check returned HTTP $code (${ms}ms) — retry or oc admin health"
    fi
    unset _or_tmp _or_out code secs ms
  fi
else
  if [[ $IS_LIVE -eq 1 ]]; then
    bad ".env missing — copy .env.example and add OPENROUTER_API_KEY"
    tip "oc secrets sync   ·  or: cp \"$REPO/.env.example\" \"$REPO/.env\" && chmod 600 \"$REPO/.env\""
  else
    opt ".env absent in this checkout (secondary — secrets live on the install tree)"
    tip "oc secrets sync   ·  or run doctor from the live install"
  fi
fi

# ─── Secrets backends (1Password / Infisical) ────────────────────────
sec "Secrets backends"
if [[ -f "$REPO/vault.json" ]]; then
  ok "vault.json present"
  _be="$(oc_secrets_backend 2>/dev/null || echo none)"
  info "active backend: $_be"
  if command -v op >/dev/null 2>&1; then
    if oc_secrets_1password_ready; then
      ok "1Password CLI signed in"
      _n=0
      while IFS=$'\t' read -r _k _r; do
        [[ -n "$_k" ]] || continue
        _n=$((_n + 1))
      done < <(oc_vault_op_refs)
      if [[ "$_n" -gt 0 ]]; then
        ok "$_n 1Password ref(s) configured (names only)"
      else
        opt "no live 1Password refs — edit vault.local.json (gitignored overlay)"
      fi
    else
      opt "1Password CLI present — sign in (Developer → Integrate with 1Password CLI)"
    fi
  else
    opt "1Password CLI (op) not installed — brew install 1password-cli"
  fi
  if command -v infisical >/dev/null 2>&1; then
    if oc_secrets_infisical_ready; then
      ok "Infisical fallback ready"
    else
      info "Infisical CLI present (set INFISICAL_DIR to use as fallback)"
    fi
  fi
  tip "sync: oc secrets sync   ·  status: oc secrets status"
else
  bad "vault.json missing"
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

# ─── Model routing (live probe: would catch "all providers ignored") ──
# Sends a 1-token request per model with its EXACT configured provider block.
# Catches over-tight max_price / ignore combos that route to zero providers.
sec "Model routing (live)"
if [[ $DO_QUICK -eq 1 ]]; then
  info "skipped (--quick) — run: oc doctor   or   oc admin health"
elif [[ -f "$ENV_FILE" ]] && [[ -n "$(getkey OPENROUTER_API_KEY)" ]] && command -v curl >/dev/null; then
  probe="$(ORK="$(getkey OPENROUTER_API_KEY)" python3 - "$REPO" <<'PY'
import json, os, re, sys, time, urllib.request, urllib.error
repo=sys.argv[1]; key=os.environ.pop("ORK", "")
def scrub(s):
    s = str(s or "")
    s = re.sub(r"(?i)bearer\s+\S+", "Bearer <redacted>", s)
    s = re.sub(r"sk-(or-v1-|proj-)?[A-Za-z0-9_-]{8,}", "sk-<redacted>", s)
    s = re.sub(r"(?i)(api[_-]?key|token|secret)[=:]\S+", r"\1=<redacted>", s)
    return s[:80]
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
        msg = f"HTTP {e.code}"
        try:
            raw = e.read().decode("utf-8", "replace")[:400]
            err = json.loads(raw).get("error", {})
            if isinstance(err, dict):
                code = err.get("code") or err.get("type")
                if code:
                    msg = f"HTTP {e.code} {code}"
        except Exception:
            pass
        print(f"ERR|{mid}|{scrub(msg)}")
    except Exception as e:
        print(f"ERR|{mid}|{scrub(e)}")
PY
)"
  unset ORK 2>/dev/null || true
  probe="$(printf '%s\n' "$probe" | oc_redact_secrets)"
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
_mcp_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo = sys.argv[1]
m = json.load(open(os.path.join(repo, "opencode.json"))).get("mcp") or {}
if not m:
    print("INFO|no MCP servers configured")
for n, c in m.items():
    if not isinstance(c, dict):
        continue
    en = c.get("enabled", True)
    url = c.get("url") or ((c.get("command") or [""])[0])
    if en:
        print("OK|%s enabled (%s)" % (n, url))
        if n == "context7":
            envf = os.path.join(repo, ".env")
            key = ""
            if os.path.isfile(envf):
                for line in open(envf, encoding="utf-8"):
                    if line.startswith("CONTEXT7_API_KEY=") and not line.strip().endswith("="):
                        key = line.split("=", 1)[1].strip().strip("'\"")
                        break
            if key:
                print("OK|context7 has CONTEXT7_API_KEY")
            else:
                print("OPT|context7 enabled but CONTEXT7_API_KEY unset")
    else:
        print("INFO|%s disabled" % n)
PY
)"
if [[ -z "$_mcp_report" ]]; then
  opt "could not evaluate MCP servers"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OK) ok "$msg" ;; OPT) opt "$msg" ;; INFO) info "$msg" ;; *) info "$msg" ;; esac
  done <<< "$_mcp_report"
fi
unset _mcp_report

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

# ─── Skills paths + inventory ────────────────────────────────────────
sec "Skills sources"
_sk_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, re, sys
repo = sys.argv[1]
oc = json.load(open(os.path.join(repo, "opencode.json")))
paths = set((oc.get("skills") or {}).get("paths") or [])
allowed = {"~/.config/opencode/skills", "./skills"}
home = os.path.expanduser("~")

def expand(p):
    if p.startswith("~/"):
        return os.path.join(home, p[2:])
    if p == "./skills":
        return os.path.join(repo, "skills")
    return p

if not paths:
    print("OK|skills fence active - no sources configured")
else:
    for p in sorted(paths):
        ep = expand(p)
        if os.path.isdir(ep):
            print("OK|source %s -> %s" % (p, ep))
        elif p == "./skills":
            print("INFO|./skills (project-local; oc new creates it)")
        else:
            print("OPT|%s (not present)" % p)
            print("TIP|mkdir -p %s  # or: oc fix" % ep)
    outside = [p for p in paths if p not in allowed and (".claude" in p or ".agents" in p)]
    if outside:
        print("OPT|skills fence leak: %s - run: oc fix" % ", ".join(outside))
    else:
        print("OK|skills fence = ~/.config/opencode/skills + ./skills")

skills_root = os.path.join(repo, "skills")
found = []
if os.path.isdir(skills_root):
    for name in sorted(os.listdir(skills_root)):
        skill = os.path.join(skills_root, name, "SKILL.md")
        if not os.path.isfile(skill):
            continue
        text = open(skill, encoding="utf-8").read(4000)
        m = re.search(r"(?m)^name:\s*[\"']?([A-Za-z0-9._-]+)", text)
        front = m.group(1) if m else name
        if front != name:
            print("OPT|skills/%s/SKILL.md name=%r (dir is %r)" % (name, front, name))
        else:
            found.append(name)
            print("OK|skill %s" % name)
required = ("content-aware-recon", "content-aware-audit")
missing = [n for n in required if n not in found]
if missing:
    for n in missing:
        print("BAD|required skill missing: skills/%s/SKILL.md" % n)
    print("TIP|restore from repo")
else:
    print("OK|required content-aware skills present (%s)" % ", ".join(required))

PY
)"
if [[ -z "$_sk_report" ]]; then
  opt "could not evaluate skills sources"
else
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      OK) ok "$msg" ;;
      INFO) info "$msg" ;;
      TIP) tip "$msg" ;;
      OPT) opt "$msg" ;;
      SOFT) soft "$msg" ;;
      BAD|FAIL) bad "$msg" ;;
      *) info "$msg" ;;
    esac
  done <<< "$_sk_report"
fi
unset _sk_report

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
# Mostly informational. Footgun signatures (goal / empty plugin) escalate.
sec "Runtime log health"
LOG="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/log/opencode.log"
if [[ -f "$LOG" ]]; then
  tailn="$(tail -n 20000 "$LOG" 2>/dev/null)"
  errc="$(printf '%s\n' "$tailn" | grep -c 'level=ERROR' 2>/dev/null || true)"
  if [[ "${errc:-0}" -eq 0 ]]; then
    ok "no ERROR lines in the last 20k log lines"
  else
    info "$errc ERROR line(s) in last 20k lines of $LOG — top signatures:"
    if [[ $DO_JSON -eq 0 ]]; then
      printf '%s\n' "$tailn" | grep 'level=ERROR' \
        | sed -E 's/.*message=//; s/^"([^"]*)".*/\1/; s/ (ref|error|cause|sessionID|session\.id|messageID|stack|small|agent|providerID|modelID)=.*$//; s/ses_[A-Za-z0-9]+/ses_…/g; s/[0-9]+/N/g' \
        | sort | uniq -c | sort -rn | head -3 \
        | while read -r n rest; do printf "      %6dx %s\n" "$n" "$(printf '%s' "$rest" | cut -c1-88)"; done
    fi
    fmt_hits="$(printf '%s\n' "$tailn" | grep -cE 'failed to format file|failed command=.*prettier' 2>/dev/null || true)"
    bun_be="$(printf '%s\n' "$tailn" | grep -c 'BUN_BE_BUN' 2>/dev/null || true)"
    if [[ "${fmt_hits:-0}" -gt 5 ]]; then
      soft "formatter noise (${fmt_hits} hits in log) — prettier/ruff PATH or formatter command env"
      tip "ensure prettier + ruff on PATH; if BUN_BE_BUN appears, launch via oc launch (not raw bun-wrapped prettier)"
    elif [[ "${bun_be:-0}" -gt 0 && "${fmt_hits:-0}" -gt 0 ]]; then
      soft "prettier formatter failed with BUN_BE_BUN in log — use system prettier on PATH"
    fi
  fi
  misuse_report="$(oc_log_misuse_report "$LOG" 2>/dev/null || true)"
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in OPT) opt "$msg" ;; TIP) tip "$msg" ;; *) info "$msg" ;; esac
  done <<< "$misuse_report"
  # WARN signatures that matter for OpenConfig footguns
  plugin_miss="$(printf '%s\n' "$tailn" | grep -c 'No matching version found for @opencode-ai/plugin@' 2>/dev/null || true)"
  if [[ "${plugin_miss:-0}" -gt 0 ]]; then
    if [[ "${OC_DOCTOR_PLUGIN_PEER_OK:-0}" -eq 1 ]]; then
      info "stale @opencode-ai/plugin npm-miss WARNs in log ($plugin_miss) — peer now matches CLI; ignore"
    else
      soft "recent @opencode-ai/plugin npm miss ($plugin_miss WARN) — CLI ahead of registry"
      tip "align peer: oc versions --fix   "
    fi
  fi
else
  info "no opencode log yet ($LOG)"
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
[[ $DO_JSON -eq 0 ]] && echo ""
# ─── Supported versions (versions.json) ───────────────────────────
sec "Supported versions"
if [[ ! -f "$REPO/versions.json" ]]; then
  bad "versions.json missing"
  tip "restore from repo — pins OpenCode / Ghostty / tmux minima"
else
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
# tmux binary + conf symlink + load-test
if command -v tmux >/dev/null 2>&1; then
  if oc_runtime_conf_ok "$HOME/.tmux.conf" tmux.conf; then
    ok "tmux.conf → live install"
  elif [[ -f "$HOME/.tmux.conf" || -L "$HOME/.tmux.conf" ]]; then
    opt "tmux.conf exists but not linked to the live install"
    tip "from the live tree: oc setup"
  else
    opt "tmux.conf not linked"
    tip "from the live tree: oc setup"
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
    tmux -L "$_sock" kill-server 2>/dev/null || true
  else
    bad "tmux.conf failed to load"
    tip "see /tmp/oc-tmux-doctor.err · restore: ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf"
    [[ -s /tmp/oc-tmux-doctor.err ]] && info "$(head -2 /tmp/oc-tmux-doctor.err | tr '\n' ' ')"
    tmux -L "$_sock" kill-server 2>/dev/null || true
  fi
else
  bad "tmux not installed"
  tip "install: brew install tmux && ln -sfn \"$REPO/tmux.conf\" ~/.tmux.conf"
fi

# Ghostty
_gbin=""
if command -v ghostty >/dev/null 2>&1; then _gbin="$(command -v ghostty)"
elif [[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]]; then
  _gbin="/Applications/Ghostty.app/Contents/MacOS/ghostty"
fi
if [[ -n "$_gbin" ]]; then
  if oc_runtime_conf_ok "$HOME/.config/ghostty/config" ghostty.conf; then
    ok "ghostty.conf → live install"
  elif [[ -d "$HOME/.config/ghostty" ]]; then
    if [[ -f "$HOME/.config/ghostty/config" || -L "$HOME/.config/ghostty/config" ]]; then
      opt "ghostty config exists but not linked to the live install"
      tip "from the live tree: oc setup"
    else
      opt "Ghostty present but no config linked"
      tip "from the live tree: oc setup"
    fi
  else
    info "Ghostty binary found; ~/.config/ghostty not created yet"
    tip "from the live tree: oc setup"
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
[[ $DO_JSON -eq 0 ]] && echo ""
# ─── Telemetry / phone-home ───────────────────────────────────────
sec "Telemetry (must be off)"
tel_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo = sys.argv[1]
oc = json.load(open(os.path.join(repo, "opencode.json")))
checks = []
checks.append(("OK" if oc.get("share") == "disabled" else "BAD", "share=%s" % oc.get("share")))
checks.append(("OK" if oc.get("autoupdate") is False else "BAD", "autoupdate=%s" % oc.get("autoupdate")))
checks.append(("OK" if oc.get("logLevel") == "ERROR" else "BAD", "logLevel=%s" % oc.get("logLevel")))
checks.append(("OK" if (oc.get("experimental") or {}).get("openTelemetry") is False else "BAD",
               "openTelemetry=%s" % (oc.get("experimental") or {}).get("openTelemetry")))
checks.append(("OK" if (oc.get("server") or {}).get("mdns") is False else "BAD",
               "server.mdns=%s" % (oc.get("server") or {}).get("mdns")))
or_models = (((oc.get("provider") or {}).get("openrouter") or {}).get("models") or {})
available_routes = all(
    (((m.get("options") or {}).get("provider") or {}).get("data_collection") == "allow"
     and "zdr" not in ((m.get("options") or {}).get("provider") or {}))
    for m in or_models.values() if isinstance(m, dict)
)
checks.append(("OK" if available_routes and or_models else "BAD", "OpenRouter routes unrestricted (data_collection=allow, no ZDR filter)"))
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
for _kv in DO_NOT_TRACK=1; do
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
[[ $DO_JSON -eq 0 ]] && echo ""
# ─── Compaction optimizations ─────────────────────────────────────
sec "Compaction optimizations"
# Compaction is configured through supported opencode.json compaction.* keys.
comp_report="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo=sys.argv[1]
oc=json.load(open(os.path.join(repo,"opencode.json")))
comp=oc.get("compaction") or {}
if comp.get("auto"): print("OK|compaction.auto")
else: print("OPT|compaction.auto not enabled")
if comp.get("preserve_recent_tokens"):
    print("OK|preserve_recent_tokens=%s" % comp.get("preserve_recent_tokens"))
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
[[ $DO_JSON -eq 0 ]] && echo ""
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

# 2. Stale processes only — NEVER flag lsp-daemons owned by a live `opencode` /
#    OpenCode.app / Cursor session (older doctor --harden killed those and nuked TUIs).
if command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && HARDEN_KILL+=("$pid")
  done < <(pgrep -f "OpenCode.app|ai.opencode.desktop" 2>/dev/null)
  # Orphan lsp-daemon PIDs only (no opencode/Cursor ancestor)
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if python3 -c '
import subprocess, sys
pid = int(sys.argv[1])
cur = pid
for _ in range(16):
    try:
        line = subprocess.check_output(["ps", "-p", str(cur), "-o", "ppid=,command="], text=True).strip()
    except Exception:
        sys.exit(0)  # gone → treat as orphanish no-op
    if not line:
        sys.exit(0)
    parts = line.split(None, 1)
    if len(parts) < 2:
        sys.exit(0)
    ppid, cmd = int(parts[0]), parts[1]
    cl = cmd.lower()
    if cur != pid:
        if "lsp-daemon" not in cl and "opencode" in cl:
            sys.exit(1)  # live CLI
        if "opencode.app" in cl or "ai.opencode.desktop" in cl:
            sys.exit(1)
        if "cursor" in cl and ("helper" in cl or "extension-host" in cl):
            sys.exit(1)
    if ppid in (0, 1) or ppid == cur:
        sys.exit(0)  # orphan
    cur = ppid
sys.exit(0)
' "$pid"
    then
      HARDEN_KILL+=("$pid")
    fi
  done < <(pgrep -f "lsp-daemon/dist/cli.js" 2>/dev/null)
  if [[ ${#HARDEN_KILL[@]} -gt 0 ]]; then
    # shellcheck disable=SC2207
    HARDEN_KILL=($(printf '%s\n' "${HARDEN_KILL[@]}" | awk 'NF && !seen[$0]++'))
  fi
  if [[ ${#HARDEN_KILL[@]} -gt 0 ]]; then
    opt "${#HARDEN_KILL[@]} stale OpenCode.app / orphan lsp-daemon process(es) — run ./doctor.sh --harden to kill"
  else
    ok "no stale OpenCode.app / orphan lsp-daemon processes (live session daemons left alone)"
  fi
fi

# 3. External config file that would load alongside the repo
ext_cfg=()
for f in "$HOME/.opencode/opencode.json" "$HOME/.opencode/opencode.jsonc"; do
  [[ -f "$f" ]] && ext_cfg+=("$f")
done
if [[ ${#ext_cfg[@]} -gt 0 ]]; then
  bad "external config loads alongside repo: ${ext_cfg[*]} — move/remove it (repo is the single source)"
else ok "no external opencode.json outside the repo"; fi

# 4. Skills fence — global OpenConfig skills + project ./skills (no ~/.claude / ~/.agents)
ext_skills="$(python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo=sys.argv[1]; ext=[]
ALLOWED={ "~/.config/opencode/skills", "./skills" }
def outside(p):
    p=str(p)
    if p in ALLOWED: return False
    return ".claude" in p or ".agents" in p or (p.startswith(("~","/")) and "opencode/skills" not in p)
oc=json.load(open(os.path.join(repo,"opencode.json")))
ext+=[p for p in (oc.get("skills",{}) or {}).get("paths",[]) if outside(p)]
print("|".join(dict.fromkeys(ext)))
PY
)"
if [[ -n "$ext_skills" ]]; then
  opt "skills load from OUTSIDE OpenConfig: ${ext_skills//|/, } — run: oc fix"
else ok "skills: ~/.config/opencode/skills + ./skills (any project cwd)"; fi

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
[[ $DO_JSON -eq 0 ]] && echo ""
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
  ok "cleared ~/.opencode regenerated deps"
  [[ $removed -eq 0 ]] && info "no desktop/app artifacts to remove"
  # disable external loading via config (idempotent)
  if [[ -x "$REPO/fix.sh" ]]; then
    info "Disabling external loading in config (skills -> ./skills)..."
    "$REPO/fix.sh" >/dev/null 2>&1 && ok "config locked to repo"
  fi
  [[ $DO_JSON -eq 0 ]] && echo ""
  info "Re-running doctor..."
  if [[ $DO_QUICK -eq 1 ]]; then exec "$REPO/doctor.sh" --quick; else exec "$REPO/doctor.sh"; fi
fi

# ─── Auto-fix (optional) ─────────────────────────────────────────
if [[ $DO_FIX -eq 1 ]]; then
  sec "Auto-fix"
  if [[ -x "$REPO/versions.sh" ]]; then
    info "Aligning @opencode-ai/plugin peer (oc versions --fix)..."
    "$REPO/versions.sh" --fix >/dev/null 2>&1 && ok "versions --fix ok" || soft "versions --fix reported issues (non-fatal)"
  fi
  if [[ -x "$REPO/fix.sh" ]]; then
    info "Running fix.sh (colors, footguns, skills lock)..."
    "$REPO/fix.sh" 2>&1
    ok "fix.sh complete"
    [[ $DO_JSON -eq 0 ]] && echo ""
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
    [[ $DO_JSON -eq 0 ]] && echo ""
    if [[ $DO_QUICK -eq 1 ]]; then exec "$REPO/doctor.sh" --quick; else exec "$REPO/doctor.sh"; fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────
if [[ $DO_JSON -eq 1 ]]; then
  python3 - "$crit" "$miss" "$softn" "$DO_QUICK" "${OC_DOCTOR_VER:-?}" "$REPO" <<'PY'
import json, sys
crit, miss, softn = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
quick = sys.argv[4] == "1"
ver, repo = sys.argv[5], sys.argv[6]
ready = crit == 0
print(json.dumps({
    "ok": ready,
    "ready": ready and miss == 0,
    "critical": crit,
    "optional": miss,
    "soft": softn,
    "quick": quick,
    "version": ver,
    "repo": repo,
    "verdict": (
        "ready" if ready and miss == 0 else
        "core_ready" if ready else
        "unhealthy"
    ),
}, indent=2))
PY
  exit $(( crit > 0 ? 1 : 0 ))
fi

sec "Summary"
if [[ $crit -eq 0 && $miss -eq 0 ]]; then
  printf "  ${c_g}${c_bold}Ready to code — everything checks out.${c_0}\n"
  [[ $softn -gt 0 ]] && info "$softn advisory note(s) (~) — not blocking"
elif [[ $crit -eq 0 ]]; then
  printf "  ${c_g}Core is ready.${c_0} ${c_y}$miss optional item(s) missing (see ⚠ above).${c_0}\n"
  [[ $softn -gt 0 ]] && info "$softn advisory note(s) (~) — latency/network, not install gaps"
  tip "oc secrets sync · oc setup (from the live install) · oc fix"
else
  printf "  ${c_r}$crit critical issue(s)${c_0}"
  [[ $miss -gt 0 ]] && printf " + ${c_y}$miss optional${c_0}"
  [[ $softn -gt 0 ]] && printf " · ${c_dim}$softn advisory${c_0}"
  printf " — fix ✗ items before coding.\n"
  tip "oc secrets sync            # allowlisted keys → .env"
  tip "oc setup                   # from the live ~/.config/opencode tree"
  tip "oc fix && oc validate && oc doctor"
fi
[[ $DO_JSON -eq 0 ]] && echo ""
exit $(( crit > 0 ? 1 : 0 ))
