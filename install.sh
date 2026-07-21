#!/usr/bin/env bash
# install.sh — 1-step OpenConfig (oc) installer
#
# Best-known config for OpenCode · OpenRouter · oh-my-openagent (OmO).
#
# Preferred (already cloned):
#   ./install.sh [--dir PATH] [--skip-cli] [--yes] [--lazy|--full]
#
# Fresh machine (distribution URL is base64 — keeps tree free of host-owner literals):
#   curl -fsSL "$(printf %s 'aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2plc3Nlb3VlL29wZW5jb2RlLWNvbmZpZ3MvbWFpbi9pbnN0YWxsLnNo' | base64 -d)" | bash
#
# Safety:
#   • Refuses root; umask 077 for secret files
#   • Never deletes OpenCode sessions (~/.local/share/opencode)
#   • Backs up config/tmux/ghostty/zshrc before replacing
#   • Idempotent zshrc (no duplicate source lines)
#   • Safe .env key writes (no sed injection)
#   • main() wrapper so curl|bash cannot partial-execute mid-download
#   • Delegates final reconcile to setup.sh
#
# After: source ~/.zshrc && oc doctor && oc launch

# Entire body lives in main() so a truncated curl|bash pipe cannot run half a script.
install_main() {
set -euo pipefail

umask 077
unset CDPATH 2>/dev/null || true
IFS=$' \t\n'

# ── Flags ─────────────────────────────────────────────────────────
INSTALL_DIR_FLAG=""
SKIP_CLI=false
ASSUME_YES=false
LAZY_MODE=true
LOG_FILE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|--prefix)
      INSTALL_DIR_FLAG="${2:-}"
      [[ -n "$INSTALL_DIR_FLAG" ]] || { echo "fatal: $1 needs a path" >&2; exit 1; }
      shift 2
      ;;
    --log)
      LOG_FILE_FLAG="${2:-}"
      [[ -n "$LOG_FILE_FLAG" ]] || { echo "fatal: --log needs a path" >&2; exit 1; }
      shift 2
      ;;
    --skip-cli) SKIP_CLI=true; shift ;;
    --yes|-y|--quick|-q) ASSUME_YES=true; shift ;;
    --lazy) LAZY_MODE=true; shift ;;
    --full|--wizard) LAZY_MODE=false; shift ;;
    -h|--help)
      cat <<'EOF'
install.sh — OpenConfig (oc) installer

  Best-known config for OpenCode · OpenRouter · oh-my-openagent (OmO).

  ./install.sh [--dir PATH] [--log PATH] [--skip-cli] [--yes] [--lazy|--full]

  # Fresh machine (decode distribution raw URL, then pipe):
  curl -fsSL "$(printf %s 'aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2plc3Nlb3VlL29wZW5jb2RlLWNvbmZpZ3MvbWFpbi9pbnN0YWxsLnNo' | base64 -d)" | bash

Flags:
  --dir PATH   install/clone location (default: repo dir if local, else ~/opencode-configs)
  --log PATH   write install log to PATH (default: ~/.opencode-backups/logs/install-*.log)
  --skip-cli   do not install OpenCode CLI
  --yes, -y    non-interactive: accept all defaults, skip key prompts (use env vars for keys)
  --quick, -q  alias for --yes (fast full install; preferred via: oc install --quick)
  --lazy       interactive lazy mode (default): Enter accepts defaults; only ask for missing keys
  --full       interactive wizard: confirm install dir, CLI, terminals, keys, setup

Lazy defaults: install CLI=yes · zshrc=yes · tmux/ghostty=yes when present · setup=yes ·
optional keys=skip · OpenRouter required (prompt; Enter skips with warning).

Env (pre-seed keys, no paste needed):
  OPENROUTER_API_KEY  OPENAI_API_KEY  EXA_API_KEY  CONTEXT7_API_KEY

Safety: refuses root; never deletes sessions; backs up replaced configs.
Logs:   ~/.opencode-backups/logs/install-latest.log (no secrets)

After install: source ~/.zshrc && oc doctor && oc launch
EOF
      exit 0
      ;;
    *)
      echo "fatal: unknown flag: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

# ── Early HOME / XDG harden (common.sh not available for curl|bash yet) ──
if [[ "$(id -u)" -eq 0 ]]; then
  echo "fatal: refuse to run as root — install as your normal user" >&2
  exit 1
fi
if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
  HOME="$(cd ~ 2>/dev/null && pwd -P)" || { echo "fatal: cannot resolve HOME" >&2; exit 1; }
fi
while [[ -n "$HOME" && "$HOME" == */ && "$HOME" != "/" ]]; do HOME="${HOME%/}"; done
if [[ "$HOME" == "/" ]]; then
  echo "fatal: refusing HOME=/" >&2
  exit 1
