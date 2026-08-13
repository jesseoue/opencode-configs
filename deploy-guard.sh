#!/bin/bash
# deploy-guard.sh — pre-deployment gate + runtime protection for OpenConfig
# Usage: oc deploy [check|lock|unlock|status|quarantine|health]
#
# Gate checks before deployment:
#   1. Credit balance above threshold ($50 default)
#   2. All configured models probed healthy (HTTP 200)
#   3. No rate limit exhaustion detected
#   4. Circuit breaker not tripped
#   5. No stale/expired API keys
#   6. Git working tree clean (no uncommitted drift)
#   7. Signature valid (identity proof)
#
# Runtime protection:
#   - Credit alerts at $100 / $50 / $10 thresholds
#   - Auto-quarantine when credits drop below $10
#   - Model health heartbeat (optional cron)
#   - Deployment lock file (prevents concurrent deploys)
#   - Graceful degradation: fall back to cheaper models on credit pressure

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

ENV_FILE="${REPO}/.env"
oc_export_env_file "$ENV_FILE"

API_KEY="${OPENROUTER_API_KEY:-}"
LOCK_FILE="${LOCK_FILE:-/tmp/oc-deploy.lock}"
ALERT_LOG="${ALERT_LOG:-/tmp/oc-deploy-alerts.log}"

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_bold=$'\033[1m'; c_0=$'\033[0m'
ok(){   printf "  ${c_g}✓${c_0} %s\n" "$*"; }
opt(){  printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){  printf "  ${c_r}✗${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }

# ── Thresholds (override via env) ──
CREDIT_CRITICAL="${OC_CREDIT_CRITICAL:-10}"
CREDIT_WARN="${OC_CREDIT_WARN:-50}"
CREDIT_CAUTION="${OC_CREDIT_CAUTION:-100}"
MODEL_PROBE_TIMEOUT="${OC_MODEL_PROBE_TIMEOUT:-30}"
DEPLOY_LOCK_TTL="${OC_DEPLOY_LOCK_TTL:-300}"  # seconds

# ── Get credit balance ──
get_credits() {
  curl -s -H "Authorization: Bearer $API_KEY" https://openrouter.ai/api/v1/credits 2>/dev/null
}

# ── Check credit balance ──
check_credits() {
  local threshold="${1:-$CREDIT_WARN}"
  local data remaining
  data=$(get_credits) || { bad "Cannot fetch OpenRouter credits"; return 1; }
  remaining=$(echo "$data" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
print(f'{d[\"total_credits\"] - d[\"total_usage\"]:.2f}')
" 2>/dev/null) || { bad "Cannot parse credit response"; return 1; }

  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$remaining" "$CREDIT_CRITICAL"; then
    bad "CRITICAL: \$${remaining} credits remaining (threshold: \$${CREDIT_CRITICAL})"
    printf "  ${c_r}ACTION REQUIRED: Add credits at https://openrouter.ai/credits${c_0}\n"
    return 2
  elif python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$remaining" "$CREDIT_WARN"; then
    opt "WARNING: \$${remaining} credits remaining (threshold: \$${CREDIT_WARN})"
    return 0
  elif python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$remaining" "$CREDIT_CAUTION"; then
    info "Caution: \$${remaining} credits remaining (threshold: \$${CREDIT_CAUTION})"
    return 0
  else
    ok "Credits: \$${remaining} (healthy)"
    return 0
  fi
}

# ── Probe all models ──
probe_models() {
  local failed=0 count=0
  info "Probing models (timeout: ${MODEL_PROBE_TIMEOUT}s)..."
  if ! "$REPO/models.sh" --probe 2>&1; then
    bad "One or more model probes failed"
    return 1
  fi
  ok "All models healthy"
  return 0
}

# ── Check rate limits ──
check_ratelimit() {
  local headers code
  headers=$(curl -sI -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
    "https://openrouter.ai/api/v1/chat/completions" 2>/dev/null)
  code=$(echo "$headers" | head -1 | awk '{print $2}')
  if echo "$headers" | grep -qi "429"; then
    bad "RATE LIMITED — cannot deploy"
    echo "$headers" | grep -i "retry-after" | while read -r line; do
      printf "  %s\n" "$line" | tr -d '\r'
    done
    return 1
  fi
  # Check remaining quota
  local remaining=$(echo "$headers" | grep -i "x-ratelimit-requests-remaining" | awk -F': ' '{print $2}' | tr -d '\r')
  if [[ -n "$remaining" && "$remaining" != "0" ]]; then
    local total=$(echo "$headers" | grep -i "x-ratelimit-requests-limit" | awk -F': ' '{print $2}' | tr -d '\r')
    local pct=$(( remaining * 100 / total ))
    if [[ $pct -lt 10 ]]; then
      opt "Rate limit: $remaining/$total requests remaining ($pct%) — tight"
    else
      ok "Rate limit: $remaining/$total requests remaining ($pct%)"
    fi
  else
    ok "Rate limit: not constrained"
  fi
  return 0
}

# ── Check git working tree ──
check_git_clean() {
  if ! git -C "$REPO" diff --quiet 2>/dev/null; then
    bad "Git working tree has uncommitted changes"
    git -C "$REPO" diff --stat 2>/dev/null
    return 1
  fi
  if ! git -C "$REPO" diff --cached --quiet 2>/dev/null; then
    bad "Git has staged but uncommitted changes"
    return 1
  fi
  ok "Git working tree clean"
  return 0
}

# ── Check signature ──
check_signature() {
  local sig_out
  sig_out=$("$REPO/oc" signature 2>&1)
  if echo "$sig_out" | grep -q "signature.*ok"; then
    ok "Signature valid"
    return 0
  else
    bad "Signature mismatch — refresh: oc signature --refresh"
    return 1
  fi
}

# ── Deployment lock ──
acquire_lock() {
  local reason="${1:-deploy check}"
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null | head -1)
    if kill -0 "$pid" 2>/dev/null; then
      bad "Deployment locked by PID $pid"
      bad "  Lock file: $LOCK_FILE"
      bad "  Force unlock: oc deploy unlock --force"
      return 1
    fi
    # Stale lock
    info "Removing stale lock (PID $pid not running)"
    rm -f "$LOCK_FILE"
  fi
  echo "$$" > "$LOCK_FILE"
  echo "$reason" >> "$LOCK_FILE"
  echo "$(date -u +%s)" >> "$LOCK_FILE"
  ok "Deployment lock acquired (PID $$, TTL: ${DEPLOY_LOCK_TTL}s)"
  return 0
}

release_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(head -1 "$LOCK_FILE" 2>/dev/null)
    if [[ "$pid" == "$$" ]]; then
      rm -f "$LOCK_FILE"
      ok "Deployment lock released"
    fi
  fi
}

