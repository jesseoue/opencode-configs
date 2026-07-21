#!/bin/bash
# openrouter-admin.sh — OpenRouter admin dashboard + live health analysis
# Usage: ~/.config/opencode/openrouter-admin.sh [command]
#
# Commands:
#   status    — Account overview (credits, keys, spend, rate limits)
#   keys      — List all API keys with usage + rate limit analysis
#   credits   — Credit balance + projection
#   alert     — Check if credits below threshold (default $50)
#   health    — Live probe all configured models + rate limit check
#   ratelimit — Check current rate limit headers + remaining quota
#   models    — Show configured models with live routing + pricing
#   whoami    — Show account identity + plan + limits

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

ENV_FILE="${REPO}/.env"
oc_export_env_file "$ENV_FILE"

API_KEY="${OPENROUTER_API_KEY:-}"
MGMT_KEY="${OPENROUTER_MGMT_KEY:-}"

c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_0="\033[0m"
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: OPENROUTER_API_KEY not set in .env"
  echo "  Get one at https://openrouter.ai/keys"
  echo "  Tip: quote values with & # or spaces — scripts never source .env"
  exit 1
fi

get_credits() {
  curl -s -H "Authorization: Bearer $API_KEY" https://openrouter.ai/api/v1/credits 2>/dev/null
}

cmd="${1:-status}"

case "$cmd" in

  whoami)
    echo -e "${c_b}═══ Account Identity ═══${c_0}"
    echo ""
    get_credits | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
print(f'  Total credits:   \${d[\"total_credits\"]:.2f}')
print(f'  Total usage:     \${d[\"total_usage\"]:.2f}')
remaining = d['total_credits'] - d['total_usage']
print(f'  Remaining:        \${remaining:.2f}')
" 2>&1 || bad "Failed to get account info"
    echo ""
    if [[ -n "$MGMT_KEY" ]]; then
      ok "Management key set — can manage API keys"
    else
      info "No management key — key management disabled"
    fi
    ;;

  credits)
    echo -e "${c_b}═══ Credit Balance ═══${c_0}"
    echo ""
    get_credits | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
total = d['total_credits']
used = d['total_usage']
remaining = total - used
pct = (remaining / total * 100) if total > 0 else 0
print(f'  Total credits:  \${total:.2f}')
print(f'  Total usage:    \${used:.2f}')
print(f'  Remaining:      \${remaining:.2f} ({pct:.1f}%)')
print()
if remaining < 10:
    print('  ⚠ CRITICAL — less than \$10 remaining')
elif remaining < 50:
    print('  ⚠ LOW — less than \$50 remaining')
else:
    print('  ✓ Healthy')
"
    ;;

  keys)
    if [[ -z "$MGMT_KEY" ]]; then
      echo "ERROR: OPENROUTER_MGMT_KEY not set — cannot list keys"
      exit 1
    fi
    echo -e "${c_b}═══ API Keys ═══${c_0}"
    echo ""
    curl -s -H "Authorization: Bearer $MGMT_KEY" https://openrouter.ai/api/v1/keys | python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = data.get('data', [])
print(f'  Total keys: {len(keys)}')
print()
for k in sorted(keys, key=lambda x: x.get('usage', 0), reverse=True):
    label = k.get('label', '?')
    usage = k.get('usage', 0)
    daily = k.get('usage_daily', 0)
    weekly = k.get('usage_weekly', 0)
    monthly = k.get('usage_monthly', 0)
    limit = k.get('limit')
    remaining = k.get('limit_remaining')
    expires = k.get('expires_at', 'never')
    disabled = k.get('disabled', False)
    status = 'DISABLED' if disabled else 'active'
    print(f'  {label} ({status})')
    print(f'    total:    \${usage:.2f}')
    print(f'    daily:    \${daily:.4f}')
    print(f'    weekly:   \${weekly:.2f}')
    print(f'    monthly:  \${monthly:.2f}')
    if limit:
        pct = (remaining / limit * 100) if limit > 0 else 0
        print(f'    limit:    \${limit:.2f} (remaining: \${remaining:.2f}, {pct:.1f}%)')
        if remaining < 5:
            print(f'    ⚠ KEY LIMIT LOW')
    if expires and expires != 'never':
        print(f'    expires:  {expires}')
    print()
