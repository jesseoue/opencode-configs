#!/usr/bin/env bash
# maintain.sh — System maintenance: clean stale sessions, prune caches,
# check disk usage, and collect plan strategies for optimization.
#
# Usage: ./maintain.sh [--check] [--clean] [--plans]
#   --check   audit only, don't change anything
#   --clean   archive stale sessions to ~/.opencode-backups/, prune caches
#   --plans   collect and summarize plan strategies from .omo/plans/

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
CHECK=false
CLEAN=false
PLANS=false

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --clean) CLEAN=true ;;
    --plans) PLANS=true ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# Default: run all
if ! $CHECK && ! $CLEAN && ! $PLANS; then
  CHECK=true; PLANS=true
fi

c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_0="\033[0m"
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }

echo -e "${c_b}== OpenConfig (oc) maintenance ==${c_0}"
echo ""

# ─── 1. Stale session cleanup ────────────────────────────────────
echo "Session cleanup:"
SESSIONS_DIR="${OC_SESSIONS_DIR}/sessions"
# Prefer nested sessions/; also support flat share tree
[[ -d "$SESSIONS_DIR" ]] || SESSIONS_DIR="${OC_SESSIONS_DIR}"
if [ -d "$SESSIONS_DIR" ] && [[ "$SESSIONS_DIR" == *opencode* ]]; then
  total=$(find "$SESSIONS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  stale=$(find "$SESSIONS_DIR" -type f -mtime +7 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$SESSIONS_DIR" 2>/dev/null | awk '{print $1}')
  echo "  Total session files: $total ($size)"
  echo "  Stale (>7 days): $stale"
  if $CLEAN && [ "$stale" -gt 0 ]; then
    # Always archive before delete — never destroy sessions without a backup
    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="${OC_BACKUP_ROOT}/sessions-$stamp"
    mkdir -p "$archive"
    find "$SESSIONS_DIR" -type f -mtime +7 -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
          rel="${f#"$SESSIONS_DIR"/}"
          mkdir -p "$archive/$(dirname "$rel")"
          mv "$f" "$archive/$rel"
        done
    ok "Archived $stale stale session file(s) → $archive (not deleted in place)"
  elif [ "$stale" -gt 0 ]; then
    opt "Run --clean to archive $stale stale files under ~/.opencode-backups/ (never hard-deletes)"
  else
    ok "No stale sessions"
  fi
else
  info "No sessions directory found"
fi
echo ""

# ─── 2. Plugin cache check ───────────────────────────────────────
echo "Plugin cache:"
CACHE_DIR="$HOME/.cache/opencode/packages"
if [ -d "$CACHE_DIR" ]; then
  versions=$(ls -1 "$CACHE_DIR" 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
  echo "  Plugin versions cached: $versions ($size)"
  if [ "$versions" -gt 3 ]; then
    opt "Multiple old plugin versions cached — can prune"
    if $CLEAN; then
      # Keep only the latest version
      latest=$(ls -1t "$CACHE_DIR" 2>/dev/null | head -1)
      for old in $(ls -1 "$CACHE_DIR" 2>/dev/null | grep -v "$latest"); do
        rm -rf "$CACHE_DIR/$old"
        ok "Removed old cache: $old"
      done
    fi
  else
    ok "Cache size reasonable"
  fi
else
  info "No plugin cache found"
fi
echo ""

# ─── 3. .omo runtime cleanup ─────────────────────────────────────
echo "Runtime files:"
OMO_DIR="$HOME/.omo"
if [ -d "$OMO_DIR" ]; then
  # Count non-teams files
  runtime=$(find "$OMO_DIR" -type f -not -path "*/teams/*" 2>/dev/null | wc -l | tr -d ' ')
  teams=$(find "$OMO_DIR/teams" -type f 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$OMO_DIR" 2>/dev/null | awk '{print $1}')
  echo "  Runtime files: $runtime ($size)"
  echo "  Team specs: $teams"
  if [ "$runtime" -gt 100 ]; then
    opt "Large runtime dir — consider cleaning"
    if $CLEAN; then
      find "$OMO_DIR" -type f -not -path "*/teams/*" -not -path "*/codegraph/*" -delete 2>/dev/null
      ok "Cleaned runtime files (kept teams + codegraph)"
    fi
  else
    ok "Runtime size reasonable"
  fi
else
  info "No .omo directory"
fi
echo ""

# ─── 4. Log rotation ─────────────────────────────────────────────
echo "Log files:"
LOG_FILE="$HOME/.local/share/opencode/log/opencode.log"
if [ -f "$LOG_FILE" ]; then
  size=$(du -sh "$LOG_FILE" 2>/dev/null | awk '{print $1}')
  lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  errors=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo "0")
  echo "  Log size: $size ($lines lines, $errors errors)"
  if [ "$lines" -gt 50000 ]; then
    opt "Log file large — consider rotating"
    if $CLEAN; then
      tail -10000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
      ok "Log rotated (kept last 10k lines)"
    fi
  else
    ok "Log size reasonable"
  fi
else
  info "No log file found"
fi
echo ""

# ─── 5. Disk usage ───────────────────────────────────────────────
echo "Disk usage:"
repo_size=$(du -sh "$REPO" 2>/dev/null | awk '{print $1}')
echo "  Config repo: $repo_size"
cache_size=$(du -sh "$HOME/.cache/opencode" 2>/dev/null | awk '{print $1}')
echo "  Plugin cache: $cache_size"
sessions_size=$(du -sh "$OC_SESSIONS_DIR" 2>/dev/null | awk '{print $1}')
echo "  Sessions + logs: $sessions_size"
echo ""

# ─── 6. Plan strategies ──────────────────────────────────────────
if $PLANS; then
  echo "Plan strategies:"
  PLANS_DIR=""
  for d in "$REPO/.omo/plans" "$HOME/.omo/plans" "$(pwd)/.omo/plans"; do
    if [ -d "$d" ]; then
      PLANS_DIR="$d"
      break
    fi
  done
  if [ -n "$PLANS_DIR" ] && [ "$(ls -1 "$PLANS_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    count=$(ls -1 "$PLANS_DIR" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Found $count plan(s) in $PLANS_DIR:"
    for f in "$PLANS_DIR"/*.md; do
      [ -f "$f" ] || continue
      name=$(basename "$f" .md)
      # Count checkboxes
      total=$(grep -c '\[.\]' "$f" 2>/dev/null || echo "0")
      done=$(grep -cE '\[x\]|\[•\]' "$f" 2>/dev/null || echo "0")
      echo "    $name: $done/$total tasks done"
    done
  else
    ok "No plans found — clean slate"
  fi
  echo ""

  # Show available team strategies
  echo "  Available team strategies:"
  for d in "$REPO"/teams/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    desc=$(python3 -c "import json; print(json.load(open('$d/config.json')).get('description','')[:60])" 2>/dev/null || echo "")
    echo "    $name: $desc"
  done
  echo ""

  # Show available profiles
  echo "  Available profiles:"
  for f in "$REPO"/profiles/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    model=$(python3 -c "import json; print(json.load(open('$f')).get('model','').replace('openrouter/',''))" 2>/dev/null || echo "?")
    agent=$(python3 -c "import json; print(json.load(open('$f')).get('default_agent','?'))" 2>/dev/null || echo "?")
    echo "    $name: model=$model, agent=$agent"
  done
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────
echo -e "${c_g}Maintenance complete.${c_0}"
$CHECK && ! $CLEAN && echo "Run with --clean to apply fixes."