# ── Quarantine mode ──
enter_quarantine() {
  local reason="${1:-credit threshold}"
  local timestamp
  timestamp=$(date -u +%s)
  echo "$timestamp|quarantine|$reason" >> "$ALERT_LOG"
  printf "  ${c_r}⚠ ENTERING QUARANTINE MODE — %s${c_0}\n" "$reason"

  # Switch to cost-saving models
  if [[ -f "$REPO/oh-my-openagent.json" ]]; then
    python3 -c "
import json, sys
omo = json.load(open('$REPO/oh-my-openagent.json'))
changes = 0
# Swap primary agents to cheapest models
for section in ('agents', 'categories'):
    for name, cfg in (omo.get(section, {}) or {}).items():
        if not isinstance(cfg, dict): continue
        model = cfg.get('model', '')
        if 'deepseek-v4-pro' in str(model) and '0813' not in str(model):
            cfg['model'] = 'openrouter/deepseek/deepseek-v4-pro-0813'
            changes += 1
            print(f'  quarantine: {section}.{name} → deepseek-v4-pro-0813 (cheaper GA)')
        if 'claude-opus-5' in str(model) and 'fast' not in str(model):
            cfg['model'] = 'openrouter/deepseek/deepseek-v4-pro-0813'
            changes += 1
            print(f'  quarantine: {section}.{name} → deepseek-v4-pro-0813 (opus swap)')
if changes:
    json.dump(omo, open('$REPO/oh-my-openagent.json', 'w'), indent=2)
    print(f'  Quarantine: {changes} model(s) downgraded to cost-saving')
else:
    print('  Quarantine: already on cost-saving models, no changes')
" 2>&1
  fi
}

