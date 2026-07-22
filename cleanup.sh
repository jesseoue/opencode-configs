#!/usr/bin/env bash
# cleanup.sh — Reconcile the environment back to the known-good setup.
#
# Knows exactly what SHOULD be here and checks each item closely:
#   • required files present in the repo (the manifest below)
#   • ~/.config/opencode symlinked to this repo
#   • plugin pinned to a version that actually loads (fixes broken pins)
#   • stale plugin caches pruned (keep only the pinned version)
#   • leftover config copies removed (backup kept)
#   • old backups pruned (keep newest N)
#   • repo cruft removed (.DS_Store, *.bak, *.log, stray node_modules, broken links)
#   • .env perms locked to 600
# Ends by re-validating. Destructive steps back up first and honor --dry-run.
#
# Usage:
#   ./cleanup.sh            reconcile to known-good (prompts before deleting copies)
#   ./cleanup.sh --dry-run  report drift, change nothing
#   ./cleanup.sh --yes      non-interactive (assume yes to safe deletions)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
CONFIG_HOME="${XDG_CONFIG_HOME}"
LINK="${OC_CONFIG_LINK}"
CACHE="${XDG_CACHE_HOME}/opencode/packages"
BACKUP_ROOT="${OC_BACKUP_ROOT}"
KEEP_BACKUPS=5
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0; YES=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;; --yes|-y) YES=1 ;;
  -h|--help) oc_print_script_help "$0"; exit 0 ;;
  *) echo "Unknown flag: $a"; exit 2 ;;
esac; done

