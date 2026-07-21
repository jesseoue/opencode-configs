#!/usr/bin/env bash
# setup.sh — Idempotent OpenConfig setup (repo: opencode-configs)
#
# Gets this repo working as ~/.config/opencode.
# Safe to run multiple times. Won't clobber existing .env or working symlinks.
#
# Usage:
#   ./setup.sh              # full setup (idempotent)
#   ./setup.sh --check      # check only, don't change anything
#   ./setup.sh --force      # overwrite broken symlinks

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
LINK="${OC_CONFIG_LINK}"
OMO_TEAMS="$HOME/.omo/teams"
OC_VERSION="$(oc_versions_get opencode_configs 2>/dev/null || echo "1.5.0")"

CHECK_ONLY=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    --force) FORCE=true ;;
    --sync-env) SYNC_ENV=true ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

SYNC_ENV="${SYNC_ENV:-false}"

fix(){ $CHECK_ONLY && return 0; "$@"; }

# Colors (respect non-tty)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_p="\033[35m"
  c_bold="\033[1m"; c_dim="\033[2m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_p=""; c_bold=""; c_dim=""; c_0=""
fi
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }

oc_banner "$OC_VERSION" "OpenConfig setup — OpenCode · OpenRouter · OmO"

# ─── 1. OpenCode CLI ──────────────────────────────────────────────
echo "Step 1: OpenCode CLI"
if command -v opencode >/dev/null 2>&1; then
  ver="$(opencode --version 2>/dev/null | head -1)"
  ok "installed: $ver"
else
  bad "opencode CLI not found"
  echo ""
  echo "  Install it with:"
  echo "    curl -fsSL https://opencode.ai/install | bash"
  exit 1
fi
echo ""

# ─── 2. Config symlink ────────────────────────────────────────────
echo "Step 2: Config symlink (~/.config/opencode → this repo)"
mkdir -p "$(dirname "$LINK")"
if oc_link_points_to "$LINK" "$REPO" 2>/dev/null; then
  ok "symlink correct"
elif [ -L "$LINK" ]; then
  tgt="$(oc_readlink_abs "$LINK" 2>/dev/null || readlink "$LINK" || true)"
  opt "symlink points to $tgt (expected $REPO)"
  $FORCE && { fix ln -sfn "$REPO" "$LINK"; ok "symlink updated"; } || echo "  Run with --force to fix"
elif [ -d "$LINK" ]; then
  opt "$LINK is a real directory, not a symlink"
  if $FORCE; then
    oc_backup_path "$LINK" "config" >/dev/null
    fix ln -sfn "$REPO" "$LINK"
    ok "backed up to ${OC_BACKUP_PATH:-} and symlinked (sessions untouched at $OC_SESSIONS_DIR)"
  else
    echo "  Run with --force to replace (backs up first; never deletes sessions)"
  fi
elif [ ! -e "$LINK" ]; then
  fix ln -sfn "$REPO" "$LINK"
  ok "symlink created"
fi
# Explicit: never touch session store
if [[ -d "$OC_SESSIONS_DIR" ]]; then
  info "OpenCode sessions preserved at $OC_SESSIONS_DIR"
fi
echo ""

# ─── 3. API keys (.env) ───────────────────────────────────────────
echo "Step 3: API keys (.env)"
ENV_FILE="$REPO/.env"
# Never overwrite an existing .env — create from example only if missing, then
# merge any new keys from .env.example (empty values only for missing keys).
if ! $CHECK_ONLY; then
  created="$(oc_ensure_env_file "$ENV_FILE" "$REPO/.env.example" 2>/dev/null || true)"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  if [[ "$created" == "created" ]]; then
    ok ".env created from template (chmod 600)"
    echo ""
    echo "  Required keys (edit $ENV_FILE):"
    echo "    OPENROUTER_API_KEY  — https://openrouter.ai/keys (required)"
    echo "    EXA_API_KEY         — https://exa.ai (recommended, web search MCP)"
    echo "    CONTEXT7_API_KEY    — https://context7.com (recommended, docs MCP)"
  else
    ok ".env preserved (merged any new keys from .env.example; values never clobbered)"
  fi
  if [[ -z "$(oc_get_env_key "$ENV_FILE" OPENROUTER_API_KEY 2>/dev/null || true)" ]]; then
    opt "OPENROUTER_API_KEY unset — add it to $ENV_FILE"
  else
    ok "OPENROUTER_API_KEY set"
  fi