"
    ;;

  health)
    echo -e "${c_b}═══ OpenRouter Health Check ═══${c_0}"
    echo ""
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" \
      https://openrouter.ai/api/v1/credits 2>/dev/null)
    if [ "$http_code" != "200" ]; then
      bad "API key invalid or OpenRouter down (HTTP $http_code)"
      exit 1
    fi
    ok "API key valid (HTTP 200)"
    get_credits | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
remaining = d['total_credits'] - d['total_usage']
if remaining < 10:
    print(f'  ⚠ CRITICAL: \${remaining:.2f} credits remaining')
elif remaining < 50:
    print(f'  ⚠ LOW: \${remaining:.2f} credits remaining')
else:
    print(f'  ✓ \${remaining:.2f} credits remaining')
"
    echo ""
    echo -e "${c_b}── Model Routing Probes ──${c_0}"
    python3 -c "
import json
oc = json.load(open('$REPO/opencode.json'))
models = oc.get('provider', {}).get('openrouter', {}).get('models', {})
for mid in sorted(models.keys()):
    m = models[mid]
    real_id = m.get('id', mid)
    print(f'{mid}|{real_id}')
" | while IFS='|' read -r mid real_id; do
      echo -n "  "
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$real_id\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":16}" \
        "https://openrouter.ai/api/v1/chat/completions" 2>/dev/null)
      if [ "$http_code" = "200" ]; then
        printf "${c_g}✓${c_0} %-35s routes (HTTP 200)\n" "$mid"
      elif [ "$http_code" = "429" ]; then
        printf "${c_y}⚠${c_0} %-35s RATE LIMITED (HTTP 429)\n" "$mid"
      elif [ "$http_code" = "402" ]; then
        printf "${c_r}✗${c_0} %-35s INSUFFICIENT CREDITS (HTTP 402)\n" "$mid"
      else
        printf "${c_r}✗${c_0} %-35s FAILED (HTTP %s)\n" "$mid" "$http_code"
      fi
    done
    echo ""
    echo -e "${c_b}── Rate Limit Headers ──${c_0}"
    curl -sI -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
      "https://openrouter.ai/api/v1/chat/completions" 2>/dev/null \
      | grep -i "x-ratelimit\|retry-after" \
      | while read -r line; do
          echo "  $line" | tr -d '\r'
        done || true

    # Direct OpenAI GPT lane (when key is present)
    echo ""
    echo -e "${c_b}── Direct OpenAI Probes ──${c_0}"
    OPENAI_KEY="${OPENAI_API_KEY:-}"
    if [[ -z "$OPENAI_KEY" ]]; then
      opt "OPENAI_API_KEY not set — GPT lane falls back to OpenRouter"
    else
      python3 -c "
import json
oc = json.load(open('$REPO/opencode.json'))
models = (oc.get('provider') or {}).get('openai', {}).get('models') or {}
for mid in sorted(models.keys()):
    print(mid)
" | while read -r mid; do
        [[ -z "$mid" ]] && continue
        echo -n "  "
        http_code=$(curl -s -o /tmp/oc-openai-health.json -w "%{http_code}" \
          -H "Authorization: Bearer $OPENAI_KEY" \
          -H "Content-Type: application/json" \
          -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_completion_tokens\":16}" \
          "https://api.openai.com/v1/chat/completions" 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
          printf "${c_g}✓${c_0} %-35s routes (HTTP 200)\n" "openai/$mid"
        elif [ "$http_code" = "429" ]; then
          printf "${c_y}⚠${c_0} %-35s RATE LIMITED (HTTP 429)\n" "openai/$mid"
        else
          printf "${c_r}✗${c_0} %-35s FAILED (HTTP %s)\n" "openai/$mid" "$http_code"
        fi
      done
    fi
    ;;

  ratelimit)
    echo -e "${c_b}═══ Rate Limit Status ═══${c_0}"
    echo ""
    headers=$(curl -sI -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
      "https://openrouter.ai/api/v1/chat/completions" 2>/dev/null)
    if echo "$headers" | grep -qi "429"; then
      bad "RATE LIMITED (HTTP 429)"
      retry=$(echo "$headers" | grep -i "retry-after" | awk '{print $2}' | tr -d '\r')
      [ -n "$retry" ] && echo "  Retry after: ${retry}s"
    else
      ok "Not rate limited"
    fi
    echo ""
    echo "  Rate limit headers:"
    echo "$headers" | grep -i "x-ratelimit\|retry-after" | while read -r line; do
      echo "    $line" | tr -d '\r'
    done
    ;;

  models)
    echo -e "${c_b}═══ Configured Models ═══${c_0}"
    echo ""
    python3 -c "
