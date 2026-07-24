#!/usr/bin/env bash
# lib/common.sh — shared helpers for opencode-configs scripts.
# Source from repo scripts:  # shellcheck source=lib/common.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/common.sh"
# Or when already in REPO: source "$REPO/lib/common.sh"
#
# Hardens footguns we've hit in production:
#   • .env values with &, #, spaces break `source .env` — never source; parse+export
#   • OpenCode drops package.json/node_modules into the config dir (symlink target)
#   • ~/.opencode/bin is the CLI install — not a leftover config copy
#   • Prefer oh-my-openagent name (legacy oh-my-opencode still appears in caches)
#   • HOME / XDG / REPO must be absolute + sane before any path writes

# ── Bootstrap: shell / HOME / XDG / REPO ───────────────────────────

# Stable IFS + no CDPATH surprises (cd would otherwise print/jump oddly).
oc_harden_shell() {
  unset CDPATH 2>/dev/null || true
  IFS=$' \t\n'
  # Make pathname expansion predictable in our scripts
  set +o noglob 2>/dev/null || true
}

# Resolve, normalize, and validate HOME. Refuse "/", relative, or missing dirs.
oc_harden_home() {
  local resolved=""
  if [[ -z "${HOME:-}" ]]; then
    if resolved="$(cd ~ 2>/dev/null && pwd -P)"; then
      HOME="$resolved"
    elif command -v getent >/dev/null 2>&1; then
      HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
    elif [[ "$(uname -s 2>/dev/null)" == Darwin ]] && command -v dscl >/dev/null 2>&1; then
      HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
  fi
  # Strip trailing slashes without turning "/" into ""
  while [[ -n "${HOME:-}" && "$HOME" == */ && "$HOME" != "/" ]]; do
    HOME="${HOME%/}"
  done
  if [[ -z "${HOME:-}" ]]; then
    echo "oc: HOME is unset and could not be resolved" >&2
    return 1
  fi
  if [[ "$HOME" != /* ]]; then
    echo "oc: HOME must be an absolute path (got: $HOME)" >&2
    return 1
  fi
  if [[ "$HOME" == "/" ]]; then
    echo "oc: refusing HOME=/ (would write under system root)" >&2
    return 1
  fi
  if [[ ! -d "$HOME" ]]; then
    echo "oc: HOME is not a directory: $HOME" >&2
    return 1
  fi
  if command -v realpath >/dev/null 2>&1; then
    HOME="$(realpath "$HOME")"
  else
    HOME="$(cd "$HOME" && pwd -P)"
  fi
  export HOME
}

# Absolute-ize XDG dirs under a hardened HOME. Refuse "/" and relative values.
oc_harden_xdg() {
  export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
  export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

  _oc_check_xdg() {
    local name="$1" val="$2"
    while [[ -n "$val" && "$val" == */ && "$val" != "/" ]]; do
      val="${val%/}"
    done
    if [[ -z "$val" || "$val" == "/" ]]; then
      echo "oc: refusing empty or root $name" >&2
      return 1
    fi
    if [[ "$val" != /* ]]; then
      echo "oc: $name must be absolute (got: $val)" >&2
      return 1
    fi
    printf '%s' "$val"
  }

  XDG_CONFIG_HOME="$(_oc_check_xdg XDG_CONFIG_HOME "$XDG_CONFIG_HOME")" || return 1
  XDG_DATA_HOME="$(_oc_check_xdg XDG_DATA_HOME "$XDG_DATA_HOME")" || return 1
  XDG_CACHE_HOME="$(_oc_check_xdg XDG_CACHE_HOME "$XDG_CACHE_HOME")" || return 1
  XDG_STATE_HOME="$(_oc_check_xdg XDG_STATE_HOME "$XDG_STATE_HOME")" || return 1
  export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  unset -f _oc_check_xdg 2>/dev/null || true
}

# Canonical install/runtime paths derived from hardened HOME/XDG.
oc_set_standard_paths() {
  OC_SESSIONS_DIR="${XDG_DATA_HOME}/opencode"
  OC_BACKUP_ROOT="${HOME}/.opencode-backups"
  OC_CONFIG_LINK="${XDG_CONFIG_HOME}/opencode"
  OC_CLI_DIR="${HOME}/.opencode"
  OC_CLI_BIN="${OC_CLI_DIR}/bin/opencode"
  export OC_SESSIONS_DIR OC_BACKUP_ROOT OC_CONFIG_LINK OC_CLI_DIR OC_CLI_BIN
}

# Resolve REPO to an absolute path that contains opencode.json.
# Prefer caller-set REPO; else walk from the sourcing script / this file.
oc_resolve_repo() {
  local here candidate
  if [[ -n "${REPO:-}" ]]; then
    REPO="${REPO%/}"
    if [[ "$REPO" != /* ]]; then
      echo "oc: REPO must be absolute (got: $REPO)" >&2
      return 1
    fi
    if command -v realpath >/dev/null 2>&1; then
      REPO="$(realpath "$REPO")"
    else
      REPO="$(cd "$REPO" && pwd -P)"
    fi
    if [[ ! -f "$REPO/opencode.json" ]]; then
      echo "oc: REPO does not look like opencode-configs (missing opencode.json): $REPO" >&2
      return 1
    fi
    export REPO
    return 0
  fi

  # BASH_SOURCE[1] = caller that sourced us; [0] = this file (lib/)
  here="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd -P)"
  if [[ -f "$here/opencode.json" ]]; then
    candidate="$here"
  elif [[ -f "$here/../opencode.json" ]]; then
    candidate="$(cd "$here/.." && pwd -P)"
  else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    candidate="$here"
  fi
  if command -v realpath >/dev/null 2>&1; then
    candidate="$(realpath "$candidate")"
  fi
  if [[ ! -f "$candidate/opencode.json" ]]; then
    echo "oc: could not resolve REPO (no opencode.json near ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}})" >&2
    return 1
  fi
  REPO="$candidate"
  export REPO
}

# Absolute-ize an install/target dir under HOME; refuse "/", HOME, and sessions tree.
oc_harden_install_dir() {
  local raw="${1:?path}" dir
  dir="$raw"
  while [[ -n "$dir" && "$dir" == */ && "$dir" != "/" ]]; do
    dir="${dir%/}"
  done
  if [[ -z "$dir" || "$dir" == "/" ]]; then
    echo "oc: refusing install dir ${raw:-empty}" >&2
    return 1
  fi
  if [[ "$dir" != /* ]]; then
    dir="$HOME/$dir"
  fi
  if command -v realpath >/dev/null 2>&1 && [[ -e "$dir" || -L "$dir" ]]; then
    dir="$(realpath "$dir")"
  fi
  if [[ "$dir" == "/" || "$dir" == "$HOME" ]]; then
    echo "oc: refusing install dir $dir" >&2
    return 1
  fi
  # Never clone/overwrite into the session store
  case "$dir" in
    "$OC_SESSIONS_DIR"|"$OC_SESSIONS_DIR"/*|"$HOME/.local/share/opencode"|"$HOME/.local/share/opencode"/*)
      echo "oc: refusing install into sessions tree: $dir" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$dir"
}

# Full bootstrap. Args: require_repo=1 (default) | 0
oc_bootstrap() {
  local require_repo="${1:-1}"
  oc_harden_shell
  oc_harden_home || return 1
  oc_harden_xdg || return 1
  oc_set_standard_paths
  case "$require_repo" in
    0|no|false|off) ;;
    *) oc_resolve_repo || return 1 ;;
  esac
  return 0
}

# Print the leading `#` usage block from a script (shebang skipped; stops at `set `).
# Use for -h/--help instead of `grep '^#'` which dumps every later comment too.
oc_print_script_help() {
  local script="${1:-}"
  if [[ -z "$script" ]]; then
    script="${BASH_SOURCE[1]:-$0}"
  fi
  awk 'NR==1{next} /^set /{exit} {sub(/^# ?/,""); print}' "$script"
}

# When sourced: always harden HOME/XDG; resolve REPO when already set or discoverable.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  oc_harden_shell
  oc_harden_home || return 1
  oc_harden_xdg || return 1
  oc_set_standard_paths
  if [[ -n "${REPO:-}" ]] || [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/opencode.json" ]]; then
    oc_resolve_repo || return 1
  fi
fi

# Keys safe/useful to inject into OpenCode / admin / headless runs.
# Never dump the whole .env (DB URLs, company secrets, etc.) into the process environment.
OC_ENV_ALLOWLIST=(
  OPENROUTER_API_KEY
  OPENAI_API_KEY
  EXA_API_KEY
  CONTEXT7_API_KEY
  OPENROUTER_MGMT_KEY
  OC_PROJECTS_DIR
  OC_DEFAULT_WORKSPACE
  OC_DEFAULT_PROFILE
  DO_NOT_TRACK
  OMO_DISABLE_POSTHOG
  OMO_SEND_ANONYMOUS_TELEMETRY
  OMO_CODEX_DISABLE_POSTHOG
  OMO_CODEX_SEND_ANONYMOUS_TELEMETRY
  CODEGRAPH_TELEMETRY
  OTEL_SDK_DISABLED
)

# Install/runtime junk OpenCode may drop into the config repo.
OC_CONFIG_STRAYS=(
  node_modules
  package.json
  package-lock.json
  npm-shrinkwrap.json
  yarn.lock
  pnpm-lock.yaml
  bun.lock
  bun.lockb
  .omo
  .sisyphus
  .codegraph
  command
  .opencode
  plugins
)

# ── Branding (OpenConfig — `oc`) ─────────────────────────────────────
# Shared banner for install / setup / oc help. Product name is OpenConfig;
# repo folder remains opencode-configs.
oc_banner() {
  local version="${1:-}"
  local tagline="${2:-}"
  local c_b="${c_b:-}" c_p="${c_p:-}" c_dim="${c_dim:-}" c_bold="${c_bold:-}" c_0="${c_0:-}"
  # Soft colors when caller hasn't defined them yet
  if [[ -z "$c_b" && -t 1 && -z "${NO_COLOR:-}" ]]; then
    c_b="\033[36m"; c_p="\033[35m"; c_dim="\033[2m"; c_bold="\033[1m"; c_0="\033[0m"
  fi
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
  if [[ -n "$version" ]]; then
    printf '  %bOpenConfig%b  %boc%b v%s\n' "${c_p}" "${c_0}" "${c_bold}" "${c_0}" "$version"
  else
    printf '  %bOpenConfig%b  %boc%b\n' "${c_p}" "${c_0}" "${c_bold}" "${c_0}"
  fi
  if [[ -n "$tagline" ]]; then
    printf '  %b%s%b\n' "${c_dim}" "$tagline" "${c_0}"
  else
    printf '  %bPinned stack for OpenCode · OpenRouter · OmO%b\n' "${c_dim}" "${c_0}"
  fi
  printf '\n'
}

# Read one KEY from a dotenv file without shell-eval. Prints value only.
# Handles: export KEY=, outer single/double quotes, values containing & # spaces.
oc_get_env_key() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" <<'PY'
import sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            if "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k.strip() != want:
                continue
            v = v.strip()
            if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
                v = v[1:-1]
            sys.stdout.write(v)
            break
except OSError:
    pass
PY
}

# Export allowlisted keys from .env into the current shell (safe for & in URLs).
oc_export_env_file() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  # shellcheck disable=SC2046
  eval "$(
    ALLOW="$(IFS=,; echo "${OC_ENV_ALLOWLIST[*]}")" \
    python3 - "$file" <<'PY'
import os, shlex, sys
path = sys.argv[1]
allow = set(os.environ.get("ALLOW", "").split(","))
found = {}
try:
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            if "=" not in line:
                continue
            k, _, v = line.partition("=")
            k = k.strip()
            if k not in allow:
                continue
            v = v.strip()
            if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
                v = v[1:-1]
            found[k] = v
except OSError:
    pass
for k, v in found.items():
    print(f"export {k}={shlex.quote(v)}")
PY
  )"
}

# Telemetry off — always set before launching OpenCode / OmO CLI.
# Kills PostHog (OmO), codegraph phone-home, OpenCode OTel exporters, and
# Codex-edition OmO telemetry. Also hardens headless boot.
oc_telemetry_off() {
  export DO_NOT_TRACK=1
  export OMO_DISABLE_POSTHOG=1
  export OMO_SEND_ANONYMOUS_TELEMETRY=0
  export OMO_CODEX_DISABLE_POSTHOG=1
  export OMO_CODEX_SEND_ANONYMOUS_TELEMETRY=0
  export CODEGRAPH_TELEMETRY=0
  # Ensure OpenCode experimental OTel / third-party OTLP stay dark
  unset OPENCODE_ENABLE_TELEMETRY 2>/dev/null || true
  unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT \
        OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT \
        OTEL_EXPORTER_OTLP_HEADERS OPENCODE_OTLP_ENDPOINT 2>/dev/null || true
  export OTEL_SDK_DISABLED=true
  export OPENCODE_DISABLE_EXTERNAL_SKILLS="${OPENCODE_DISABLE_EXTERNAL_SKILLS:-1}"
  export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS="${OPENCODE_DISABLE_CLAUDE_CODE_SKILLS:-1}"
  export OPENCODE_DISABLE_LSP_DOWNLOAD="${OPENCODE_DISABLE_LSP_DOWNLOAD:-1}"
  export OPENCODE_FAST_BOOT="${OPENCODE_FAST_BOOT:-1}"
}

# Remove install/runtime strays from the config repo. Prints removed names on stdout.
# Usage: oc_scrub_config_strays "$REPO"   → sets OC_SCRUBBED (space-separated) 
oc_scrub_config_strays() {
  local repo="${1:?repo}"
  local name path
  local rm_bin
  rm_bin="$(command -v rm 2>/dev/null || true)"
  [[ -x "$rm_bin" ]] || rm_bin="/bin/rm"
  OC_SCRUBBED=""
  for name in "${OC_CONFIG_STRAYS[@]}"; do
    path="$repo/$name"
    if [[ -e "$path" || -L "$path" ]]; then
      "$rm_bin" -rf "$path"
      OC_SCRUBBED="${OC_SCRUBBED}${OC_SCRUBBED:+ }$name"
    fi
  done
}

# True if path looks like the OpenCode CLI install (~/.opencode with bin/), not a config copy.
oc_is_cli_install_dir() {
  local d="$1"
  [[ -d "$d/bin" ]] || return 1
  # Treat as CLI install when the only "interesting" entries are bin + install junk
  local extra
  extra="$(find "$d" -maxdepth 1 -mindepth 1 \
    ! -name bin ! -name .gitignore \
    ! -name node_modules ! -name package.json ! -name package-lock.json ! -name bun.lock ! -name bun.lockb \
    2>/dev/null | head -1)"
  [[ -z "$extra" ]]
}

# Move path aside under ~/.opencode-backups/<kind>-<stamp>/basename (never rm).
# Sets OC_BACKUP_PATH to the destination. No-op if path missing.
# OpenCode session store (OC_SESSIONS_DIR) must never be passed here for deletion.
oc_backup_path() {
  local src="${1:?path}" kind="${2:-file}"
  OC_BACKUP_PATH=""
  [[ -e "$src" || -L "$src" ]] || return 0
  # Hard refuse: never move the live sessions tree into backups via this helper
  local sessions="${OC_SESSIONS_DIR:-$HOME/.local/share/opencode}"
  case "$src" in
    "$sessions"|"$sessions"/*)
      echo "oc: refusing to move sessions path via oc_backup_path: $src" >&2
      return 1
      ;;
  esac
  local stamp root dest base
  stamp="$(date +%Y%m%d-%H%M%S)"
  root="${OC_BACKUP_ROOT:-$HOME/.opencode-backups}/${kind}-${stamp}"
  base="$(basename "$src")"
  mkdir -p "$root"
  dest="$root/$base"
  # Avoid clobbering an earlier backup in the same second
  if [[ -e "$dest" ]]; then
    dest="$root/${base}.$$"
  fi
  mv "$src" "$dest"
  OC_BACKUP_PATH="$dest"
}

# True when ~/.zshrc has an inline opencode() that is missing telemetry kill switches
# (or other 1.5 launcher essentials). Fresh inline or snippet source → false.
oc_zshrc_inline_stale() {
  local zshrc="${1:-$HOME/.zshrc}"
  [[ -f "$zshrc" ]] || return 1
  grep -qF 'source ~/.config/opencode/zshrc.snippet' "$zshrc" 2>/dev/null && return 1
  grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$zshrc" 2>/dev/null || return 1
  # Must export kill switches before launch (snippet does this)
  grep -qE 'DO_NOT_TRACK=1' "$zshrc" 2>/dev/null \
    && grep -qE 'OMO_DISABLE_POSTHOG' "$zshrc" 2>/dev/null \
    && grep -qE 'OTEL_SDK_DISABLED' "$zshrc" 2>/dev/null \
    && return 1
  return 0
}

# Remove a stale/duplicated inline opencode() block and related OpenConfig lines.
# Leaves unrelated shell config alone. Used when migrating to zshrc.snippet.
# Refuses to write if the result would shrink the file below 50% (safety).
oc_zshrc_strip_inline_opencode() {
  local zshrc="${1:-}"
  [[ -n "$zshrc" && -f "$zshrc" ]] || return 1
  python3 - "$zshrc" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
orig_len = len(text)
# Drop contiguous comment block immediately above opencode()
text = re.sub(
    r"(?m)(?:^[ \t]*#.*\n)+(?=^[ \t]*opencode[ \t]*\(\))",
    "",
    text,
)
# Brace-match remove opencode() { ... }
m = re.search(r"(?m)^[ \t]*opencode[ \t]*\(\)[ \t]*\{", text)
if m:
    i = m.end() - 1  # at '{'
    depth = 0
    j = i
    while j < len(text):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                j += 1
                break
        j += 1
    while j < len(text) and text[j] in "\r\n":
        j += 1
    text = text[: m.start()] + text[j:]

# Drop leftover OpenConfig lines that lived next to the inline launcher
drop_res = [
    re.compile(r"(?m)^[ \t]*#.*\boc\b.*dispatcher.*\n"),
    re.compile(r"(?m)^[ \t]*#.*'oc doctor'.*\n"),
    re.compile(r"(?m)^[ \t]*#.*See: oc help.*\n"),
    re.compile(r"(?m)^[ \t]*#.*opencode.*PATH.*\n"),
    re.compile(r"(?m)^[ \t]*#.*oradmin.*\n"),
    re.compile(r"(?m)^[ \t]*alias[ \t]+oradmin=.*\n"),
    re.compile(r"(?m)^[ \t]*setopt[ \t]+NO_BEEP[ \t]*\n"),
    re.compile(r"(?m)^[ \t]*setopt[ \t]+NO_LIST_BEEP[ \t]*\n"),
    re.compile(r"(?m)^[ \t]*# Mute terminal bells.*\n"),
    re.compile(
        r"(?m)^[ \t]*\[\[ -d \"\$HOME/\.config/opencode\" \]\].*PATH=.*\$HOME/\.config/opencode.*\n"
    ),
    re.compile(
        r"(?m)^[ \t]*\[\[ -d \"\$HOME/\.opencode/bin\" \]\].*PATH=.*\$HOME/\.opencode/bin.*\n"
    ),
]
for rx in drop_res:
    text = rx.sub("", text)
text = re.sub(r"\n{3,}", "\n\n", text)
# Safety: never wipe a real zshrc (must keep ≥50% of original size, ≥20 lines)
if orig_len > 500 and (len(text) < orig_len // 2 or text.count("\n") < 20):
    print(
        f"refusing strip: result too small ({len(text)} chars / {text.count(chr(10))} lines; "
        f"was {orig_len})",
        file=sys.stderr,
    )
    sys.exit(2)
open(path, "w", encoding="utf-8").write(text)
print("stripped inline opencode()")
PY
}

# Copy-based backup (keeps source in place). Use for in-place edits.
# Sets OC_BACKUP_PATH. Prefer this over oc_backup_path when you will keep editing $src.
oc_backup_copy() {
  local src="${1:?path}" kind="${2:-file}"
  OC_BACKUP_PATH=""
  [[ -e "$src" || -L "$src" ]] || return 0
  local sessions="${OC_SESSIONS_DIR:-$HOME/.local/share/opencode}"
  case "$src" in
    "$sessions"|"$sessions"/*)
      echo "oc: refusing to backup sessions path via oc_backup_copy: $src" >&2
      return 1
      ;;
  esac
  local stamp root dest base
  stamp="$(date +%Y%m%d-%H%M%S)"
  root="${OC_BACKUP_ROOT:-$HOME/.opencode-backups}/${kind}-${stamp}"
  base="$(basename "$src")"
  mkdir -p "$root"
  dest="$root/$base"
  if [[ -e "$dest" ]]; then
    dest="$root/${base}.$$"
  fi
  cp -p "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
  OC_BACKUP_PATH="$dest"
}

# Idempotent ~/.zshrc integration: one canonical source line, remove duplicates.
# Canonical:  source ~/.config/opencode/zshrc.snippet
# Fresh inline opencode() (with telemetry) is left alone; stale inline is migrated.
oc_ensure_zshrc_snippet() {
  local zshrc="${1:-$HOME/.zshrc}"
  local canonical='source ~/.config/opencode/zshrc.snippet'
  local tmp matches
  if [[ ! -f "$zshrc" ]]; then
    umask 077
    printf '%s\n' "# OpenConfig (oc)" "$canonical" > "$zshrc"
    chmod 644 "$zshrc" 2>/dev/null || true
    echo "created $zshrc with snippet"
    return 0
  fi
  matches="$(grep -cE 'zshrc\.snippet' "$zshrc" 2>/dev/null || true)"
  matches="${matches:-0}"
  # Already perfect: exactly one line and it's the canonical form
  if [[ "$matches" -eq 1 ]] && grep -qF "$canonical" "$zshrc" 2>/dev/null; then
    # Strip duplicate inline if somehow both exist (copy-backup — never move)
    if grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$zshrc" 2>/dev/null; then
      oc_backup_copy "$zshrc" "zshrc" >/dev/null
      oc_zshrc_strip_inline_opencode "$zshrc"
      if ! grep -qF "$canonical" "$zshrc" 2>/dev/null; then
        {
          echo ""
          echo "# OpenConfig (oc) — do not duplicate this block"
          echo "$canonical"
        } >> "$zshrc"
      fi
      echo "zshrc migrated (removed duplicate inline; snippet source kept; backup: ${OC_BACKUP_PATH:-none})"
      return 0
    fi
    echo "zshrc already OK (single snippet source)"
    return 0
  fi
  # Multiple / non-canonical source lines → strip and keep one canonical
  # (mv-backup is OK here: we replace the whole file from $tmp)
  if [[ "$matches" -gt 0 ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/oc-zshrc.XXXXXX")"
    grep -vE 'zshrc\.snippet' "$zshrc" > "$tmp" || true
    {
      echo ""
      echo "# OpenConfig (oc) — do not duplicate this block"
      echo "$canonical"
    } >> "$tmp"
    oc_backup_path "$zshrc" "zshrc" >/dev/null
    mv "$tmp" "$zshrc"
    chmod 644 "$zshrc" 2>/dev/null || true
    if grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$zshrc" 2>/dev/null; then
      oc_backup_copy "$zshrc" "zshrc" >/dev/null
      oc_zshrc_strip_inline_opencode "$zshrc"
    fi
    echo "zshrc updated (deduped snippet; backup: ${OC_BACKUP_PATH:-none})"
    return 0
  fi
  # Stale inline (missing telemetry) → migrate to snippet (copy-backup — never move)
  if oc_zshrc_inline_stale "$zshrc"; then
    oc_backup_copy "$zshrc" "zshrc" >/dev/null
    oc_zshrc_strip_inline_opencode "$zshrc"
    {
      echo ""
      echo "# OpenConfig (oc) — do not duplicate this block"
      echo "$canonical"
    } >> "$zshrc"
    echo "zshrc migrated stale inline opencode() → snippet (backup: ${OC_BACKUP_PATH:-none})"
    return 0
  fi
  # Fresh inline with telemetry — leave alone (no double-define)
  if grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$zshrc" 2>/dev/null; then
    echo "zshrc has inline opencode() — left as-is (no snippet source added)"
    return 0
  fi
  # Fresh: append canonical source once
  {
    echo ""
    echo "# OpenConfig (oc) — do not duplicate this block"
    echo "$canonical"
  } >> "$zshrc"
  echo "zshrc appended snippet source"
}

# ── Installer helpers ─────────────────────────────────────────────

oc_die() {
  printf 'oc: %s\n' "$*" >&2
  return 1
}

oc_require_cmds() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "oc: missing required command(s): ${missing[*]}" >&2
    return 1
  fi
}

# True if two paths resolve to the same filesystem object (or equal strings).
oc_same_path() {
  local a="${1:-}" b="${2:-}"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$a" == "$b" ]] && return 0
  if command -v realpath >/dev/null 2>&1; then
    local ra rb
    ra="$(realpath "$a" 2>/dev/null || true)"
    rb="$(realpath "$b" 2>/dev/null || true)"
    [[ -n "$ra" && -n "$rb" && "$ra" == "$rb" ]] && return 0
  fi
  # Fallback: resolve directories via pwd -P when both exist as dirs
  if [[ -d "$a" && -d "$b" ]]; then
    [[ "$(cd "$a" && pwd -P)" == "$(cd "$b" && pwd -P)" ]] && return 0
  fi
  return 1
}

# Resolve a symlink's target to an absolute path (best-effort).
oc_readlink_abs() {
  local link="${1:?}" tgt dir
  [[ -L "$link" ]] || return 1
  tgt="$(readlink "$link")"
  if [[ "$tgt" == /* ]]; then
    printf '%s\n' "$tgt"
    return 0
  fi
  dir="$(cd "$(dirname "$link")" && pwd -P)"
  printf '%s\n' "$dir/$tgt"
}

# Set KEY=value only when the key is missing or empty. Never clobbers a set value.
# Prints "set" if written, "keep" if left alone. Returns 0 either way.
# Usage: oc_set_env_key_if_unset "$file" KEY value
oc_set_env_key_if_unset() {
  local file="${1:?}" key="${2:?}" value="${3-}" cur
  cur="$(oc_get_env_key "$file" "$key" 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    printf 'keep\n'
    return 0
  fi
  oc_set_env_key "$file" "$key" "$value"
  printf 'set\n'
}

# Ensure .env exists from .env.example without overwriting an existing file.
# Then merge any missing keys from the example (never clobber non-empty values).
# Usage: oc_ensure_env_file "$env_file" "$example_file"
oc_ensure_env_file() {
  local dest="${1:?}" example="${2:?}"
  umask 077
  if [[ ! -f "$dest" ]]; then
    if [[ -f "$example" ]]; then
      cp "$example" "$dest"
    else
      : >"$dest"
    fi
    chmod 600 "$dest" 2>/dev/null || true
    printf 'created\n'
  else
    printf 'exists\n'
  fi
  oc_ensure_env_keys_from_example "$dest" "$example" >/dev/null 2>&1 || true
}

# True if path is a symlink whose resolved target matches expected (via oc_same_path).
# Usage: oc_link_points_to "$link" "$expected"
oc_link_points_to() {
  local link="${1:?}" expected="${2:?}" tgt
  [[ -L "$link" ]] || return 1
  tgt="$(oc_readlink_abs "$link" 2>/dev/null || readlink "$link" || true)"
  [[ -n "$tgt" ]] || return 1
  oc_same_path "$tgt" "$expected"
}

# Ensure a symlink points at expected. Backs up real dirs / wrong links first.
# Never deletes sessions. Skip if already correct. Dry-run with OC_LINK_DRY=1.
# Usage: oc_ensure_symlink "$link" "$expected" [backup_kind]
# Prints: ok|created|updated|would_create|would_update|needs_force
oc_ensure_symlink() {
  local link="${1:?}" expected="${2:?}" kind="${3:-link}"
  local parent dry="${OC_LINK_DRY:-0}"
  parent="$(dirname "$link")"
  if oc_link_points_to "$link" "$expected"; then
    printf 'ok\n'
    return 0
  fi
  if [[ -L "$link" || -e "$link" ]]; then
    if [[ "$dry" == "1" ]]; then
      printf 'would_update\n'
      return 0
    fi
    if [[ -e "$link" && ! -L "$link" ]]; then
      oc_backup_path "$link" "$kind" >/dev/null || true
    elif [[ -L "$link" ]]; then
      # Wrong symlink — backup the link entry itself (copy target path into backup note)
      mkdir -p "${OC_BACKUP_ROOT:-$HOME/.opencode-backups}/$kind-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      rm -f "$link"
    fi
    mkdir -p "$parent"
    ln -sfn "$expected" "$link"
    printf 'updated\n'
    return 0
  fi
  if [[ "$dry" == "1" ]]; then
    printf 'would_create\n'
    return 0
  fi
  mkdir -p "$parent"
  ln -sfn "$expected" "$link"
  printf 'created\n'
}

# Set KEY=value in a dotenv file without shell/sed injection. Creates file if missing.
# Usage: oc_set_env_key "$file" KEY value
oc_set_env_key() {
  local file="${1:?}" key="${2:?}" value="${3-}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "oc: invalid env key: $key" >&2
    return 1
  }
  umask 077
  if [[ ! -f "$file" ]]; then
    : >"$file"
    chmod 600 "$file" 2>/dev/null || true
  fi
  python3 - "$file" "$key" "$value" <<'PY'
import os, sys, tempfile
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
found = False
try:
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if stripped.startswith("export "):
                body = stripped[7:].lstrip()
            else:
                body = stripped
            if body and not body.startswith("#") and "=" in body:
                k = body.split("=", 1)[0].strip()
                if k == key:
                    lines.append(f"{key}={value}")
                    found = True
                    continue
            lines.append(line)
except FileNotFoundError:
    pass
if not found:
    lines.append(f"{key}={value}")
dir_name = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=dir_name, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write("\n".join(lines))
        if lines:
            out.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

# Ensure every KEY= from .env.example exists in dest .env.
# Never overwrites a non-empty value. Safe for upgrades when new keys are added.
# Usage: oc_ensure_env_keys_from_example "$env_file" "$example_file"
oc_ensure_env_keys_from_example() {
  local dest="${1:?}" example="${2:?}"
  [[ -f "$example" ]] || return 0
  umask 077
  python3 - "$dest" "$example" <<'PY'
import os, sys, tempfile
dest, example = sys.argv[1], sys.argv[2]

def parse(path):
    order, vals = [], {}
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                stripped = line.strip()
                body = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
                if body and not body.startswith("#") and "=" in body:
                    k, v = body.split("=", 1)
                    k = k.strip()
                    if k not in vals:
                        order.append(k)
                    vals[k] = v
    except FileNotFoundError:
        pass
    return order, vals

ex_order, ex_vals = parse(example)
dest_order, dest_vals = parse(dest)
added = []
for k in ex_order:
    if k not in dest_vals:
        dest_order.append(k)
        dest_vals[k] = ex_vals.get(k, "")
        added.append(k)

# Rebuild dest preserving existing non-key lines when possible: rewrite as KEY=value block
# Keep comments/blank structure from dest if it exists; append missing keys at end.
lines = []
seen = set()
try:
    with open(dest, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            body = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
            if body and not body.startswith("#") and "=" in body:
                k = body.split("=", 1)[0].strip()
                lines.append(f"{k}={dest_vals.get(k, '')}")
                seen.add(k)
            else:
                lines.append(line)
except FileNotFoundError:
    pass
for k in dest_order:
    if k not in seen:
        lines.append(f"{k}={dest_vals.get(k, '')}")
        seen.add(k)
dir_name = os.path.dirname(dest) or "."
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=dir_name, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write("\n".join(lines))
        if lines:
            out.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
if added:
    print(",".join(added))
PY
}

# Copy allowlisted keys from src .env → dest when dest is missing/empty for that key.
# Never copies non-allowlisted keys (keeps foreign secrets out of the OpenCode env).
# Usage: oc_migrate_allowlisted_env "$src_env" "$dest_env"
oc_migrate_allowlisted_env() {
  local src="${1:?}" dest="${2:?}"
  [[ -f "$src" ]] || return 0
  local key cur val migrated=()
  for key in "${OC_ENV_ALLOWLIST[@]}"; do
    cur="$(oc_get_env_key "$dest" "$key" 2>/dev/null || true)"
    [[ -n "$cur" ]] && continue
    val="$(oc_get_env_key "$src" "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] || continue
    oc_set_env_key "$dest" "$key" "$val"
    migrated+=("$key")
  done
  if [[ ${#migrated[@]} -gt 0 ]]; then
    printf '%s\n' "${migrated[*]}"
  fi
}

# Rewrite dest .env to contain ONLY allowlisted keys (values from src).
# Copies a backup first (never moves the live file mid-read).
# Prints: kept=N removed=M
# Usage: oc_scrub_env_to_allowlist "$src_or_dest" ["$dest"]
oc_scrub_env_to_allowlist() {
  local src="${1:?}" dest="${2:-$1}"
  [[ -f "$src" ]] || return 1
  local tmp key val kept=0 removed=0
  # Copy-backup BEFORE rewriting — oc_backup_path moves and would empty the source.
  if [[ -f "$dest" ]]; then
    oc_backup_copy "$dest" "env-scrub" >/dev/null || true
  fi
  removed="$(oc_env_foreign_key_count "$src")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/oc-env-scrub.XXXXXX")"
  {
    printf '%s\n' "# OpenConfig .env — allowlisted keys only (never commit)."
    printf '%s\n' "# Scrubbed $(date -u +%Y-%m-%dT%H:%M:%SZ). Foreign secrets belong in your secrets manager,"
    printf '%s\n' "# not in this config tree. See OC_ENV_ALLOWLIST in lib/common.sh."
    printf '\n'
  } >"$tmp"
  chmod 600 "$tmp"
  for key in "${OC_ENV_ALLOWLIST[@]}"; do
    val="$(oc_get_env_key "$src" "$key" 2>/dev/null || true)"
    if [[ -z "$val" && "$src" != "$dest" && -f "$dest" ]]; then
      val="$(oc_get_env_key "$dest" "$key" 2>/dev/null || true)"
    fi
    [[ -n "$val" ]] || continue
    oc_set_env_key "$tmp" "$key" "$val"
    kept=$((kept + 1))
  done
  # Ensure telemetry defaults
  oc_set_env_key_if_unset "$tmp" DO_NOT_TRACK 1 >/dev/null
  oc_set_env_key_if_unset "$tmp" OMO_DISABLE_POSTHOG 1 >/dev/null
  oc_set_env_key_if_unset "$tmp" OMO_SEND_ANONYMOUS_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$tmp" OMO_CODEX_DISABLE_POSTHOG 1 >/dev/null
  oc_set_env_key_if_unset "$tmp" OMO_CODEX_SEND_ANONYMOUS_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$tmp" CODEGRAPH_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$tmp" OTEL_SDK_DISABLED true >/dev/null
  mv -f "$tmp" "$dest"
  chmod 600 "$dest"
  printf 'kept=%s removed=%s\n' "$kept" "${removed:-0}"
}

# Filter a secrets-manager dotenv dump → allowlisted-only dest (never write foreign keys).
# Usage: oc_import_allowlisted_dotenv "$dump_file" "$dest_env"
oc_import_allowlisted_dotenv() {
  local dump="${1:?}" dest="${2:?}"
  [[ -f "$dump" ]] || return 1
  oc_ensure_env_file "$dest" >/dev/null 2>&1 || true
  local key val imported=()
  for key in "${OC_ENV_ALLOWLIST[@]}"; do
    val="$(oc_get_env_key "$dump" "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] || continue
    oc_set_env_key "$dest" "$key" "$val"
    imported+=("$key")
  done
  # Ensure telemetry defaults exist
  oc_set_env_key_if_unset "$dest" DO_NOT_TRACK 1 >/dev/null
  oc_set_env_key_if_unset "$dest" OMO_DISABLE_POSTHOG 1 >/dev/null
  oc_set_env_key_if_unset "$dest" OMO_SEND_ANONYMOUS_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$dest" OMO_CODEX_DISABLE_POSTHOG 1 >/dev/null
  oc_set_env_key_if_unset "$dest" OMO_CODEX_SEND_ANONYMOUS_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$dest" CODEGRAPH_TELEMETRY 0 >/dev/null
  oc_set_env_key_if_unset "$dest" OTEL_SDK_DISABLED true >/dev/null
  chmod 600 "$dest" 2>/dev/null || true
  if [[ ${#imported[@]} -gt 0 ]]; then
    printf '%s\n' "${imported[*]}"
  fi
}

# Count non-allowlisted keys in a .env (names only — never prints values).
# Usage: oc_env_foreign_key_count "$env_file" → prints integer
oc_env_foreign_key_count() {
  local file="${1:?}"
  [[ -f "$file" ]] || { printf '0\n'; return 0; }
  ALLOW="$(IFS=,; echo "${OC_ENV_ALLOWLIST[*]}")" \
  python3 - "$file" <<'PY'
import os, re, sys
allow = set(os.environ.get("ALLOW", "").split(","))
n = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    k = line.split("=", 1)[0].strip()
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) and k not in allow:
        n += 1
print(n)
PY
}

# Download URL to a temp file, basic sanity-check shebang, run with bash. Cleans up.
# Usage: oc_run_remote_install <url> [label]
oc_run_remote_install() {
  local url="${1:?}" label="${2:-remote installer}"
  local tmp
  oc_require_cmds curl bash || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/oc-install.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  if ! curl -fsSL --connect-timeout 15 --max-time 180 --proto '=https' --tlsv1.2 \
      -o "$tmp" "$url"; then
    echo "oc: failed to download $label from $url" >&2
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    echo "oc: downloaded $label is empty" >&2
    return 1
  fi
  if ! head -1 "$tmp" | grep -qE '^#!/(usr/)?bin/(env )?(ba)?sh'; then
    echo "oc: downloaded $label does not look like a shell script" >&2
    return 1
  fi
  bash "$tmp"
}

# ── Logging ───────────────────────────────────────────────────────
# Plain-text install/setup logs under ~/.opencode-backups/logs/
# Never write secrets (API keys) into the log.

oc_log_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Strip ANSI color codes from a string (for log files).
oc_strip_ansi() {
  # shellcheck disable=SC2001
  printf '%s' "$*" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

# Open OC_LOG_FILE (create dir, chmod 600, write header). Sets OC_LOG_FILE + OC_LOG_DIR.
# Usage: oc_log_open [kind] [optional explicit path]
oc_log_open() {
  local kind="${1:-install}" explicit="${2:-}"
  OC_LOG_DIR="${OC_BACKUP_ROOT:-$HOME/.opencode-backups}/logs"
  mkdir -p "$OC_LOG_DIR"
  if [[ -n "$explicit" ]]; then
    OC_LOG_FILE="$explicit"
    mkdir -p "$(dirname "$OC_LOG_FILE")"
  else
    OC_LOG_FILE="${OC_LOG_DIR}/${kind}-$(date +%Y%m%d-%H%M%S)-$$.log"
  fi
  umask 077
  {
    echo "# opencode-configs ${kind} log"
    echo "# started: $(oc_log_ts)"
    echo "# host: $(uname -n 2>/dev/null || echo unknown)"
    echo "# user: $(id -un 2>/dev/null || echo unknown)"
    echo "# pid: $$"
    echo "# ----"
  } >"$OC_LOG_FILE"
  chmod 600 "$OC_LOG_FILE" 2>/dev/null || true
  # latest symlink for this kind
  ln -sfn "$OC_LOG_FILE" "${OC_LOG_DIR}/${kind}-latest.log" 2>/dev/null || true
  export OC_LOG_FILE OC_LOG_DIR
}

# Append one line: LEVEL message (no colors). No-op if log not open.
oc_log() {
  local level="${1:-INFO}"
  shift || true
  [[ -n "${OC_LOG_FILE:-}" ]] || return 0
  printf '%s [%s] %s\n' "$(oc_log_ts)" "$level" "$(oc_strip_ansi "$*")" >>"$OC_LOG_FILE" 2>/dev/null || true
}

oc_log_section() {
  oc_log "----" "$*"
}

# Append a multi-line blob (e.g. setup.sh output), ANSI-stripped.
oc_log_blob() {
  local label="${1:-output}"
  [[ -n "${OC_LOG_FILE:-}" ]] || return 0
  {
    echo "$(oc_log_ts) [BLOB:${label}] begin"
    oc_strip_ansi "$(cat)"
    echo ""
    echo "$(oc_log_ts) [BLOB:${label}] end"
  } >>"$OC_LOG_FILE" 2>/dev/null || true
}

oc_log_close() {
  local ec="${1:-0}"
  [[ -n "${OC_LOG_FILE:-}" ]] || return 0
  {
    echo "# ----"
    echo "# finished: $(oc_log_ts)"
    echo "# exit: $ec"
  } >>"$OC_LOG_FILE" 2>/dev/null || true
  # Keep newest 30 logs per kind (best-effort)
  if [[ -d "${OC_LOG_DIR:-}" ]]; then
    # shellcheck disable=SC2012
    ls -1t "$OC_LOG_DIR"/install-*.log 2>/dev/null | tail -n +31 | while IFS= read -r old; do
      rm -f "$old" 2>/dev/null || true
    done
  fi
}

# ── Version pins (versions.json) ─────────────────────────────────────
# Compare dotted versions: oc_version_ge A B → 0 if A >= B
oc_version_ge() {
  local a="${1:-0}" b="${2:-0}"
  python3 -c "
import sys
def parts(s):
    out=[]
    for p in str(s).strip().lstrip('vV').replace('-','.').split('.'):
        if p.isdigit(): out.append(int(p))
        else:
            dig=''.join(c for c in p if c.isdigit())
            out.append(int(dig) if dig else 0)
    return out or [0]
A,B=parts(sys.argv[1]),parts(sys.argv[2])
n=max(len(A),len(B)); A+=[0]*(n-len(A)); B+=[0]*(n-len(B))
sys.exit(0 if A>=B else 1)
" "$a" "$b" 2>/dev/null
}

# Read a dotted path from versions.json (e.g. tmux.min → 3.3.0)
oc_versions_get() {
  local keypath="${1:-}"
  local file="${REPO:-}/versions.json"
  [[ -n "$keypath" && -f "$file" ]] || return 1
  python3 - "$file" "$keypath" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(1)
    cur = cur[part]
if cur is None or cur == "":
    sys.exit(1)
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur))
PY
}

# Best-effort tool version string (first semver-ish token).
oc_tool_version() {
  local tool="${1:-}"
  case "$tool" in
    opencode)
      local bin="${2:-$(command -v opencode 2>/dev/null || echo "${OC_CLI_BIN:-}")}"
      [[ -x "$bin" ]] || return 1
      "$bin" --version 2>/dev/null | head -1 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1
      ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      tmux -V 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+[a-z]?' | head -1 | tr -d 'a-z'
      ;;
    ghostty)
      local gbin=""
      if command -v ghostty >/dev/null 2>&1; then gbin="$(command -v ghostty)"
      elif [[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]]; then
        gbin="/Applications/Ghostty.app/Contents/MacOS/ghostty"
      fi
      [[ -n "$gbin" ]] || return 1
      "$gbin" +version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
        || "$gbin" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
      ;;
    node)
      command -v node >/dev/null 2>&1 || return 1
      node --version 2>/dev/null | tr -d 'v'
      ;;
    python|python3)
      command -v python3 >/dev/null 2>&1 || return 1
      python3 --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
      ;;
    bun)
      command -v bun >/dev/null 2>&1 || return 1
      bun --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1
      ;;
    go)
      command -v go >/dev/null 2>&1 || return 1
      go version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
      ;;
    *) return 1 ;;
  esac
}

# Expand ~ and relative paths to absolute. Empty input → empty output.
oc_expand_path() {
  local p="${1:-}" base home_proj i1 i2
  [[ -n "$p" ]] || return 0
  # Quote patterns — unquoted ~/ in ${p#~/} tilde-expands and fails to strip.
  if [[ "$p" == "~" ]]; then
    p="$HOME"
  elif [[ "$p" == "~/"* ]]; then
    p="${HOME}/${p:2}"
  fi
  if [[ "$p" != /* ]]; then
    p="$(pwd -P)/$p"
  fi
  # Normalize when the path exists; otherwise strip trailing /
  if [[ -d "$p" ]]; then
    p="$(cd "$p" && pwd -P)"
    # macOS APFS is often case-insensitive: pwd -P may return a random spelling.
    # Prefer the conventional ~/Projects path when it is the same inode.
    if [[ "$(uname -s)" == "Darwin" ]]; then
      base="$(basename "$p")"
      home_proj="$HOME/Projects"
      if [[ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" == "projects" && -d "$home_proj" ]]; then
        i1="$(stat -f '%i' "$p" 2>/dev/null || true)"
        i2="$(stat -f '%i' "$home_proj" 2>/dev/null || true)"
        if [[ -n "$i1" && "$i1" == "$i2" ]]; then
          p="$home_proj"
        fi
      fi
    fi
    printf '%s\n' "$p"
  else
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s\n' "$p"
  fi
}

# Read a key from projects.json (projects_dir | default_profile).
oc_projects_config_get() {
  local key="${1:-}"
  local file="${REPO:-}/projects.json"
  [[ -n "$key" && -f "$file" ]] || return 1
  python3 - "$file" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(1)
val = data.get(key)
if val is None or val == "":
    sys.exit(1)
print(val)
PY
}

# Canonical projects home for `oc new`.
# Precedence: OC_PROJECTS_DIR env → .env → projects.json → ~/Projects
oc_projects_dir() {
  local raw=""
  if [[ -n "${OC_PROJECTS_DIR:-}" ]]; then
    raw="$OC_PROJECTS_DIR"
  elif [[ -n "${REPO:-}" && -f "$REPO/.env" ]]; then
    raw="$(oc_get_env_key "$REPO/.env" OC_PROJECTS_DIR 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    raw="$(oc_projects_config_get projects_dir 2>/dev/null || true)"
  fi
  [[ -n "$raw" ]] || raw="~/Projects"
  oc_expand_path "$raw"
}

# Default profile name for scaffolds (high unless overridden).
oc_default_profile() {
  local p="${OC_DEFAULT_PROFILE:-}"
  if [[ -z "$p" && -n "${REPO:-}" && -f "$REPO/.env" ]]; then
    p="$(oc_get_env_key "$REPO/.env" OC_DEFAULT_PROFILE 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]]; then
    p="$(oc_projects_config_get default_profile 2>/dev/null || true)"
  fi
  printf '%s\n' "${p:-high}"
}

# Ensure the projects directory exists. Prints the absolute path.
oc_ensure_projects_dir() {
  local dir
  dir="$(oc_projects_dir)"
  mkdir -p "$dir"
  oc_expand_path "$dir"
}

# Subdirectory name under projects home used by `oc launch` redirects.
oc_default_workspace_name() {
  local name="${OC_DEFAULT_WORKSPACE:-}"
  if [[ -z "$name" && -n "${REPO:-}" && -f "$REPO/.env" ]]; then
    name="$(oc_get_env_key "$REPO/.env" OC_DEFAULT_WORKSPACE 2>/dev/null || true)"
  fi
  if [[ -z "$name" ]]; then
    name="$(oc_projects_config_get default_workspace 2>/dev/null || true)"
  fi
  name="$(basename "${name:-workspace}")"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    name="workspace"
  fi
  printf '%s\n' "$name"
}

# Ensure a clean launch workspace subdirectory under the projects home.
# Creates AGENTS.md + project opencode.json when missing; scrubs install strays.
# Prints absolute path. Never returns the bare projects home.
oc_ensure_launch_workspace() {
  local home name dest profile
  # Need REPO for project opencode.json scaffolding
  if [[ -z "${REPO:-}" || ! -f "${REPO:-}/opencode.json" ]]; then
    if declare -F oc_resolve_repo >/dev/null 2>&1; then
      oc_resolve_repo 2>/dev/null || true
    fi
  fi
  if [[ -z "${REPO:-}" || ! -f "${REPO:-}/opencode.json" ]]; then
    local link="${OC_CONFIG_LINK:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
    if [[ -d "$link" && -f "$link/opencode.json" ]]; then
      REPO="$(cd "$link" && pwd -P)"
      export REPO
    fi
  fi
  home="$(oc_ensure_projects_dir)"
  name="$(oc_default_workspace_name)"
  dest="${home}/${name}"
  mkdir -p "$dest"
  if declare -F oc_scrub_config_strays >/dev/null 2>&1; then
    oc_scrub_config_strays "$dest" >/dev/null 2>&1 || true
  fi
  if [[ ! -f "$dest/AGENTS.md" ]]; then
    cat >"$dest/AGENTS.md" <<EOF
# ${name}

Scratch workspace for \`oc launch\` (OpenConfig). Edit freely — this is not the config repo.
EOF
  fi
  # Empty skills fence — OpenCode warns on missing ./skills every launch otherwise
  if [[ ! -d "$dest/skills" ]]; then
    mkdir -p "$dest/skills"
    : >"$dest/skills/.gitkeep"
  fi
  profile="$(oc_default_profile)"
  if [[ ! -f "$dest/opencode.json" && -n "${REPO:-}" && -f "${REPO}/profiles/${profile}.json" ]]; then
    if ! oc_write_project_opencode_json "$profile" "$dest/opencode.json" 2>/dev/null; then
      # Fallback: minimal project config pointing at global schema
      printf '%s\n' '{' \
        '  "$schema": "https://opencode.ai/config.json",' \
        '  "instructions": ["AGENTS.md"]' \
        '}' >"$dest/opencode.json"
    fi
  fi
  if [[ ! -f "$dest/.gitignore" ]]; then
    printf '%s\n' \
      'node_modules/' 'package.json' 'package-lock.json' 'bun.lock' 'bun.lockb' \
      '.omo/' '.sisyphus/' '.env' '.DS_Store' \
      >"$dest/.gitignore"
  fi
  oc_expand_path "$dest"
}

# True if path is exactly the projects home (not a subdirectory).
oc_is_projects_home() {
  local path="${1:-}" projects
  [[ -n "$path" && -d "$path" ]] || return 1
  path="$(cd "$path" && pwd -P)"
  projects="$(oc_projects_dir)"
  oc_same_path "$path" "$projects"
}

# True if $1 is the OpenConfig config tree (repo or ~/.config/opencode link target)
# or a path inside it. Launching OpenCode there drops package.json/node_modules
# into the config-only repo — never do that by default.
oc_is_under_config_tree() {
  local path="${1:-}"
  local repo_abs="" link_abs="" link="${OC_CONFIG_LINK:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
  [[ -n "$path" ]] || return 1
  path="$(oc_expand_path "$path" 2>/dev/null || printf '%s' "$path")"
  if [[ -d "$path" ]]; then
    path="$(cd "$path" && pwd -P)"
  elif [[ -e "$path" ]]; then
    path="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  fi
  if [[ -n "${REPO:-}" && -d "${REPO:-}" ]]; then
    repo_abs="$(cd "$REPO" && pwd -P)"
  fi
  if [[ -L "$link" || -d "$link" ]]; then
    link_abs="$(cd "$link" 2>/dev/null && pwd -P || true)"
  fi
  if [[ -n "$repo_abs" && ( "$path" == "$repo_abs" || "$path" == "$repo_abs"/* ) ]]; then
    return 0
  fi
  if [[ -n "$link_abs" && ( "$path" == "$link_abs" || "$path" == "$link_abs"/* ) ]]; then
    return 0
  fi
  return 1
}

# Resolve where OpenCode should start.
# Usage: oc_resolve_launch_dir [path] [force]
#   path   — optional directory (default: cwd)
#   force  — if "force", allow starting inside the config tree
# Prints absolute path on stdout.
# Redirects config-tree OR bare projects-home targets to
# projects_dir/default_workspace (unless force). Messages go to stderr.
oc_resolve_launch_dir() {
  local requested="${1:-}" force="${2:-}"
  local candidate workspace
  if [[ -n "$requested" ]]; then
    candidate="$(oc_expand_path "$requested")"
  else
    candidate="$(pwd -P)"
  fi
  if [[ ! -d "$candidate" ]]; then
    echo "oc: not a directory: $candidate" >&2
    return 1
  fi
  candidate="$(cd "$candidate" && pwd -P)"
  if [[ "$force" == "force" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Config repo → clean workspace subdirectory (never bare ~/Projects)
  if oc_is_under_config_tree "$candidate"; then
    workspace="$(oc_ensure_launch_workspace)" || return 1
    printf 'oc: refusing to start OpenCode inside the config repo\n' >&2
    printf 'oc:   was: %s\n' "$candidate" >&2
    printf 'oc:   now: %s  (override: oc launch --here)\n' "$workspace" >&2
    printf '%s\n' "$workspace"
    return 0
  fi
  # Bare projects home is not a project — use the workspace subdirectory
  if oc_is_projects_home "$candidate"; then
    workspace="$(oc_ensure_launch_workspace)" || return 1
    printf 'oc: projects home is not a launch target — using workspace\n' >&2
    printf 'oc:   was: %s\n' "$candidate" >&2
    printf 'oc:   now: %s\n' "$workspace" >&2
    printf '%s\n' "$workspace"
    return 0
  fi
  printf '%s\n' "$candidate"
}

# Write a project-local opencode.json from a global profile, rewriting
# instructions[] to project AGENTS.md + absolute paths into this config repo.
# Usage: oc_write_project_opencode_json <profile> <dest_file>
oc_write_project_opencode_json() {
  local profile="${1:-}"
  local dest="${2:-}"
  local src="${REPO:-}/profiles/${profile}.json"
  [[ -n "$profile" && -n "$dest" && -f "$src" && -n "${REPO:-}" ]] || return 1
  python3 - "$src" "$dest" "$REPO" "$profile" <<'PY'
import json, os, sys

src, dest, repo, profile = sys.argv[1:5]
with open(src, encoding="utf-8") as f:
    data = json.load(f)

instructions = ["AGENTS.md"]
core = os.path.join(repo, "prompts", "core.md")
if os.path.isfile(core):
    instructions.append(core)
prompt = os.path.join(repo, "prompts", "profiles", f"{profile}.md")
if os.path.isfile(prompt):
    instructions.append(prompt)
data["instructions"] = instructions

# Keep schema pointing at the public OpenCode schema (same as profiles).
os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
with open(dest, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}


# ── Distribution host (encoded) ──────────────────────────────────────
# signature.json github_b64 holds the clone base URL. Kept encoded so the
# tree has no distribution-host owner literals; decode only at runtime.
oc_github_url() {
  local sig="${1:-${REPO:?}/signature.json}"
  python3 - "$sig" <<'PY'
import base64, json, sys
sig = json.load(open(sys.argv[1], encoding="utf-8"))
b64 = (sig.get("github_b64") or "").strip()
if not b64:
    sys.stderr.write("oc: signature.json missing github_b64\n")
    sys.exit(2)
print(base64.b64decode(b64).decode("ascii").rstrip("/"))
PY
}

# Clone URL (…/repo.git)
oc_github_clone_url() {
  local base
  base="$(oc_github_url "${1:-}")" || return $?
  if [[ "$base" == *.git ]]; then
    printf '%s\n' "$base"
  else
    printf '%s.git\n' "$base"
  fi
}

# Raw content URL: oc_github_raw_url [signature.json] <ref/path>  e.g. main/install.sh
oc_github_raw_url() {
  local sig refpath base owner_repo
  if [[ $# -ge 2 ]]; then
    sig="$1"
    refpath="$2"
  else
    sig="${REPO:?}/signature.json"
    refpath="${1:?ref/path required}"
  fi
  base="$(oc_github_url "$sig")" || return $?
  base="${base%.git}"
  owner_repo="${base#*github.com/}"
  owner_repo="${owner_repo#/}"
  printf 'https://raw.githubusercontent.com/%s/%s\n' "$owner_repo" "$refpath"
}

# ── Project identity signature ───────────────────────────────────────
# signature.json proves this tree is OpenConfig (openconfig/opencode-configs),
# not a random OpenCode clone. Fingerprint covers files[]; markers cover branding.

# Compute fingerprint for REPO (or $1). Prints sha256 hex (no prefix).
oc_signature_compute() {
  local root="${1:-${REPO:?}}"
  python3 - "$root" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
sig_path = os.path.join(root, "signature.json")
if not os.path.isfile(sig_path):
    sys.stderr.write("oc: signature.json missing\n")
    sys.exit(2)
sig = json.load(open(sig_path, encoding="utf-8"))
files = sig.get("files") or []
if not files:
    sys.stderr.write("oc: signature.json files[] empty\n")
    sys.exit(2)
lines = []
for rel in files:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        sys.stderr.write(f"oc: signature file missing: {rel}\n")
        sys.exit(2)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    lines.append(f"{rel}={h.hexdigest()}")
lines.sort()
blob = "\n".join(lines).encode("utf-8") + b"\n"
print(hashlib.sha256(blob).hexdigest())
PY
}

# Verify markers + fingerprint. Args: [root]
# Prints: ok|<id>|<shortfp>   or   fail|<reason>
# Exit 0 ok, 1 fail, 2 missing tooling/file
oc_verify_signature() {
  local root="${1:-${REPO:?}}"
  python3 - "$root" <<'PY'
import hashlib, json, os, sys

root = sys.argv[1]
sig_path = os.path.join(root, "signature.json")

def fail(msg):
    print(f"fail|{msg}")
    sys.exit(1)

if not os.path.isfile(sig_path):
    fail("signature.json missing — not an OpenConfig tree?")

try:
    sig = json.load(open(sig_path, encoding="utf-8"))
except Exception as e:
    fail(f"signature.json invalid JSON ({e})")

if sig.get("product") != "OpenConfig":
    fail(f"product={sig.get('product')!r} (expected OpenConfig)")
if sig.get("cli") != "oc":
    fail(f"cli={sig.get('cli')!r} (expected oc)")
sid = sig.get("id") or ""
if sid != "openconfig/opencode-configs":
    fail(f"id={sid!r} (expected openconfig/opencode-configs)")

for m in sig.get("markers") or []:
    rel = m.get("path") or ""
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        fail(f"marker missing: {rel}")
    if "json" in m:
        try:
            data = json.load(open(path, encoding="utf-8"))
        except Exception as e:
            fail(f"{rel}: invalid JSON ({e})")
        for k, want in (m.get("json") or {}).items():
            if data.get(k) != want:
                fail(f"{rel}: {k}={data.get(k)!r} ≠ {want!r}")
    body = None
    for needle in m.get("contains") or []:
        if body is None:
            body = open(path, encoding="utf-8", errors="replace").read()
        if needle not in body:
            fail(f"{rel}: missing marker {needle!r}")

files = sig.get("files") or []
if not files:
    fail("files[] empty")
lines = []
for rel in files:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        fail(f"fingerprint file missing: {rel}")
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    lines.append(f"{rel}={h.hexdigest()}")
lines.sort()
blob = "\n".join(lines).encode("utf-8") + b"\n"
got = hashlib.sha256(blob).hexdigest()
want = (sig.get("fingerprint") or "").strip().lower()
if want.startswith("sha256:"):
    want = want[7:]
if not want:
    fail("fingerprint empty — run: oc signature --refresh")
if got != want:
    fail(f"fingerprint mismatch (got {got[:12]}… want {want[:12]}…) — wrong project or dirty tree; refresh if intentional: oc signature --refresh")

vpath = os.path.join(root, "versions.json")
if os.path.isfile(vpath):
    try:
        v = json.load(open(vpath, encoding="utf-8"))
        if v.get("product") != "OpenConfig" or v.get("cli") != "oc":
            fail("versions.json product/cli drift from OpenConfig/oc")
    except Exception:
        fail("versions.json unreadable")

print(f"ok|{sid}|{got[:12]}")
sys.exit(0)
PY
}

# OmO plugin cache path for a pin like oh-my-openagent@4.19.1
oc_omo_plugin_cache_dir() {
  local pin="${1:-}"
  if [[ -z "$pin" ]]; then
    pin="$(python3 -c "import json,os; p=os.path.join('${REPO:-.}','opencode.json'); xs=[x for x in json.load(open(p)).get('plugin',[]) if 'oh-my-openagent@' in x]; print(xs[0] if xs else '')" 2>/dev/null || true)"
  fi
  [[ -n "$pin" ]] || return 1
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/opencode/packages/$pin"
}

# True when the pin's cache has a real oh-my-openagent install (not an empty dir).
oc_omo_plugin_cache_ok() {
  local pin="${1:-}" cdir pkg
  cdir="$(oc_omo_plugin_cache_dir "$pin")" || return 1
  pkg="$cdir/node_modules/oh-my-openagent/package.json"
  [[ -f "$pkg" ]]
}

# Pre-install oh-my-openagent + platform binary into OpenCode's plugin cache.
# Do NOT run postinstall.mjs — it calls invalidateOpenCodePluginCache() and deletes the dir.
# Returns 0 when cache is healthy after (or already was).
oc_ensure_omo_plugin_cache() {
  local pin ver cdir platform_pkg uname_s uname_m
  pin="$(python3 -c "import json,os; p=os.path.join('${REPO:-.}','opencode.json'); xs=[x for x in json.load(open(p)).get('plugin',[]) if 'oh-my-openagent@' in x]; print(xs[0] if xs else '')" 2>/dev/null || true)"
  if [[ -z "$pin" ]]; then
    echo "oc: no oh-my-openagent@… pin in opencode.json" >&2
    return 1
  fi
  ver="${pin#oh-my-openagent@}"
  cdir="$(oc_omo_plugin_cache_dir "$pin")" || return 1
  if oc_omo_plugin_cache_ok "$pin"; then
    return 0
  fi
  if ! command -v bun >/dev/null 2>&1; then
    echo "oc: bun required to install plugin cache for $pin" >&2
    return 1
  fi
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "${uname_s}-${uname_m}" in
    Darwin-arm64)  platform_pkg="oh-my-openagent-darwin-arm64" ;;
    Darwin-x86_64) platform_pkg="oh-my-openagent-darwin-x64" ;;
    Linux-x86_64)  platform_pkg="oh-my-openagent-linux-x64" ;;
    Linux-aarch64) platform_pkg="oh-my-openagent-linux-arm64" ;;
    *)
      echo "oc: unsupported platform ${uname_s}-${uname_m} for OmO binary" >&2
      return 1
      ;;
  esac
  # Wipe empty/partial cache so bun install is clean
  rm -rf "$cdir"
  mkdir -p "$cdir"
  cat > "$cdir/package.json" <<PKGJSON
{
  "name": "oh-my-openagent-cache",
  "private": true,
  "dependencies": {
    "oh-my-openagent": "$ver",
    "$platform_pkg": "$ver"
  }
}
PKGJSON
  if [[ -n "${REPO:-}" && -f "$REPO/bunfig.toml" ]]; then
    cp "$REPO/bunfig.toml" "$cdir/bunfig.toml"
  fi
  if ! ( cd "$cdir" && bun install ); then
    echo "oc: bun install failed for $pin → $cdir" >&2
    return 1
  fi
  if ! oc_omo_plugin_cache_ok "$pin"; then
    echo "oc: plugin cache still missing node_modules/oh-my-openagent after install ($pin)" >&2
    return 1
  fi
  return 0
}

# Write fingerprint into signature.json (maintainer). Prints new fingerprint.
oc_signature_refresh() {
  local root="${1:-${REPO:?}}"
  local fp
  fp="$(oc_signature_compute "$root")" || return $?
  python3 - "$root" "$fp" <<'PY'
import json, os, sys
root, fp = sys.argv[1], sys.argv[2]
path = os.path.join(root, "signature.json")
sig = json.load(open(path, encoding="utf-8"))
sig["fingerprint"] = fp
ver_path = os.path.join(root, "versions.json")
if os.path.isfile(ver_path):
    try:
        v = json.load(open(ver_path, encoding="utf-8"))
        if v.get("opencode_configs"):
            sig["version"] = str(v["opencode_configs"])
        if v.get("tagline"):
            sig["tagline"] = str(v["tagline"])
    except Exception:
        pass
with open(path, "w", encoding="utf-8") as f:
    json.dump(sig, f, indent=2)
    f.write("\n")
print(fp)
PY
}