else
  if [[ -f "$ENV_FILE" ]]; then
    ok ".env exists"
  else
    opt ".env missing (would create from .env.example without overwriting later)"
  fi
fi
echo ""

# ─── 4. Team specs ────────────────────────────────────────────────
echo "Step 4: Team mode specs"
mkdir -p "$OMO_TEAMS"
# Prune stale/broken symlinks (e.g. retired build-crew)
for existing in "$OMO_TEAMS"/*; do
  [ -e "$existing" ] || [ -L "$existing" ] || continue
  name="$(basename "$existing")"
  if [ ! -d "$REPO/teams/$name" ]; then
    if [ -L "$existing" ]; then
      fix rm -f "$existing"
      ok "removed stale team link '$name'"
    else
      opt "orphan path $existing (not a symlink to this repo — leave alone)"
    fi
  fi
done
for spec_dir in "$REPO"/teams/*/; do
  [ -d "$spec_dir" ] || continue
  team_name="$(basename "$spec_dir")"
  team_link="$OMO_TEAMS/$team_name"
  target="${spec_dir%/}"
  if [ -L "$team_link" ] && [ "$(readlink "$team_link")" = "$target" -o "$(readlink "$team_link")" = "$spec_dir" ]; then
    ok "team '$team_name' provisioned"
  else
    fix ln -sfn "$target" "$team_link"
    ok "team '$team_name' symlinked"
  fi
done
echo ""

# ─── 5. LSP servers ───────────────────────────────────────────────
echo "Step 5: LSP servers"
need_install=false
command -v typescript-language-server >/dev/null 2>&1 && ok "typescript-language-server" || { opt "typescript-language-server not found"; need_install=true; }
command -v basedpyright-langserver >/dev/null 2>&1 && ok "basedpyright" || { opt "basedpyright not found"; need_install=true; }
command -v gopls >/dev/null 2>&1 && ok "gopls" || { opt "gopls not found"; need_install=true; }
if $need_install && ! $CHECK_ONLY; then
  echo "  Installing missing LSP servers..."
  command -v typescript-language-server >/dev/null 2>&1 || npm i -g typescript-language-server typescript 2>/dev/null || true
  command -v basedpyright-langserver >/dev/null 2>&1 || pip install basedpyright 2>/dev/null || true
  command -v gopls >/dev/null 2>&1 || go install golang.org/x/tools/gopls@latest 2>/dev/null || true
fi
echo ""

# ─── 5b. CodeGraph (OmO code intelligence) ────────────────────────
echo "Step 5b: CodeGraph"
CG_BIN="${HOME}/.omo/codegraph/bin/codegraph"
if [[ -x "$CG_BIN" ]]; then
  ok "codegraph $($CG_BIN --version 2>/dev/null | head -1 | tr -d '\r')"
elif [[ -x "${HOME}/.omo/codegraph/bin/codegraph" ]]; then
  ok "codegraph present"
else
  opt "codegraph binary missing at ~/.omo/codegraph/bin/codegraph"
  if ! $CHECK_ONLY; then
    # OmO auto_provision on first session; try CLI install if available via bunx
    info "Will auto-provision on first OpenCode/OmO session (codegraph.auto_provision=true)"
  fi
fi
# Ensure config does not point at a non-default broken install_dir
python3 - "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
repo=sys.argv[1]
p=os.path.join(repo,"oh-my-openagent.json")
omo=json.load(open(p))
cg=omo.get("codegraph") or {}
bad=cg.get("install_dir")
if bad and ("/.cache/opencode/codegraph" in str(bad) or str(bad).startswith("~/.cache")):
    print(f"  ⚠ codegraph.install_dir={bad!r} is wrong — OmO default is ~/.omo/codegraph")
elif cg.get("enabled") is False:
    print("  ⚠ codegraph.enabled is false")
else:
    print("  ✓ codegraph config OK (enabled, default ~/.omo/codegraph)")
PY
echo ""

# ─── 6. Formatters ────────────────────────────────────────────────
echo "Step 6: Formatters"
need_install=false
command -v prettier >/dev/null 2>&1 && ok "prettier" || { opt "prettier not found"; need_install=true; }
command -v ruff >/dev/null 2>&1 && ok "ruff" || { opt "ruff not found"; need_install=true; }
if $need_install && ! $CHECK_ONLY; then
  echo "  Installing missing formatters..."
  command -v prettier >/dev/null 2>&1 || npm i -g prettier 2>/dev/null || true
  command -v ruff >/dev/null 2>&1 || pip install ruff 2>/dev/null || true