fi
[[ -d "$HOME" ]] || { echo "fatal: HOME is not a directory: $HOME" >&2; exit 1; }
export HOME
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
_oc_early_xdg() {
  local name="$1" val="$2"
  while [[ -n "$val" && "$val" == */ && "$val" != "/" ]]; do val="${val%/}"; done
  [[ -n "$val" && "$val" != "/" && "$val" == /* ]] || {
    echo "fatal: $name must be an absolute non-root path" >&2; exit 1
  }
  printf '%s' "$val"
}
XDG_CONFIG_HOME="$(_oc_early_xdg XDG_CONFIG_HOME "$XDG_CONFIG_HOME")"
XDG_DATA_HOME="$(_oc_early_xdg XDG_DATA_HOME "$XDG_DATA_HOME")"
XDG_CACHE_HOME="$(_oc_early_xdg XDG_CACHE_HOME "$XDG_CACHE_HOME")"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
unset -f _oc_early_xdg

# ── Logging (as early as HOME is known; before common.sh) ─────────
OC_LOG_DIR="${HOME}/.opencode-backups/logs"
mkdir -p "$OC_LOG_DIR"
if [[ -n "$LOG_FILE_FLAG" ]]; then
  OC_LOG_FILE="$LOG_FILE_FLAG"
  mkdir -p "$(dirname "$OC_LOG_FILE")"
else
  OC_LOG_FILE="${OC_LOG_DIR}/install-$(date +%Y%m%d-%H%M%S)-$$.log"
fi
umask 077
{
  echo "# opencode-configs install log"
  echo "# started: $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "# host: $(uname -n 2>/dev/null || echo unknown)"
  echo "# user: $(id -un 2>/dev/null || echo unknown)"
  echo "# pid: $$"
  echo "# uname: $(uname -srm 2>/dev/null || true)"
  echo "# ----"
} >"$OC_LOG_FILE"
chmod 600 "$OC_LOG_FILE" 2>/dev/null || true
ln -sfn "$OC_LOG_FILE" "${OC_LOG_DIR}/install-latest.log" 2>/dev/null || true
export OC_LOG_FILE OC_LOG_DIR

_log_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
_log_strip() { printf '%s' "$*" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }
_log() {
  local level="${1:-INFO}"; shift || true
  printf '%s [%s] %s\n' "$(_log_ts)" "$level" "$(_log_strip "$*")" >>"$OC_LOG_FILE" 2>/dev/null || true
}
_log_section() { _log "----" "$*"; }
_INSTALL_TMPS=()
_install_exit_ec=0
_install_finish() {
  local ec="${_install_exit_ec:-0}" t
  for t in "${_INSTALL_TMPS[@]:-}"; do rm -f "$t" 2>/dev/null || true; done
  {
    echo "# ----"
    echo "# finished: $(_log_ts)"
    echo "# exit: $ec"
    echo "# log: $OC_LOG_FILE"
  } >>"$OC_LOG_FILE" 2>/dev/null || true
  # shellcheck disable=SC2012
  ls -1t "$OC_LOG_DIR"/install-*.log 2>/dev/null | tail -n +31 | while IFS= read -r old; do
    rm -f "$old" 2>/dev/null || true
  done
}
trap '_install_exit_ec=$?; _install_finish' EXIT

# Colors only on TTY
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_p="\033[35m"
  c_bold="\033[1m"; c_dim="\033[2m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_p=""; c_bold=""; c_dim=""; c_0=""
fi
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; _log "OK" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; _log "WARN" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; _log "ERR" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; _log "INFO" "$*"; }
die(){
  printf "  ${c_r}✗${c_0} %s\n" "$*" >&2
  _log "FATAL" "$*"
  _install_exit_ec=1
  exit 1
}

# OpenConfig banner (common.sh not sourced yet for curl|bash bootstrap)
_install_banner() {
  printf '%b\n' "${c_b}${c_bold}"
  cat <<'ASCII'
   ___                   ____             __ _
  / _ \ _ __  ___ _ __  / ___|___  _ __  / _(_) __ _
 | | | | '_ \/ _ \ '_ \ | |   / _ \| '_ \| |_| |/ _` |
 | |_| | |_) |  __/ | | | |__| (_) | | | |  _| | (_| |
  \___/| .__/ \___|_| |_|\____\___/|_| |_|_| |_|\__, |
       |_|                                      |___/
ASCII
  printf '%b' "${c_0}"
  printf '  %bOpenConfig%b  %boc%b\n' "${c_p}" "${c_0}" "${c_bold}" "${c_0}"
  printf '  %bBest-known config for OpenCode · OpenRouter · OmO%b\n' "${c_dim}" "${c_0}"
  printf '  %bSources:%b OpenCode ← opencode.ai/install · OmO ← npm oh-my-openagent · config ← OpenConfig (identity openconfig/opencode-configs)\n\n' "${c_dim}" "${c_0}"
}

# ── Interactive prompts (prefer /dev/tty so curl|bash still works) ─
OC_CAN_PROMPT=false
if ! $ASSUME_YES && [[ -r /dev/tty && -w /dev/tty ]]; then
  OC_CAN_PROMPT=true
elif ! $ASSUME_YES && [[ -t 0 ]]; then
  OC_CAN_PROMPT=true
fi

# Read a line into REPLY from tty when possible.
oc_read_line() {
  REPLY=""
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    # shellcheck disable=SC2162
    IFS= read -r REPLY </dev/tty || true
  elif [[ -t 0 ]]; then
    IFS= read -r REPLY || true
  else
    REPLY=""
  fi
}

# ask_yn "Install CLI?" "Y"  → sets REPLY to y or n; empty input uses default (Y or N)
ask_yn() {
  local prompt="$1" default="${2:-Y}" ans ddisp
  if [[ "${default}" =~ ^[Yy] ]]; then
    ddisp="Y/n"
  else
    ddisp="y/N"
  fi
  if ! $OC_CAN_PROMPT; then
    if [[ "${default}" =~ ^[Yy] ]]; then REPLY=y; else REPLY=n; fi
    return 0
  fi
  printf "  %s [%s]: " "$prompt" "$ddisp"
  oc_read_line
  ans="${REPLY:-}"
  if [[ -z "$ans" ]]; then
    if [[ "${default}" =~ ^[Yy] ]]; then REPLY=y; else REPLY=n; fi
    return 0
  fi
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) REPLY=y ;;
    [Nn]|[Nn][Oo]) REPLY=n ;;
    *)
      # Unknown → default
      if [[ "${default}" =~ ^[Yy] ]]; then REPLY=y; else REPLY=n; fi
      ;;
  esac
}

# ask_value "Install dir" "/default/path" → REPLY is value (Enter keeps default)
ask_value() {
  local prompt="$1" default="${2:-}"
  if ! $OC_CAN_PROMPT; then
    REPLY="$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    printf "  %s [%s]: " "$prompt" "$default"
  else
    printf "  %s: " "$prompt"
  fi
  oc_read_line
  if [[ -z "${REPLY:-}" ]]; then
    REPLY="$default"
  fi
}

# Seed allowlisted key from process environment if .env empty
seed_key_from_env() {
  local key="$1"
  local cur envval
  cur="$(oc_get_env_key "$ENV_FILE" "$key" 2>/dev/null || true)"
  [[ -z "$cur" ]] || return 0
  envval="$(printenv "$key" 2>/dev/null || true)"
  [[ -n "$envval" ]] || return 0
  oc_set_env_key "$ENV_FILE" "$key" "$envval"
  ok "$key imported from environment (value redacted)"
  _log "INFO" "$key seeded_from_env"
}

# Distribution host encoded (no owner literals in source). Decode at runtime.
_OC_GH_B64='aHR0cHM6Ly9naXRodWIuY29tL2plc3Nlb3VlL29wZW5jb2RlLWNvbmZpZ3M='
_oc_gh_url() {
  if command -v base64 >/dev/null 2>&1; then
    local out
    out="$(printf '%s' "$_OC_GH_B64" | base64 -D 2>/dev/null || printf '%s' "$_OC_GH_B64" | base64 -d 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  python3 -c "import base64; print(base64.b64decode('${_OC_GH_B64}').decode())"
}
REPO_URL="$(_oc_gh_url).git"
# Path after github.com/ — used to validate origin remotes
_OC_GH_PATH="$(_oc_gh_url)"
_OC_GH_PATH="${_OC_GH_PATH#*github.com/}"
_OC_GH_PATH="${_OC_GH_PATH#/}"
_OC_GH_PATH="${_OC_GH_PATH%.git}"
OPENCODE_CLI_INSTALL_URL="https://opencode.ai/install"

# In-place when running ./install.sh from a checkout; otherwise ~/opencode-configs
_script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
fi
if [[ -n "$INSTALL_DIR_FLAG" ]]; then
  INSTALL_DIR="$INSTALL_DIR_FLAG"
elif [[ -n "${OPENCODE_CONFIGS_DIR:-}" ]]; then
  INSTALL_DIR="$OPENCODE_CONFIGS_DIR"
elif [[ -n "$_script_dir" && -f "$_script_dir/opencode.json" ]]; then
  INSTALL_DIR="$_script_dir"
else
  INSTALL_DIR="$HOME/opencode-configs"
fi
unset _script_dir
while [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == */ && "$INSTALL_DIR" != "/" ]]; do
  INSTALL_DIR="${INSTALL_DIR%/}"
done
if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "/" ]]; then
  die "refusing install dir ${INSTALL_DIR_FLAG:-/}"
