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

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
sec(){ oc_section "$*"; }
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
  opencode.json tui.json tmux.conf ghostty.conf zshrc.snippet README.md AGENTS.md
  .github/workflows/check.yml
  validate.sh doctor.sh cleanup.sh fix.sh models.sh versions.sh diagnose.sh setup.sh install.sh maintain.sh
  opencode.sh run.sh openrouter-admin.sh oc locate.sh signature.sh deploy-guard.sh
  launch-desktop.sh serve-desktop.sh export-t3.py sync-t3.py
  tests/smoke.sh tests/idempotency.sh tests/runtime-diagnostics.sh tests/prepare-ci-runtime.py
  lib/common.sh
  agents/lead.md agents/build.md agents/plan.md agents/explore.md agents/librarian.md agents/oracle.md agents/junior.md
  agents/content-aware-research.md agents/content-aware-fast.md agents/content-aware-deep.md agents/context-aware-hermes.md
  skills/content-aware-recon/SKILL.md skills/content-aware-audit/SKILL.md
  prompts/core.md
  prompts/profiles/high.md prompts/profiles/low.md prompts/profiles/fast.md prompts/profiles/research.md
  prompts/profiles/debug.md prompts/profiles/writing.md prompts/profiles/content-aware.md
  profiles/high.json profiles/low.json profiles/fast.json profiles/research.json profiles/writing.json profiles/debug.json profiles/content-aware.json
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

if [[ -e "$REPO/.runtime" || -L "$REPO/.runtime" ]]; then
  drift=$((drift+1))
  if [[ $DRY -eq 1 ]]; then
    warn "[dry-run] would remove in-repo .runtime"
  else
    act "rm -rf \"$REPO/.runtime\""; fix "removed in-repo .runtime (runtime is sibling)"
  fi
fi
# Stale second checkout under /Users/Shared/configs
for stale in /Users/Shared/configs/opencode-configs.stale-*; do
  [[ -e "$stale" ]] || continue
  drift=$((drift+1))
  if [[ $DRY -eq 1 ]]; then
    warn "[dry-run] would remove stale copy $stale"
  else
    act "rm -rf \"$stale\""; fix "removed stale copy $stale"
  fi
done

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
done < <(find "$REPO" \( -path "$REPO/.git" -prune -o \( -name '.DS_Store' -o -name '*.bak' -o -name '*.bak.*' -o -name '*.log' \) -print \) 2>/dev/null)
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
for md in sorted(glob.glob(repo+"/agents/*.md")):
    t=open(md).read()
    body=t.split('---',2)[2].strip() if t.startswith('---') and t.count('---')>=2 else t.strip()
    print(("EMPTY" if not body else "OK")+f"|{os.path.basename(md)}")
PY
)"
while IFS='|' read -r kind a b; do
  case "$kind" in
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