fi
echo ""

# ─── 7. Tmux + Ghostty + Zshrc ────────────────────────────────
echo "Step 7: Terminal configs"
if command -v tmux >/dev/null 2>&1; then
  TMUX_CONF="$HOME/.tmux.conf"
  if [ -L "$TMUX_CONF" ] && [ "$(readlink "$TMUX_CONF")" = "$REPO/tmux.conf" ]; then
    ok "tmux.conf symlinked"
  elif [ -f "$TMUX_CONF" ] || [ -L "$TMUX_CONF" ]; then
    opt "tmux.conf exists (not our symlink — run --force to replace; backs up first)"
    if $FORCE; then
      oc_backup_path "$TMUX_CONF" "tmux" >/dev/null
      fix ln -sfn "$REPO/tmux.conf" "$TMUX_CONF"
      ok "tmux.conf symlinked (backup → ${OC_BACKUP_PATH:-})"
    fi
  else
    fix ln -sfn "$REPO/tmux.conf" "$TMUX_CONF"
    ok "tmux.conf symlinked"
  fi
else
  opt "tmux not installed (team mode tmux_visualization won't work)"
  echo "  Install: brew install tmux"
fi
echo ""

# ─── Ghostty config (optional) ───────────────────────────────
if [[ -d "$HOME/.config/ghostty" ]]; then
  GHOSTTY_CONF="$HOME/.config/ghostty/config"
  if [ -L "$GHOSTTY_CONF" ] && [ "$(readlink "$GHOSTTY_CONF")" = "$REPO/ghostty.conf" ]; then
    ok "ghostty.conf symlinked"
  elif [ -f "$GHOSTTY_CONF" ] || [ -L "$GHOSTTY_CONF" ]; then
    opt "ghostty config exists (not our symlink — run --force to replace; backs up first)"
    if $FORCE; then
      oc_backup_path "$GHOSTTY_CONF" "ghostty" >/dev/null
      fix ln -sfn "$REPO/ghostty.conf" "$GHOSTTY_CONF"
      ok "ghostty.conf symlinked (backup → ${OC_BACKUP_PATH:-})"
    fi
  else
    fix ln -sfn "$REPO/ghostty.conf" "$GHOSTTY_CONF"
    ok "ghostty.conf symlinked"
  fi
else
  info "Ghostty not detected — skip ghostty.conf"
fi
echo ""

# ─── Zshrc snippet (idempotent — no duplicate source lines) ──
echo "Step 7b: zshrc snippet"
if ! $CHECK_ONLY; then
  msg="$(oc_ensure_zshrc_snippet "$HOME/.zshrc")"
  ok "$msg"
else
  if [ -f "$HOME/.zshrc" ] && grep -qF 'source ~/.config/opencode/zshrc.snippet' "$HOME/.zshrc" 2>/dev/null; then
    if grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$HOME/.zshrc" 2>/dev/null; then
      opt "zshrc sources snippet AND has inline opencode() — re-run without --check to strip duplicate"
    else
      ok "zshrc snippet already sourced (canonical)"
    fi
  elif oc_zshrc_inline_stale "$HOME/.zshrc" 2>/dev/null; then
    opt "zshrc has stale inline opencode() (missing telemetry) — re-run without --check to migrate"
  elif [ -f "$HOME/.zshrc" ] && grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$HOME/.zshrc" 2>/dev/null; then
    ok "zshrc has inline opencode() (snippet source not required)"
  elif [ -f "$HOME/.zshrc" ] && grep -qE 'zshrc\.snippet' "$HOME/.zshrc" 2>/dev/null; then
    opt "zshrc has a non-canonical snippet source — re-run without --check to normalize"
  else
    opt "zshrc missing snippet — re-run without --check to add it"
  fi
fi
echo ""

# ─── Projects directory (oc new home) ───────────────────────────
echo "Step 7c: Projects directory"
if ! $CHECK_ONLY; then
  PROJECTS_DIR="$(oc_ensure_projects_dir)"
  ok "projects → $PROJECTS_DIR"
  # Persist default into .env when unset so paths stay consistent
  if [[ -f "$REPO/.env" ]]; then
    existing_pd="$(oc_get_env_key "$REPO/.env" OC_PROJECTS_DIR 2>/dev/null || true)"
    if [[ -z "$existing_pd" ]]; then
      oc_set_env_key "$REPO/.env" OC_PROJECTS_DIR "$PROJECTS_DIR"
      ok "wrote OC_PROJECTS_DIR to .env"
    fi
  fi