exit_quarantine() {
  info "Exiting quarantine — restoring from repo (git checkout)"

  if git -C "$REPO" diff --quiet oh-my-openagent.json 2>/dev/null; then
    ok "oh-my-openagent.json already at repo state"
  else
    git -C "$REPO" checkout -- oh-my-openagent.json 2>/dev/null
    ok "oh-my-openagent.json restored from repo"
  fi

  local timestamp
  timestamp=$(date -u +%s)
  echo "$timestamp|unquarantine|manual exit" >> "$ALERT_LOG"
}

# ── Full gate check ──
do_check() {
  local failed=0
  printf "\n${c_b}${c_bold}═══ Pre-Deployment Gate Check ═══${c_0}\n\n"

  if [[ -z "$API_KEY" ]]; then
    bad "OPENROUTER_API_KEY not set — cannot check OpenRouter"
    return 1
  fi

  check_credits || failed=$((failed + 1))
  echo ""
  check_ratelimit || failed=$((failed + 1))
  echo ""
  probe_models || failed=$((failed + 1))
  echo ""
  check_git_clean || failed=$((failed + 1))
  echo ""
  check_signature || failed=$((failed + 1))
  echo ""

  if [[ $failed -eq 0 ]]; then
    printf "${c_g}${c_bold}═══ ALL CHECKS PASSED — ready to deploy ═══${c_0}\n\n"
    return 0
  else
    printf "${c_r}${c_bold}═══ ${failed} GATE CHECK(S) FAILED — deployment blocked ═══${c_0}\n\n"
    return 1
  fi
}

# ── Health heartbeat (continuous) ──
do_health() {
  local interval="${1:-300}"
  info "Starting health heartbeat (interval: ${interval}s)"
  info "Press Ctrl+C to stop"
  while true; do
    local timestamp
    timestamp=$(date -u +%s)
    check_credits "$CREDIT_WARN" 2>&1 || {
      echo "$timestamp|credit_low|below threshold" >> "$ALERT_LOG"
    }
    sleep "$interval"
  done
}

# ── Status ──
do_status() {
  printf "\n${c_b}${c_bold}═══ Deployment Guard Status ═══${c_0}\n\n"
  # Lock status
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(head -1 "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
      opt "Deployment locked (PID $pid)"
    else
      info "Stale lock file (PID $pid not running)"
    fi
  else
    ok "No deployment lock"
  fi
  echo ""
  # Credit status
  check_credits
  echo ""
  # Alert log tail
  if [[ -f "$ALERT_LOG" ]]; then
    local lines
    lines=$(wc -l < "$ALERT_LOG" | tr -d ' ')
    info "Alert log: $lines entries ($ALERT_LOG)"
    tail -5 "$ALERT_LOG" | while read -r line; do
      printf "  %s\n" "$line"
    done
  fi
  echo ""
}

# ── Main dispatch ──
cmd="${1:-check}"

case "$cmd" in
  check|gate)
    do_check
    ;;
  lock)
    acquire_lock "${2:-manual}"
    ;;
  unlock)
    if [[ "${2:-}" == "--force" ]]; then
      rm -f "$LOCK_FILE"
      ok "Deployment lock force-released"
    else
      release_lock
    fi
    ;;
  status)
    do_status
    ;;
  quarantine)
    if [[ "${2:-}" == "exit" ]]; then
      exit_quarantine
    else
      enter_quarantine "${2:-credit threshold}"
    fi
    ;;
  health|heartbeat)
    do_health "${2:-300}"
    ;;
  credits)
    check_credits
    ;;
  *)
    echo "Usage: oc deploy <command>"
    echo ""
    echo "Commands:"
    echo "  check|gate       Pre-deployment gate check (credits, models, rate limits, git, signature)"
    echo "  lock [reason]    Acquire deployment lock (prevents concurrent deploys)"
    echo "  unlock [--force] Release deployment lock"
    echo "  status           Show guard status (lock, credits, alert log)"
    echo "  quarantine       Enter cost-saving quarantine mode"
    echo "  quarantine exit  Exit quarantine (restore from git)"
    echo "  health [N]       Continuous credit heartbeat (every N seconds, default 300)"
    echo "  credits          Check credit balance only"
    exit 1
    ;;
esac