#!/usr/bin/env bash
# locate.sh — Discover where OpenConfig / OpenCode pieces live (read-only).
#
# Searches the filesystem for the config repo, CLI, symlinks, env keys (presence
# only — never prints secrets), projects home, terminals, teams, caches, and
# leftover copies. Safe to run anytime; writes nothing.
#
# Usage:
#   ./locate.sh                 human report
#   ./locate.sh --json          machine-readable
#   ./locate.sh --search        also scan common leftover paths
#   oc locate [--json|--search]
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

JSON=0
SEARCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --search) SEARCH=1; shift ;;
    --no-search) SEARCH=0; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
done

LINK="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
SESSIONS="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
BACKUP="${OC_BACKUP_ROOT:-$HOME/.opencode-backups}"
OMO_TEAMS="${OMO_TEAMS_DIR:-$HOME/.omo/teams}"
TMUX_CONF="${HOME}/.tmux.conf"
GHOSTTY_CONF="${HOME}/.config/ghostty/config"
ZSHRC="${HOME}/.zshrc"

if [[ -t 1 && -z "${NO_COLOR:-}" && $JSON -eq 0 ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_dim="\033[2m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_dim=""; c_0=""
fi
ok(){   printf "  ${c_g}✓${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }
warn(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){  printf "  ${c_r}✗${c_0} %s\n" "$*"; }
sec(){  printf "\n${c_b}== %s ==${c_0}\n" "$*"; }

# ── Resolve CLI ──
OPENCODE_BIN=""
if command -v opencode >/dev/null 2>&1; then
  OPENCODE_BIN="$(command -v opencode)"
elif [[ -x "$HOME/.opencode/bin/opencode" ]]; then
  OPENCODE_BIN="$HOME/.opencode/bin/opencode"
fi
OPENCODE_VER=""
if [[ -n "$OPENCODE_BIN" ]]; then
  OPENCODE_VER="$("$OPENCODE_BIN" --version 2>/dev/null | head -1 || true)"
fi

# ── Link state ──
LINK_STATE="missing"
LINK_TGT=""
if [[ -L "$LINK" ]]; then
  LINK_TGT="$(oc_readlink_abs "$LINK" 2>/dev/null || readlink "$LINK" || true)"
  if oc_link_points_to "$LINK" "$REPO"; then
    LINK_STATE="ok"
  else
    LINK_STATE="wrong"
  fi
elif [[ -d "$LINK" ]]; then
  LINK_STATE="real_dir"
elif [[ -e "$LINK" ]]; then
  LINK_STATE="other"
fi

# ── Env keys (presence only) ──
ENV_FILE="$REPO/.env"
ENV_EXISTS=0
[[ -f "$ENV_FILE" ]] && ENV_EXISTS=1
env_has() {
  [[ $ENV_EXISTS -eq 1 ]] || return 1
  local v
  v="$(oc_get_env_key "$ENV_FILE" "$1" 2>/dev/null || true)"
  [[ -n "$v" ]]
}
KEYS_SET=()
KEYS_MISSING=()
for k in OPENROUTER_API_KEY OPENAI_API_KEY EXA_API_KEY CONTEXT7_API_KEY OC_PROJECTS_DIR; do
  if env_has "$k"; then KEYS_SET+=("$k"); else KEYS_MISSING+=("$k"); fi
done

PROJECTS_DIR="$(oc_projects_dir 2>/dev/null || echo "$HOME/Projects")"
DEFAULT_PROFILE="$(oc_default_profile 2>/dev/null || echo high)"
DEFAULT_WORKSPACE_NAME="$(oc_default_workspace_name 2>/dev/null || echo workspace)"
LAUNCH_WORKSPACE="${PROJECTS_DIR}/${DEFAULT_WORKSPACE_NAME}"

# ── Terminal links ──
tmux_state="missing"
if [[ -L "$TMUX_CONF" ]]; then
  if oc_link_points_to "$TMUX_CONF" "$REPO/tmux.conf"; then tmux_state="ok"
  else tmux_state="wrong"; fi
elif [[ -e "$TMUX_CONF" ]]; then tmux_state="file"
fi
ghostty_state="missing"
if [[ -L "$GHOSTTY_CONF" ]]; then
  if oc_link_points_to "$GHOSTTY_CONF" "$REPO/ghostty.conf"; then ghostty_state="ok"
  else ghostty_state="wrong"; fi
elif [[ -e "$GHOSTTY_CONF" ]]; then ghostty_state="file"
fi

zsh_state="missing"
if [[ -f "$ZSHRC" ]]; then
  if grep -qE 'opencode-configs/zshrc\.snippet|function opencode\(|opencode\(\)|OpenConfig' "$ZSHRC" 2>/dev/null; then
    zsh_state="ok"
  else
    zsh_state="no_snippet"
  fi
fi

# ── Plugin pin / cache ──
PIN="$(python3 -c "import json;p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my' in x];print(p[0] if p else '')" 2>/dev/null || true)"
PIN_VER="${PIN##*@}"
CACHE_HIT=0
[[ -n "$PIN_VER" && -d "$CACHE/packages/oh-my-openagent@$PIN_VER" ]] && CACHE_HIT=1

# ── Teams ──
TEAM_OK=0
TEAM_TOTAL=0
if [[ -d "$REPO/teams" ]]; then
  for d in "$REPO"/teams/*/; do
    [[ -d "$d" ]] || continue
    TEAM_TOTAL=$((TEAM_TOTAL + 1))
    name="$(basename "$d")"
    if [[ -L "$OMO_TEAMS/$name" ]] && oc_link_points_to "$OMO_TEAMS/$name" "${d%/}"; then
      TEAM_OK=$((TEAM_OK + 1))
    elif [[ -L "$OMO_TEAMS/$name" ]]; then
      : # wrong
    fi
  done
fi

# ── Leftover search ──
LEFTOVERS=()
if [[ $SEARCH -eq 1 ]]; then
  candidates=(
    "$HOME/.opencode"
    "$HOME/opencode-configs"
    "$HOME/.opencode-config"
    "$HOME/Library/Application Support/opencode"
    "$HOME/Library/Preferences/opencode"
  )
  for c in "${candidates[@]}"; do
    [[ -e "$c" ]] || continue
    if oc_same_path "$c" "$REPO" 2>/dev/null; then continue; fi
    if [[ "$c" == "$HOME/.opencode" ]] && oc_is_cli_install_dir "$c" 2>/dev/null; then
      continue
    fi
    LEFTOVERS+=("$c")
  done
fi

# ── Repo strays ──
STRAYS=()
for name in node_modules package.json .omo .sisyphus .codegraph command; do
  [[ -e "$REPO/$name" || -L "$REPO/$name" ]] && STRAYS+=("$name")
done

# ── JSON or human ──
if [[ $JSON -eq 1 ]]; then
  export OC_LOCATE_REPO="$REPO" OC_LOCATE_LINK="$LINK" OC_LOCATE_LINK_STATE="$LINK_STATE" \
    OC_LOCATE_LINK_TGT="${LINK_TGT:-}" OC_LOCATE_BIN="$OPENCODE_BIN" OC_LOCATE_VER="$OPENCODE_VER" \
    OC_LOCATE_ENV="$ENV_EXISTS" OC_LOCATE_PROJECTS="$PROJECTS_DIR" OC_LOCATE_PROFILE="$DEFAULT_PROFILE" \
    OC_LOCATE_TMUX="$tmux_state" OC_LOCATE_GHOSTTY="$ghostty_state" OC_LOCATE_ZSH="$zsh_state" \
    OC_LOCATE_PIN="$PIN" OC_LOCATE_CACHE_HIT="$CACHE_HIT" \
    OC_LOCATE_TEAM_OK="$TEAM_OK" OC_LOCATE_TEAM_TOTAL="$TEAM_TOTAL" \
    OC_LOCATE_SESSIONS="$SESSIONS" OC_LOCATE_CACHE="$CACHE" OC_LOCATE_BACKUP="$BACKUP" \
    OC_LOCATE_KEYS_SET="${KEYS_SET[*]-}" OC_LOCATE_KEYS_MISSING="${KEYS_MISSING[*]-}" \
    OC_LOCATE_LEFTOVERS="${LEFTOVERS[*]-}" OC_LOCATE_STRAYS="${STRAYS[*]-}"
  python3 <<'PY'
import json, os
def split(s):
    s = (s or "").strip()
    return [x for x in s.split() if x] if s else []
out = {
  "repo": os.environ.get("OC_LOCATE_REPO", ""),
  "config_link": {
    "path": os.environ.get("OC_LOCATE_LINK", ""),
    "state": os.environ.get("OC_LOCATE_LINK_STATE", ""),
    "target": os.environ.get("OC_LOCATE_LINK_TGT", "") or None,
  },
  "opencode_cli": {
    "bin": os.environ.get("OC_LOCATE_BIN", "") or None,
    "version": os.environ.get("OC_LOCATE_VER", "") or None,
  },
  "env": {
    "exists": os.environ.get("OC_LOCATE_ENV") == "1",
    "keys_set": split(os.environ.get("OC_LOCATE_KEYS_SET")),
    "keys_missing": split(os.environ.get("OC_LOCATE_KEYS_MISSING")),
  },
  "projects_dir": os.environ.get("OC_LOCATE_PROJECTS", ""),
  "default_profile": os.environ.get("OC_LOCATE_PROFILE", ""),
  "tmux": os.environ.get("OC_LOCATE_TMUX", ""),
  "ghostty": os.environ.get("OC_LOCATE_GHOSTTY", ""),
  "zshrc": os.environ.get("OC_LOCATE_ZSH", ""),
  "plugin_pin": os.environ.get("OC_LOCATE_PIN", "") or None,
  "plugin_cache_hit": os.environ.get("OC_LOCATE_CACHE_HIT") == "1",
  "teams": {
    "ok": int(os.environ.get("OC_LOCATE_TEAM_OK") or 0),
    "total": int(os.environ.get("OC_LOCATE_TEAM_TOTAL") or 0),
  },
  "sessions_dir": os.environ.get("OC_LOCATE_SESSIONS", ""),
  "cache_dir": os.environ.get("OC_LOCATE_CACHE", ""),
  "backup_dir": os.environ.get("OC_LOCATE_BACKUP", ""),
  "leftovers": split(os.environ.get("OC_LOCATE_LEFTOVERS")),
  "repo_strays": split(os.environ.get("OC_LOCATE_STRAYS")),
  "signature": None,
}
# Attach signature verify (optional)
import subprocess
try:
    r = subprocess.run(
        [os.path.join(os.environ.get("OC_LOCATE_REPO", ""), "signature.sh"), "--json"],
        capture_output=True, text=True,
    )
    if r.stdout.strip():
        out["signature"] = json.loads(r.stdout)
except Exception:
    pass
print(json.dumps(out, indent=2))
PY
  exit 0
fi

# Human report
printf "\n${c_b}OpenConfig locate${c_0} ${c_dim}(read-only — nothing written)${c_0}\n"

sec "Config repo"
ok "repo: $REPO"
case "$LINK_STATE" in
  ok) ok "link: $LINK → $REPO" ;;
  wrong) warn "link: $LINK → ${LINK_TGT:-?} (expected $REPO)" ;;
  real_dir) warn "link: $LINK is a real directory (not a symlink)" ;;
  missing) bad "link: $LINK missing" ;;
  *) warn "link: $LINK state=$LINK_STATE" ;;
esac

# Project identity
if out="$(oc_verify_signature "$REPO" 2>/dev/null)"; then
  _sid="${out#ok|}"; _sid="${_sid%%|*}"
  _fp="${out##*|}"
  ok "signature: ${_sid} (${_fp}...)"
  unset _sid _fp
else
  bad "signature: ${out#fail|}"
  info "fix: oc signature --refresh   or clone the real repo"
fi

sec "OpenCode CLI"
if [[ -n "$OPENCODE_BIN" ]]; then
  ok "bin: $OPENCODE_BIN${OPENCODE_VER:+ ($OPENCODE_VER)}"
else
  bad "opencode CLI not found on PATH or ~/.opencode/bin"
fi

sec "API keys (.env presence only — values never printed)"
if [[ $ENV_EXISTS -eq 0 ]]; then
  bad ".env missing at $ENV_FILE"
else
  ok ".env present (perms $(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || '?'))"
  # nounset-safe: empty "${arr[@]}" errors under set -u; ${arr[@]:-} prints a blank "unset".
  if ((${#KEYS_SET[@]})); then
    for k in "${KEYS_SET[@]}"; do ok "$k set"; done
  fi
  if ((${#KEYS_MISSING[@]})); then
    for k in "${KEYS_MISSING[@]}"; do
      if [[ "$k" == "OC_PROJECTS_DIR" ]]; then info "$k unset (defaults via projects.json)"; else warn "$k unset"; fi
    done
  fi
fi

sec "Projects"
ok "home: $PROJECTS_DIR$([ -d "$PROJECTS_DIR" ] && echo '' || echo ' (missing — oc projects --ensure)')"
info "default profile: $DEFAULT_PROFILE"
info "launch workspace: $LAUNCH_WORKSPACE"
if [[ -d "$LAUNCH_WORKSPACE" ]]; then
  if [[ -f "$LAUNCH_WORKSPACE/AGENTS.md" && -f "$LAUNCH_WORKSPACE/opencode.json" ]]; then
    ok "workspace scaffold present (AGENTS.md + opencode.json)"
  else
    warn "workspace dir exists but scaffold incomplete (oc launch will repair)"
  fi
else
  info "workspace not created yet (oc launch / oc_ensure_launch_workspace)"
fi

sec "Terminals & shell"
case "$tmux_state" in
  ok) ok "tmux.conf → repo" ;;
  wrong) warn "tmux.conf points elsewhere" ;;
  file) info "tmux.conf is a regular file (not repo symlink)" ;;
  *) info "tmux.conf not linked" ;;
esac
case "$ghostty_state" in
  ok) ok "ghostty config → repo" ;;
  wrong) warn "ghostty config points elsewhere" ;;
  file) info "ghostty config is a regular file" ;;
  *) info "ghostty config not linked" ;;
esac
case "$zsh_state" in
  ok) ok "zshrc has OpenConfig / opencode() integration" ;;
  no_snippet) warn "zshrc present but no OpenConfig snippet" ;;
  *) info "zshrc missing" ;;
esac

sec "Plugin & teams"
if [[ -n "$PIN" ]]; then
  if [[ $CACHE_HIT -eq 1 ]]; then ok "pin $PIN (cache hit)"; else warn "pin $PIN (cache miss)"; fi
else
  bad "no oh-my-openagent pin in opencode.json"
fi
ok "teams linked: $TEAM_OK / $TEAM_TOTAL → $OMO_TEAMS"

sec "Runtime paths"
info "sessions: $SESSIONS$([ -d "$SESSIONS" ] && echo '' || echo ' (absent)')"
info "cache:    $CACHE"
info "backups:  $BACKUP"

if [[ ${#STRAYS[@]} -gt 0 ]]; then
  sec "Repo strays (config-only — should be empty)"
  for s in "${STRAYS[@]}"; do warn "$REPO/$s"; done
  info "scrub: oc cleanup --yes   or   oc heal"
fi

if [[ $SEARCH -eq 1 ]]; then
  sec "Leftover search"
  if [[ ${#LEFTOVERS[@]} -eq 0 ]]; then
    ok "no leftover config copies in common locations"
  else
    for L in "${LEFTOVERS[@]}"; do warn "found: $L"; done
    info "inspect then: oc cleanup --dry-run"
  fi
fi

sec "Next"
info "check everything:  oc test"
info "readiness:         oc check"
info "self-repair:       oc heal   (idempotent — skips clean steps)"
echo ""