else
  info "projects would be → $(oc_projects_dir)"
fi
echo ""

# ─── 8. Sync env from secrets manager (optional) ───────────────
# NEVER dump a whole Infisical/Doppler project into OpenConfig .env —
# that spreads company secrets into the public config tree. Import
# allowlisted OpenConfig keys only (see OC_ENV_ALLOWLIST).
if $SYNC_ENV; then
  echo "Step 8: Sync allowlisted .env keys from secrets manager"
  if command -v infisical >/dev/null 2>&1 && [[ -n "${INFISICAL_DIR:-}" ]]; then
    TMP_FILE="$(mktemp)"
    INFISICAL_ENV="${INFISICAL_ENV:-prod}"
    ( cd "$INFISICAL_DIR" && infisical export --env="$INFISICAL_ENV" --format=dotenv --silent 2>/dev/null > "$TMP_FILE" )
    perl -i -pe "s/^([A-Z0-9_]+)='([^'\n]*)'$/\$1=\$2/g" "$TMP_FILE"
    if [[ -f "$REPO/.env" ]]; then
      oc_backup_copy "$REPO/.env" "env" >/dev/null || true
    fi
    imported="$(oc_import_allowlisted_dotenv "$TMP_FILE" "$REPO/.env" 2>/dev/null || true)"
    OR_KEY="$(oc_get_env_key "$REPO/.env" OPENROUTER_API_KEY 2>/dev/null || true)"
    if [[ -n "$OR_KEY" ]]; then
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $OR_KEY" \
        -H "Content-Type: application/json" \
        -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"ping"}],"max_tokens":16}' \
        https://openrouter.ai/api/v1/chat/completions 2>/dev/null)
      if [[ "$HTTP_CODE" = "200" ]]; then
        ok ".env allowlisted keys from Infisical (verified HTTP 200)${imported:+ · $imported}"
      else
        bad "OPENROUTER_API_KEY verification failed (HTTP $HTTP_CODE)"
      fi
    else
      bad "OPENROUTER_API_KEY not found in Infisical export (allowlist import)"
    fi
    rm -f "$TMP_FILE"
  elif command -v doppler >/dev/null 2>&1; then
    TMP_FILE="$(mktemp)"
    if [[ -f "$REPO/.env" ]]; then
      oc_backup_copy "$REPO/.env" "env" >/dev/null || true
    fi
    if doppler secrets download --no-file --format=env > "$TMP_FILE" 2>/dev/null; then
      imported="$(oc_import_allowlisted_dotenv "$TMP_FILE" "$REPO/.env" 2>/dev/null || true)"
      ok ".env allowlisted keys from Doppler${imported:+ · $imported}"
    else
      bad "Doppler download failed"
    fi
    rm -f "$TMP_FILE"
  else
    opt "No secrets manager found (install Infisical or Doppler, or set keys manually)"
    echo "  Infisical:  curl -sL https://infisical.com/install.sh | bash"
    echo "  Doppler:    brew install doppler"
    echo "  Note: sync imports OpenConfig allowlisted keys only — never the full vault."
  fi
  echo ""
fi