import json
oc = json.load(open('$REPO/opencode.json'))
models = oc.get('provider', {}).get('openrouter', {}).get('models', {})
print(f'  {len(models)} models configured:')
print()
for mid in sorted(models.keys()):
    m = models[mid]
    real_id = m.get('id', mid)
    name = m.get('name', '?')
    family = m.get('family', '?')
    ctx = m.get('limit', {}).get('context', '?')
    opts = m.get('options', {}).get('provider', {})
    max_price = opts.get('max_price', {})
    prompt_cap = max_price.get('prompt', '?')
    comp_cap = max_price.get('completion', '?')
    print(f'  {mid}')
    print(f'    name:     {name}')
    print(f'    family:   {family}')
    if isinstance(ctx, int):
        print(f'    context:  {ctx:,}')
    else:
        print(f'    context:  {ctx}')
    print(f'    max_price: prompt=\${prompt_cap}, completion=\${comp_cap}')
    sort = opts.get('sort', 'none')
    if sort != 'none':
        print(f'    sort:     {sort}')
    ignore = opts.get('ignore', [])
    if ignore:
        print(f'    ignore:   {ignore}')
    print()
"
    ;;

  alert)
    threshold="${2:-50}"
    remaining=$(get_credits | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
print(f'{d[\"total_credits\"] - d[\"total_usage\"]:.2f}')
")
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$remaining" "$threshold"; then
      echo "ALERT: Low credits — \$${remaining} remaining (threshold: \$${threshold})"
      exit 1
    else
      echo "OK: \$${remaining} remaining (threshold: \$${threshold})"
    fi
    ;;

  status|*)
    echo -e "${c_b}═══ OpenRouter Account Status ═══${c_0}"
    echo ""
    get_credits | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
total = d['total_credits']
used = d['total_usage']
remaining = total - used
pct = (remaining / total * 100) if total > 0 else 0
print(f'  Credits:     \${remaining:.2f} / \${total:.2f} ({pct:.1f}% remaining)')
print(f'  Usage:       \${used:.2f} total')
if remaining < 10:
    print(f'  ⚠ CRITICAL — less than \$10 remaining')
elif remaining < 50:
    print(f'  ⚠ LOW — less than \$50 remaining')
" 2>&1 || bad "Cannot fetch credits — key may be invalid"
    echo ""
    if [[ -n "$MGMT_KEY" ]]; then
      curl -s -H "Authorization: Bearer $MGMT_KEY" https://openrouter.ai/api/v1/keys | python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = data.get('data', [])
total_daily = sum(k.get('usage_daily', 0) for k in keys)
total_monthly = sum(k.get('usage_monthly', 0) for k in keys)
print(f'  Active keys: {len(keys)}')
print(f'  Daily spend: \${total_daily:.4f}')
print(f'  Monthly:     \${total_monthly:.2f}')
print()
print('  Per-key:')
for k in sorted(keys, key=lambda x: x.get('usage', 0), reverse=True):
    label = k.get('label', '?')
    monthly = k.get('usage_monthly', 0)
    daily = k.get('usage_daily', 0)
    disabled = k.get('disabled', False)
    status = '⚠ DISABLED' if disabled else '✓'
    print(f'    {status} {label}: \${monthly:.2f}/mo, \${daily:.4f}/day')
" 2>&1 || info "Could not fetch key data"
    else
      info "No management key — key usage disabled"
    fi
    echo ""
    python3 -c "
import json
try:
    omo = json.load(open('$REPO/oh-my-openagent.json'))
    mc = omo.get('background_task', {}).get('providerConcurrency', {})
    bt = omo.get('background_task', {})
    dc = bt.get('defaultConcurrency', '?')
    print(f'  Concurrency: {dc} default')
    for m, c in sorted(mc.items(), key=lambda x: x[1], reverse=True):
        short = m.replace('openrouter/', '') if isinstance(m, str) else m
        print(f'    {short}: {c} concurrent')
except:
    print('  (could not read concurrency config)')
" 2>&1
    ;;
esac