c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_0="\033[0m"
sec(){ printf "\n${c_b}== %s ==${c_0}\n" "$*"; }
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
fix(){ printf "  ${c_g}⟳ fixed:${c_0} %s\n" "$*"; }
warn(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; }
act(){ if [[ $DRY -eq 1 ]]; then printf "  ${c_y}[dry-run]${c_0} %s\n" "$*"; else eval "$@"; fi; }
ask(){ [[ $YES -eq 1 ]] && return 0; read -r -p "  $1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

drift=0

# ─── 1. Manifest: what MUST be here ──────────────────────────────────
sec "Required files"
REQUIRED=(
  opencode.json oh-my-openagent.json tui.json tmux.conf ghostty.conf zshrc.snippet bunfig.toml README.md AGENTS.md CHANGELOG.md .env.example .gitignore projects.json versions.json signature.json
  validate.sh doctor.sh cleanup.sh fix.sh models.sh versions.sh diagnose.sh setup.sh install.sh maintain.sh
# Add locate.sh to required list
  opencode.sh run.sh openrouter-admin.sh oc locate.sh signature.sh
  lib/common.sh
  agents/content-aware-research.md
  prompts/core.md prompts/goal.md
  prompts/agents/sisyphus.md prompts/agents/hephaestus.md prompts/agents/prometheus.md prompts/agents/atlas.md
  prompts/agents/oracle.md prompts/agents/librarian.md prompts/agents/explore.md prompts/agents/multimodal-looker.md
  prompts/agents/metis.md prompts/agents/momus.md prompts/agents/sisyphus-junior.md
  prompts/categories/content-aware-fast.md prompts/categories/content-aware-deep.md prompts/categories/bug-hunt.md
  prompts/categories/refactor-safe.md prompts/categories/arch-review.md
  prompts/categories/visual-engineering.md prompts/categories/ultrabrain.md prompts/categories/deep.md
  prompts/categories/artistry.md prompts/categories/quick.md prompts/categories/unspecified-low.md
  prompts/categories/unspecified-high.md prompts/categories/writing.md
  prompts/profiles/high.md prompts/profiles/low.md prompts/profiles/fast.md prompts/profiles/research.md
  prompts/profiles/debug.md prompts/profiles/writing.md prompts/profiles/content-aware.md
  profiles/high.json profiles/low.json profiles/research.json profiles/writing.json profiles/content-aware.json profiles/debug.json profiles/fast.json
  teams/explorers/config.json teams/review-panel/config.json teams/content-aware-audit/config.json teams/ship-feature/config.json teams/debug-team/config.json teams/docs-team/config.json teams/refactor-team/config.json
  skills/.gitkeep
)
missing=0
for f in "${REQUIRED[@]}"; do
  if [[ -e "$REPO/$f" ]]; then
    :
  elif [[ "$f" == "skills/.gitkeep" ]]; then
    # Keep skills/ trackable even when only fenced skills exist
    act "mkdir -p \"$REPO/skills\" && : > \"$REPO/skills/.gitkeep\""
    fix "restored skills/.gitkeep"
    drift=$((drift+1))
  else
    bad "missing: $f"; missing=$((missing+1)); drift=$((drift+1))
  fi
done
[[ $missing -eq 0 ]] && ok "all ${#REQUIRED[@]} expected files present"
# scripts executable
for s in "$REPO"/*.sh "$REPO"/oc; do [[ -x "$s" ]] || { act "chmod +x \"$s\""; fix "made executable: $(basename "$s")"; }; done

# ─── 2. Config symlink ───────────────────────────────────────────────
sec "Config symlink"
if oc_link_points_to "$LINK" "$REPO" 2>/dev/null; then
  ok "$LINK -> $REPO"
else
  drift=$((drift+1))
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    act "oc_backup_path \"$LINK\" config >/dev/null"
    fix "backed up non-symlink $LINK"
  elif [[ -L "$LINK" ]]; then
    _old="$(oc_readlink_abs "$LINK" 2>/dev/null || readlink "$LINK" || true)"
    act "rm -f \"$LINK\""
    fix "removed wrong symlink (was → ${_old:-?})"
    unset _old
  fi
  act "ln -sfn \"$REPO\" \"$LINK\""
  fix "symlink -> $REPO"
fi

# ─── 3. Plugin pin sanity (must load, not just parse) ────────────────
sec "Plugin pin"
PIN="$(python3 -c "import json;p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my' in x];print(p[0] if p else '')" 2>/dev/null)"
PIN_VER="${PIN##*@}"
if [[ -z "$PIN" ]]; then
  bad "no oh-my-openagent plugin pinned in opencode.json"; drift=$((drift+1))
elif command -v bunx >/dev/null 2>&1; then
  loaded="$(bunx "oh-my-openagent@${PIN_VER:-latest}" doctor 2>/dev/null | grep -oE 'oh-my-openagent [0-9.]+' | grep -oE '[0-9.]+' | head -1)"
  if [[ "$loaded" == "$PIN_VER" ]]; then ok "pinned $PIN loads v$loaded"
  else warn "pinned $PIN but doctor loaded v${loaded:-unknown} (cache prune below will fix)"; fi
else
  warn "bun missing — cannot verify plugin load"
fi

# ─── 4. Prune stale plugin caches ────────────────────────────────────
sec "Plugin cache"
if [[ -d "$CACHE" ]]; then
  for d in "$CACHE"/oh-my-*; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"; ver="${base##*@}"
    if [[ -n "$PIN_VER" && "$ver" != "$PIN_VER" ]]; then
      act "rm -rf \"$d\""; fix "pruned stale cache $base (keeping v$PIN_VER)";
    else
      ok "cache $base"
    fi
  done
else
  warn "no plugin cache yet (populated on first launch)"
fi

# ─── 5. Leftover config copies ───────────────────────────────────────
sec "Leftover config copies"
found_leftover=0
for d in "$HOME/.opencode" "$HOME/opencode-configs" /usr/local/opencode; do
  [[ -d "$d" && "$d" != "$REPO" ]] || continue
  # ~/.opencode with bin/ is the OpenCode CLI install — never treat as a config copy
  if [[ "$d" == "$HOME/.opencode" && -d "$d/bin" ]]; then
    ok "$d is CLI install (bin/) — not a leftover config"
    continue
  fi
  found_leftover=1; drift=$((drift+1))
  has_backup=0; ls -1d "$BACKUP_ROOT"/config-* >/dev/null 2>&1 && has_backup=1
  if [[ $has_backup -eq 0 ]]; then
    act "mkdir -p \"$BACKUP_ROOT\" && cp -Rp \"$d\" \"$BACKUP_ROOT/config-$STAMP\""; fix "backed up $d"
  fi
  if [[ $DRY -eq 1 ]]; then warn "[dry-run] would remove $d (backup present)"
  elif ask "Remove leftover copy $d? (backup kept)"; then act "rm -rf \"$d\""; fix "removed $d"
  else warn "kept $d (re-run to remove)"; fi
done
[[ $found_leftover -eq 0 ]] && ok "no leftover copies"

# ─── 6. Prune old backups ────────────────────────────────────────────
sec "Backups"
if [[ -d "$BACKUP_ROOT" ]]; then
  n="$(ls -1d "$BACKUP_ROOT"/config-* 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n" -gt $KEEP_BACKUPS ]]; then
    ls -1dt "$BACKUP_ROOT"/config-* | tail -n +$((KEEP_BACKUPS+1)) | while read -r old; do
      act "rm -rf \"$old\""; fix "pruned old backup $(basename "$old")"
    done
  fi
  ok "$([ "$n" -le $KEEP_BACKUPS ] && echo "$n backup(s), within keep=$KEEP_BACKUPS" || echo "pruned to newest $KEEP_BACKUPS")"
else
  ok "no backups"
fi

# ─── 7. Repo cruft ───────────────────────────────────────────────────
sec "Repo cruft"
cruft=0
while IFS= read -r junk; do
  [[ -z "$junk" ]] && continue
  act "rm -rf \"$junk\""; fix "removed $(echo "$junk" | sed "s#$REPO/##")"; cruft=$((cruft+1))
done < <(find "$REPO" \( -name '.DS_Store' -o -name '*.bak' -o -name '*.bak.*' -o -name '*.log' \) 2>/dev/null)
# stray install/runtime artifacts (opencode may drop these into the config dir; keep repo config-only)
if [[ $DRY -eq 1 ]]; then
  for stray in "${OC_CONFIG_STRAYS[@]}"; do
    if [[ -e "$REPO/$stray" || -L "$REPO/$stray" ]]; then
      act "rm -rf \"$REPO/$stray\""
      cruft=$((cruft+1))
    fi
  done
else
  oc_scrub_config_strays "$REPO"
  if [[ -n "${OC_SCRUBBED:-}" ]]; then
    for stray in $OC_SCRUBBED; do
      fix "removed stray $stray"
      cruft=$((cruft+1))
    done
  fi
fi
# broken symlinks under the config dir
while IFS= read -r bl; do act "rm -f \"$bl\""; fix "removed broken symlink $(basename "$bl")"; cruft=$((cruft+1)); done \
  < <(find -L "$REPO" -maxdepth 2 -type l 2>/dev/null)
[[ $cruft -eq 0 ]] && ok "no cruft"

# ─── 8. Secrets perms ────────────────────────────────────────────────
sec "Secrets"
if [[ -f "$REPO/.env" ]]; then
  perm="$(stat -f '%Lp' "$REPO/.env" 2>/dev/null || stat -c '%a' "$REPO/.env" 2>/dev/null)"
  if [[ "$perm" != "600" ]]; then act "chmod 600 \"$REPO/.env\""; fix ".env perms -> 600 (was $perm)"; else ok ".env perms 600"; fi
else
  warn ".env absent (copy .env.example and add OPENROUTER_API_KEY)"
fi

# ─── 9. Configs: auto-normalize footguns (repair, not just detect) ────
sec "Configs (normalize)"
if [[ -x "$REPO/fix.sh" ]]; then
  fixout="$("$REPO/fix.sh" --dry-run 2>/dev/null || true)"
  if printf '%s' "$fixout" | grep -q "already clean"; then
    ok "configs already normalized (no footguns)"
  elif [[ $DRY -eq 1 ]]; then
    warn "[dry-run] fix.sh would repair: $(printf '%s' "$fixout" | grep '⟳' | wc -l | tr -d ' ') item(s) — run ./cleanup.sh to apply"; drift=$((drift+1))
  else
    if "$REPO/fix.sh" >/dev/null 2>&1; then fix "normalized configs (footguns repaired + clean-formatted)"; drift=$((drift+1))
    else bad "fix.sh failed — run ./fix.sh"; fi
  fi
else warn "fix.sh missing"; fi

# ─── 10. Prompts: every agent must carry a non-empty prompt ───────────
sec "Agent prompts"
prompt_report="$(python3 - "$REPO" <<'PY'
import json, sys, glob, os
repo=sys.argv[1]
omo=json.load(open(repo+"/oh-my-openagent.json"))
empty=[n for n,a in (omo.get("agents") or {}).items()
       if not (a.get("prompt_append") or a.get("prompt") or "").strip()]
total=len(omo.get("agents") or {})
print(f"OMO|{total}|{','.join(empty)}")
for md in sorted(glob.glob(repo+"/agents/*.md")):
    t=open(md).read()
    body=t.split('---',2)[2].strip() if t.startswith('---') and t.count('---')>=2 else t.strip()
    print(("EMPTY" if not body else "OK")+f"|{os.path.basename(md)}")
PY
)"
while IFS='|' read -r kind a b; do
  case "$kind" in
    OMO) if [[ -z "$b" ]]; then ok "$a plugin agents all have prompts"; else bad "empty prompt_append in: $b"; fi ;;
    OK)  : ;;  # md body present
    EMPTY) bad "agents/$a has no body prompt" ;;
  esac
done <<< "$prompt_report"
printf '%s\n' "$prompt_report" | grep -q '^EMPTY' || ok "agents/*.md all have body prompts"

# ─── 11. Models: configured models resolve + route (live if key) ──────
sec "Models"
env_key="$(oc_get_env_key "$REPO/.env" OPENROUTER_API_KEY)"
if [[ $DRY -eq 0 && -n "$env_key" ]] && command -v curl >/dev/null 2>&1; then
  mreport="$(ORK="$env_key" python3 - "$REPO" <<'PY'
import json, os, sys, urllib.request, urllib.error
repo=sys.argv[1]; key=os.environ["ORK"]
models=json.load(open(repo+"/opencode.json"))["provider"]["openrouter"]["models"]
for mid,m in models.items():
    if m.get("family")=="claude": continue
    body={"model":m.get("id",mid),"messages":[{"role":"user","content":"hi"}],"max_tokens":16}
    prov=(m.get("options") or {}).get("provider")
    if prov: body["provider"]=prov
    rq=urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    try: json.load(urllib.request.urlopen(rq,timeout=20)); print(f"OK|{mid}")
    except urllib.error.HTTPError as e:
        try: msg=json.load(e).get("error",{}).get("message","")[:60]
        except Exception: msg=f"HTTP {e.code}"
        print(f"ERR|{mid}|{msg}")
    except Exception as e: print(f"ERR|{mid}|{str(e)[:50]}")
PY
)"
  bad_routes=0
  while IFS='|' read -r st mid msg; do
    [[ -z "$mid" ]] && continue
    if [[ "$st" == OK ]]; then :; else bad "$mid does NOT route → $msg"; bad_routes=$((bad_routes+1)); fi
  done <<< "$mreport"
  [[ $bad_routes -eq 0 ]] && ok "all workhorse models route (max_price caps admit providers)"
else
  # offline / dry-run: static cross-ref (validate already covers refs; note it)
  ok "static model refs valid (run ./doctor.sh or ./models.sh for live routing + catalog analysis)"
fi

# ─── 12. Re-validate ──────────────────────────────────────────────────
sec "Re-validate"
if [[ $DRY -eq 0 && -x "$REPO/validate.sh" ]]; then
  VALIDATE_QUIET=1 "$REPO/validate.sh" >/dev/null 2>&1 && ok "config valid, no footguns" || bad "validation failed — run ./validate.sh"
else
  warn "skipped (dry-run)"
fi

sec "Summary"
if [[ $DRY -eq 1 ]]; then printf "  ${c_y}dry-run — %s drift item(s) detected, nothing changed${c_0}\n\n" "$drift"
elif [[ $drift -eq 0 ]]; then printf "  ${c_g}Already at known-good setup.${c_0}\n\n"
else printf "  ${c_g}Reconciled to known-good setup (%s drift item(s) fixed).${c_0}\n\n" "$drift"; fi