# ─── 8b. Plugin platform binary ────────────────────────────────
# The oh-my-openagent plugin needs a platform-specific optionalDependency.
# Pre-install it into OpenCode's plugin cache so runtime resolution is instant.
# bunfig.toml trusts lifecycle scripts, but do NOT run postinstall.mjs here —
# it calls invalidateOpenCodePluginCache() and deletes this cache directory.
if ! $CHECK_ONLY; then
  # Derive version from the pinned plugin in opencode.json (e.g. oh-my-openagent@4.16.3)
  PLUGIN_VER="$(python3 -c "import json; p=[x for x in json.load(open('$REPO/opencode.json')).get('plugin',[]) if 'oh-my-openagent@' in x]; print(p[0].split('@',1)[1] if p else '')" 2>/dev/null || true)"
  if [[ -z "$PLUGIN_VER" ]]; then
    PLUGIN_VER="$(npm view oh-my-openagent version 2>/dev/null || echo "4.19.0")"
  fi
  PLUGIN_CACHE="$HOME/.cache/opencode/packages/oh-my-openagent@${PLUGIN_VER}"
  PLATFORM_PKG=""
  
  # Detect platform
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PLATFORM_PKG="oh-my-openagent-darwin-arm64" ;;
    Darwin-x86_64) PLATFORM_PKG="oh-my-openagent-darwin-x64" ;;
    Linux-x86_64)  PLATFORM_PKG="oh-my-openagent-linux-x64" ;;
    Linux-aarch64) PLATFORM_PKG="oh-my-openagent-linux-arm64" ;;
  esac
  
  if [[ -n "$PLATFORM_PKG" ]]; then
    if [[ -d "$PLUGIN_CACHE/node_modules/$PLATFORM_PKG" ]]; then
      ok "platform binary present ($PLUGIN_VER)"
    else
      # Cache missing or binary not installed — pre-install both packages from npm registry
      info "Installing from npm: oh-my-openagent@$PLUGIN_VER + $PLATFORM_PKG@$PLUGIN_VER → $PLUGIN_CACHE"
      mkdir -p "$PLUGIN_CACHE"
      cat > "$PLUGIN_CACHE/package.json" <<PKGJSON
{
  "name": "oh-my-openagent-cache",
  "private": true,
  "dependencies": {
    "oh-my-openagent": "$PLUGIN_VER",
    "$PLATFORM_PKG": "$PLUGIN_VER"
  }
}
PKGJSON
      cp "$REPO/bunfig.toml" "$PLUGIN_CACHE/bunfig.toml" 2>/dev/null
      ( cd "$PLUGIN_CACHE" && bun install 2>/dev/null ) && ok "plugin + platform binary installed ($PLUGIN_VER)" || opt "install failed (opencode will use runtime fallback)"
      # NOTE: Do NOT run postinstall.mjs from the cache — it calls invalidateOpenCodePluginCache()
      # which deletes the cache directory itself. Just verify the binary exists.
      if [[ -f "$PLUGIN_CACHE/node_modules/$PLATFORM_PKG/bin/oh-my-openagent.js" ]] \
        || [[ -f "$PLUGIN_CACHE/node_modules/$PLATFORM_PKG/bin/oh-my-opencode.js" ]]; then
        ok "platform binary verified"
      else
        opt "platform binary not found after install (opencode will use runtime fallback)"
      fi
    fi
  fi
fi
# ─── 8c. @ast-grep/cli native binary ───────────────────────────
# Global npm @ast-grep/cli ships JS shims for `ast-grep`/`sg`. Its postinstall
# replaces those shims with the native binary from the platform optionalDep.
# If postinstall was skipped, every invocation prints:
#   [warn] postinstall script did not run; falling back to runtime binary resolution.
# (oh-my-openagent doctor probes sg/ast-grep, so the warn shows up there too.)
if ! $CHECK_ONLY; then
  AST_GREP_CLI=""
  if command -v npm >/dev/null 2>&1; then
    AST_GREP_CLI="$(npm root -g 2>/dev/null)/@ast-grep/cli"
  fi
  if [[ -f "${AST_GREP_CLI}/postinstall.js" && -e "${AST_GREP_CLI}/ast-grep" ]]; then
    if head -1 "${AST_GREP_CLI}/ast-grep" 2>/dev/null | grep -q node; then
      info "Running @ast-grep/cli postinstall (JS shim → native binary)..."
      if ( cd "$AST_GREP_CLI" && node postinstall.js ); then
        ok "ast-grep native binary installed"
      else
        opt "ast-grep postinstall failed (sg/ast-grep will warn on each run)"
      fi
    else
      ok "ast-grep native binary present"
    fi
  fi
fi
echo ""
# ─── 9. Verify ────────────────────────────────────────────────────
echo "Step 9: Verification"
# Scrub install/runtime junk OpenCode may have dropped into the config dir
if ! $CHECK_ONLY; then
  oc_scrub_config_strays "$REPO" >/dev/null
  [[ -n "${OC_SCRUBBED:-}" ]] && ok "removed config strays: $OC_SCRUBBED"
fi
if [ -x "$REPO/validate.sh" ]; then
  "$REPO/validate.sh" >/dev/null 2>&1 && ok "validate.sh passes" || bad "validate.sh failed"
fi
if [ -x "$REPO/doctor.sh" ] && ! $CHECK_ONLY; then
  echo ""
  echo "Running doctor.sh..."
  "$REPO/doctor.sh" 2>&1 || true
fi

echo ""
echo -e "${c_g}Setup complete.${c_0}"
$CHECK_ONLY && echo "Run without --check to apply fixes."
exit 0