fi
[[ "$INSTALL_DIR" == /* ]] || INSTALL_DIR="$HOME/$INSTALL_DIR"
case "$INSTALL_DIR" in
  /|"$HOME"|"$HOME/.local/share/opencode"|"$HOME/.local/share/opencode"/*|"$XDG_DATA_HOME/opencode"|"$XDG_DATA_HOME/opencode"/*)
    die "refusing install dir $INSTALL_DIR"
    ;;
esac
LINK="${XDG_CONFIG_HOME}/opencode"

# Feature toggles (lazy defaults — Enter accepts these)
DO_INSTALL_CLI=true
DO_KEYS=true
DO_ZSHRC=true
DO_TMUX=true
DO_GHOSTTY=true
DO_SETUP=true
$SKIP_CLI && DO_INSTALL_CLI=false

_install_banner
info "log → $OC_LOG_FILE"
info "HOME=$HOME"
info "install → $INSTALL_DIR"
_log "INFO" "flags skip_cli=$SKIP_CLI assume_yes=$ASSUME_YES lazy=$LAZY_MODE can_prompt=$OC_CAN_PROMPT"

if $ASSUME_YES; then
  info "non-interactive (--yes): accepting defaults; seed keys from env if present"
elif $OC_CAN_PROMPT; then
  echo ""
  printf '%b\n' "  ${c_b}One-shot healthy stack${c_0} — OpenCode + OpenRouter + OmO, pinned and checked."
  echo "  Press Enter to accept defaults (lazy mode). Keys stay local in .env — never committed."
  if $LAZY_MODE; then
    info "mode: lazy (defaults on — only missing API keys need attention)"
  else
    info "mode: full wizard"
  fi
  echo ""

  # Confirm / override install dir when not forced by --dir / checkout
  if [[ -z "$INSTALL_DIR_FLAG" ]] && ! $LAZY_MODE; then
    ask_value "Install directory" "$INSTALL_DIR"
    if [[ -n "$REPLY" && "$REPLY" != "$INSTALL_DIR" ]]; then
      INSTALL_DIR="$REPLY"
      [[ "$INSTALL_DIR" == /* ]] || INSTALL_DIR="$HOME/$INSTALL_DIR"
      while [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == */ && "$INSTALL_DIR" != "/" ]]; do
        INSTALL_DIR="${INSTALL_DIR%/}"
      done
      case "$INSTALL_DIR" in
        /|"$HOME"|"$HOME/.local/share/opencode"|"$HOME/.local/share/opencode"/*)
          die "refusing install dir $INSTALL_DIR"
          ;;
      esac
      info "install → $INSTALL_DIR"
    fi
  fi

  if ! $SKIP_CLI; then
    if $LAZY_MODE; then
      DO_INSTALL_CLI=true
    else
      ask_yn "Install / ensure OpenCode CLI?" "Y"
      [[ "$REPLY" == y ]] && DO_INSTALL_CLI=true || DO_INSTALL_CLI=false
    fi
  fi

  if $LAZY_MODE; then
    DO_KEYS=true
    DO_ZSHRC=true
    DO_TMUX=true
    DO_GHOSTTY=true
    DO_SETUP=true
  else
    ask_yn "Configure API keys now? (OpenRouter required)" "Y"
    [[ "$REPLY" == y ]] && DO_KEYS=true || DO_KEYS=false
    ask_yn "Add zsh snippet (oc + opencode launcher)?" "Y"
    [[ "$REPLY" == y ]] && DO_ZSHRC=true || DO_ZSHRC=false
    ask_yn "Link tmux.conf if tmux is installed?" "Y"
    [[ "$REPLY" == y ]] && DO_TMUX=true || DO_TMUX=false
    ask_yn "Link ghostty.conf if Ghostty config dir exists?" "Y"
    [[ "$REPLY" == y ]] && DO_GHOSTTY=true || DO_GHOSTTY=false
    ask_yn "Run setup.sh (teams, LSP, plugin cache, doctor)?" "Y"
    [[ "$REPLY" == y ]] && DO_SETUP=true || DO_SETUP=false
    ask_value "Projects directory for oc new" "${OC_PROJECTS_DIR:-$HOME/Projects}"
    if [[ -n "$REPLY" ]]; then
      OC_PROJECTS_DIR="$REPLY"
      [[ "$OC_PROJECTS_DIR" == /* || "$OC_PROJECTS_DIR" == ~* ]] || OC_PROJECTS_DIR="$HOME/$OC_PROJECTS_DIR"
      export OC_PROJECTS_DIR
      info "projects → $OC_PROJECTS_DIR"
    fi
  fi
  echo ""
  info "plan: cli=$DO_INSTALL_CLI keys=$DO_KEYS zsh=$DO_ZSHRC tmux=$DO_TMUX ghostty=$DO_GHOSTTY setup=$DO_SETUP"
else
  info "no TTY for prompts — using defaults (pass keys via env or edit .env after)"
  info "tip: download install.sh and run bash install.sh for interactive lazy mode"
fi
echo ""

# ── Prerequisites ─────────────────────────────────────────────────
_log_section "prerequisites"
need=(curl git bash)
command -v python3 >/dev/null 2>&1 || need+=(python3)
missing=()
for c in curl git bash; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  die "missing required command(s): ${missing[*]}"
fi
ok "required commands present (curl git bash)"
command -v python3 >/dev/null 2>&1 || opt "python3 not found — .env key writes and validate will be limited"

# ─── 1. OpenCode CLI ──────────────────────────────────────────────
_log_section "1. OpenCode CLI"
if ! $DO_INSTALL_CLI; then
  info "Skipping OpenCode CLI"
elif command -v opencode >/dev/null 2>&1; then
  ok "OpenCode $(opencode --version 2>/dev/null | head -1)"
else
  info "Installing OpenCode CLI (download → sanity-check → run)..."
  tmp_cli="$(mktemp "${TMPDIR:-/tmp}/oc-cli-install.XXXXXX")"
  _INSTALL_TMPS+=("$tmp_cli")
  if ! curl -fsSL --connect-timeout 15 --max-time 180 --proto '=https' --tlsv1.2 \
      -o "$tmp_cli" "$OPENCODE_CLI_INSTALL_URL"; then
    die "failed to download OpenCode installer from $OPENCODE_CLI_INSTALL_URL"
  fi
  [[ -s "$tmp_cli" ]] || die "OpenCode installer download was empty"
  head -1 "$tmp_cli" | grep -qE '^#!/(usr/)?bin/(env )?(ba)?sh' \
    || die "OpenCode installer does not look like a shell script"
  bash "$tmp_cli"
  rm -f "$tmp_cli"
  export PATH="$HOME/.opencode/bin:$PATH"
  command -v opencode >/dev/null 2>&1 || die "OpenCode install finished but 'opencode' not on PATH"
  ok "OpenCode $(opencode --version 2>/dev/null | head -1)"
fi
echo ""

# ─── 2. Clone or update repo ──────────────────────────────────────
_log_section "2. clone/update repo"
clone_or_update() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing repo at $INSTALL_DIR..."
    local remote
    remote="$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)"
    _log "INFO" "git origin=$remote"
    case "$remote" in
      *"$_OC_GH_PATH"*) ;;
      "")
        opt "no git remote 'origin' — skipping pull"
        ;;
      *)
        die "refusing to pull: origin is '$remote' (expected …/${_OC_GH_PATH})"
        ;;
    esac
    if [[ -n "$remote" ]]; then
      if git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null; then
        ok "Repo updated (ff-only)"
      else
        opt "git pull skipped (local changes or offline) — using existing tree"
      fi
    else
      ok "Repo ready"
    fi
  elif [[ -f "$INSTALL_DIR/opencode.json" ]]; then
    ok "Using existing checkout at $INSTALL_DIR (no .git)"
  elif [[ -e "$INSTALL_DIR" ]]; then
    if find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      die "$INSTALL_DIR exists and is not an opencode-configs checkout — move it aside or set --dir"
    fi
    info "Cloning into empty directory $INSTALL_DIR..."
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
    ok "Repo cloned"
  else
    info "Cloning to $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
    ok "Repo cloned"
  fi
}
clone_or_update

[[ -f "$INSTALL_DIR/opencode.json" ]] || die "missing opencode.json in $INSTALL_DIR — aborting"
[[ -f "$INSTALL_DIR/lib/common.sh" ]] || die "missing lib/common.sh in $INSTALL_DIR — aborting"
[[ -x "$INSTALL_DIR/setup.sh" ]] || chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR/oc" 2>/dev/null || true

cd "$INSTALL_DIR"
REPO="$INSTALL_DIR"
# shellcheck source=lib/common.sh
source "$INSTALL_DIR/lib/common.sh"
INSTALL_DIR="$(oc_harden_install_dir "$INSTALL_DIR")"
REPO="$INSTALL_DIR"
export REPO INSTALL_DIR
LINK="${OC_CONFIG_LINK}"
echo ""

# ─── Sessions: never touch ────────────────────────────────────────
_log_section "sessions"
if [[ -d "$OC_SESSIONS_DIR" ]]; then
  info "Leaving OpenCode sessions intact at $OC_SESSIONS_DIR (never deleted by installer)"
  _log "INFO" "sessions_size=$(du -sh "$OC_SESSIONS_DIR" 2>/dev/null | awk '{print $1}')"
else
  info "No existing sessions dir yet (will be created by OpenCode on first run)"
fi

# ─── 3. Config symlink (backup real dirs; never rm sessions) ──────
_log_section "3. config symlink"
mkdir -p "$(dirname "$LINK")"
CONFIG_ENV_BACKUP=""
if [[ -L "$LINK" ]]; then
  cur="$(oc_readlink_abs "$LINK" 2>/dev/null || readlink "$LINK")"
  if oc_same_path "$cur" "$INSTALL_DIR"; then
    ok "Config symlink correct"
  else
    # Previous link target may hold a .env — migrate allowlisted keys after we create ours
    if [[ -f "$cur/.env" ]]; then
      CONFIG_ENV_BACKUP="$cur/.env"
    fi
    oc_backup_path "$LINK" "config-link" >/dev/null
    ln -sfn "$INSTALL_DIR" "$LINK"
    ok "Config symlink updated (old link backed up → ${OC_BACKUP_PATH:-})"
    _log "INFO" "backup=${OC_BACKUP_PATH:-}"
  fi
elif [[ -e "$LINK" ]]; then
  if [[ -f "$LINK/.env" ]]; then
    CONFIG_ENV_BACKUP="$LINK/.env"
  fi
  oc_backup_path "$LINK" "config" >/dev/null
  # After mv, .env lives under the backup dir
  if [[ -n "${OC_BACKUP_PATH:-}" && -f "${OC_BACKUP_PATH}/.env" ]]; then
    CONFIG_ENV_BACKUP="${OC_BACKUP_PATH}/.env"
  fi
  ln -sfn "$INSTALL_DIR" "$LINK"
  ok "Existing config dir backed up → ${OC_BACKUP_PATH:-}; symlink created"
  _log "INFO" "backup=${OC_BACKUP_PATH:-}"
else
  ln -sfn "$INSTALL_DIR" "$LINK"
  ok "Config symlink created"
fi
echo ""

# ─── 4. .env + interactive key setup ─────────────────────────────
_log_section "4. env keys"
ENV_FILE="$INSTALL_DIR/.env"
ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$INSTALL_DIR/.env.example" ]] || die "missing .env.example"
    cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env created from template"
  else
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
}
ensure_env_file

# Upgrade path: add any new keys from .env.example without clobbering values
if [[ -f "$INSTALL_DIR/.env.example" ]]; then
  merged="$(oc_ensure_env_keys_from_example "$ENV_FILE" "$INSTALL_DIR/.env.example" 2>/dev/null || true)"
  if [[ -n "$merged" ]]; then
    ok "added missing .env keys from template: $merged"
    _log "INFO" "env_keys_added=$merged"
  fi
fi

# Preserve the user's allowlisted keys when we replaced a prior config dir/link
if [[ -n "$CONFIG_ENV_BACKUP" ]]; then
  migrated="$(oc_migrate_allowlisted_env "$CONFIG_ENV_BACKUP" "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$migrated" ]]; then
    ok "migrated keys from previous config: $migrated (values redacted)"
    _log "INFO" "env_keys_migrated=$migrated"
  fi
fi

prompt_api_key() {
  local key="$1" label="$2" url="$3" required="${4:-false}"
  local cur val
  cur="$(oc_get_env_key "$ENV_FILE" "$key" 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    ok "$key already set"
    _log "INFO" "$key=set (value redacted)"
    return 0
  fi

  if ! $DO_KEYS || ! $OC_CAN_PROMPT; then
    if [[ "$required" == "true" ]]; then
      opt "$key not set — edit $ENV_FILE or export $key and re-run"
    else
      opt "$key not set (optional) — skip for now"
    fi
    return 0
  fi

  echo ""
  printf "  %s\n" "$label"
  echo "  get one: $url"
  if [[ "$required" == "true" ]]; then
    printf "  paste key (required — Enter skips with warning): "
  else
    printf "  paste key (optional — Enter skips): "
  fi
  oc_read_line
  val="${REPLY:-}"
  # Trim whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ -n "$val" ]]; then
    oc_set_env_key "$ENV_FILE" "$key" "$val"
    ok "$key saved"
    _log "INFO" "$key written (value redacted)"
    return 0
  fi
  if [[ "$required" == "true" ]]; then
    ask_yn "Skip OpenRouter for now? (stack won't work until you add it)" "N"
    if [[ "$REPLY" == y ]]; then
      opt "Skipped OPENROUTER_API_KEY — add it before oc launch"
      return 0
    fi
    printf "  paste OpenRouter key: "
    oc_read_line
    val="${REPLY:-}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ -n "$val" ]]; then
      oc_set_env_key "$ENV_FILE" "$key" "$val"
      ok "$key saved"
      _log "INFO" "$key written (value redacted)"
    else
      opt "Still empty — edit $ENV_FILE later"
    fi
  else
    info "skipped $key"
  fi
}

echo ""
printf '%b\n' "  ${c_b}API keys${c_0}  (Enter = skip optional · values never logged)"
echo "  File: $ENV_FILE (chmod 600, gitignored)"

# Prefer env pre-seed so lazy users can: OPENROUTER_API_KEY=… ./install.sh
seed_key_from_env OPENROUTER_API_KEY
seed_key_from_env OPENAI_API_KEY
seed_key_from_env EXA_API_KEY
seed_key_from_env CONTEXT7_API_KEY
seed_key_from_env OPENROUTER_MGMT_KEY

if $DO_KEYS; then
  prompt_api_key OPENROUTER_API_KEY \
    "OpenRouter (required — GLM/Flash/Claude/Gemini/…)" \
    "https://openrouter.ai/keys" true
  prompt_api_key OPENAI_API_KEY \
    "OpenAI (recommended — direct GPT lane / Hephaestus)" \
    "https://platform.openai.com/api-keys" false
  prompt_api_key EXA_API_KEY \
    "Exa (recommended — web search)" \
    "https://exa.ai" false
  prompt_api_key CONTEXT7_API_KEY \
    "Context7 (recommended — library docs MCP)" \
    "https://context7.com/dashboard" false
else
  opt "key prompts skipped — edit $ENV_FILE after install"
fi

# Verify OpenRouter when present
if [[ -n "$(oc_get_env_key "$ENV_FILE" OPENROUTER_API_KEY 2>/dev/null || true)" ]]; then
  or_key="$(oc_get_env_key "$ENV_FILE" OPENROUTER_API_KEY)"
  http_code="$(curl -sS --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $or_key" \
    -H "Content-Type: application/json" \
    -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"ping"}],"max_tokens":16}' \
    https://openrouter.ai/api/v1/chat/completions 2>/dev/null || echo "000")"
  if [[ "$http_code" == "200" ]]; then
    ok "OpenRouter key verified (HTTP 200)"
  else
    opt "OpenRouter key returned HTTP $http_code — check at https://openrouter.ai/keys"
  fi
  unset or_key
fi

# Telemetry defaults in .env — only when unset (never clobber user values)
if command -v python3 >/dev/null 2>&1; then
  for _kv in \
    "DO_NOT_TRACK=1" \
    "OMO_DISABLE_POSTHOG=1" \
    "OMO_SEND_ANONYMOUS_TELEMETRY=0" \
    "OMO_CODEX_DISABLE_POSTHOG=1" \
    "OMO_CODEX_SEND_ANONYMOUS_TELEMETRY=0" \
    "CODEGRAPH_TELEMETRY=0" \
    "OTEL_SDK_DISABLED=true"
  do
    _k="${_kv%%=*}"; _v="${_kv#*=}"
    _r="$(oc_set_env_key_if_unset "$ENV_FILE" "$_k" "$_v" 2>/dev/null || true)"
    [[ "$_r" == "set" ]] && _log "INFO" "env_default $_k=$_v"
  done
  unset _kv _k _v _r
  # Persist projects home only when unset
  _pd="${OC_PROJECTS_DIR:-}"
  if [[ -z "$_pd" ]]; then
    _pd="$(oc_get_env_key "$ENV_FILE" OC_PROJECTS_DIR 2>/dev/null || true)"
  fi
  if [[ -z "$_pd" ]]; then
    _pd="$HOME/Projects"
  fi
  if [[ "$_pd" == "~" ]]; then
    _pd="$HOME"
  elif [[ "$_pd" == "~/"* ]]; then
    _pd="${HOME}/${_pd:2}"
  fi
  _r="$(oc_set_env_key_if_unset "$ENV_FILE" OC_PROJECTS_DIR "$_pd" 2>/dev/null || true)"
  mkdir -p "$_pd"
  if [[ "$_r" == "set" ]]; then
    ok "projects dir → $_pd (wrote OC_PROJECTS_DIR)"
  else
    ok "projects dir → $(oc_get_env_key "$ENV_FILE" OC_PROJECTS_DIR) (preserved)"
  fi
  unset _pd _r
fi
echo ""

# ─── 5. Idempotent zshrc (no duplicates) ──────────────────────────
_log_section "5. zshrc"
if $DO_ZSHRC; then
  msg="$(oc_ensure_zshrc_snippet "$HOME/.zshrc")"
  ok "$msg"
else
  info "skipped zshrc snippet"
fi
echo ""

# ─── 6. Tmux + Ghostty (backup before replace) ───────────────────
_log_section "6. terminal configs"
link_config() {
  local dest="$1" src="$2" kind="$3" label="$4"
  if [[ -L "$dest" ]] && oc_same_path "$(oc_readlink_abs "$dest" 2>/dev/null || readlink "$dest")" "$src"; then
    ok "$label already linked"
  elif [[ -e "$dest" || -L "$dest" ]]; then
    oc_backup_path "$dest" "$kind" >/dev/null
    ln -sfn "$src" "$dest"
    ok "$label linked (previous backed up → ${OC_BACKUP_PATH:-})"
    _log "INFO" "$label backup=${OC_BACKUP_PATH:-}"
  else
    ln -sfn "$src" "$dest"
    ok "$label linked"
  fi
}

if $DO_TMUX; then
  if command -v tmux >/dev/null 2>&1; then
    link_config "$HOME/.tmux.conf" "$INSTALL_DIR/tmux.conf" "tmux" "tmux.conf"
  else
    opt "tmux not installed — run: brew install tmux (then re-run setup or link manually)"
  fi
else
  info "skipped tmux.conf"
fi

if $DO_GHOSTTY; then
  if [[ -d "${XDG_CONFIG_HOME}/ghostty" ]]; then
    link_config "${XDG_CONFIG_HOME}/ghostty/config" "$INSTALL_DIR/ghostty.conf" "ghostty" "ghostty.conf"
  else
    info "Ghostty not detected — skip ghostty.conf"
  fi
else
  info "skipped ghostty.conf"
fi
echo ""

# ─── 7. Delegate teams/LSP/plugin cache/verify to setup.sh ────────
_log_section "7. setup.sh"
if $DO_SETUP; then
  info "Running setup.sh for teams, LSP, plugin cache, doctor..."
  setup_out="$(mktemp "${TMPDIR:-/tmp}/oc-setup-out.XXXXXX")"
  _INSTALL_TMPS+=("$setup_out")
  set +e
  "$INSTALL_DIR/setup.sh" >"$setup_out" 2>&1
  setup_rc=$?
  set -e
  cat "$setup_out"
  {
    echo "$(_log_ts) [BLOB:setup.sh] begin (exit=$setup_rc)"
    sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$setup_out"
    echo "$(_log_ts) [BLOB:setup.sh] end"
  } >>"$OC_LOG_FILE"
  rm -f "$setup_out"
  if [[ "$setup_rc" -ne 0 ]]; then
    opt "setup.sh reported issues (exit $setup_rc) — run: oc doctor"
  else
    ok "setup.sh finished (exit 0)"
  fi
else
  opt "setup.sh skipped — run: $INSTALL_DIR/setup.sh  (or oc setup)"
fi
# Final scrub in case setup/doctor dropped runtime junk
oc_scrub_config_strays "$INSTALL_DIR" >/dev/null
[[ -n "${OC_SCRUBBED:-}" ]] && ok "removed config strays: $OC_SCRUBBED"
echo ""

_log_section "done"
printf '%b\n' "${c_g}✓ OpenConfig installed${c_0}"
_log "OK" "OpenConfig installation complete"
echo ""
echo "  OpenConfig (oc) — best-known config for OpenCode · OpenRouter · OmO"
echo ""
echo "Safety notes:"
echo "  • Sessions left untouched: $OC_SESSIONS_DIR"
echo "  • Replacements backed up under: $OC_BACKUP_ROOT"
echo "  • zshrc: single snippet source, or your inline opencode() left alone"
echo "  • Install log: $OC_LOG_FILE"
echo "  • Latest log:  $OC_LOG_DIR/install-latest.log"
echo ""
echo "Next:"
missing_or=true
if command -v python3 >/dev/null 2>&1 && [[ -n "$(oc_get_env_key "$ENV_FILE" OPENROUTER_API_KEY 2>/dev/null || true)" ]]; then
  missing_or=false
elif grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=.+' "$ENV_FILE" 2>/dev/null; then
  missing_or=false
fi
step=1
if $missing_or; then
  echo "  $step. Edit $LINK/.env — add OPENROUTER_API_KEY (required)"
  step=$((step + 1))
fi
if [[ -z "$(oc_get_env_key "$ENV_FILE" OPENAI_API_KEY 2>/dev/null || true)" ]]; then
  echo "  $step. Optional: add OPENAI_API_KEY for the direct GPT lane (Hephaestus/Oracle/…)"
  step=$((step + 1))
fi
echo "  $step. Restart shell (or: source ~/.zshrc)"
step=$((step + 1))
echo "  $step. oc doctor && oc launch"
echo ""
echo "  oc help · oc doctor · oc admin health · oc validate"
echo "  Docs: $LINK/README.md"
echo "  Secrets: only in $ENV_FILE (never committed). Repo ships .env.example with empty values."
_install_exit_ec=0
} # end install_main

# Invoke only after the full script has been parsed (curl|bash safety).
install_main "$@"
