#!/usr/bin/env bash
# Cost-safe regression fixtures for runtime diagnostics. No agent is
# started and no provider/model endpoint is called.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

pass=0 fail=0
ok(){ printf '  ✓ %s\n' "$*"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n' "$*"; fail=$((fail+1)); }
expect_text(){
  local name="$1" text="$2" pattern="$3"
  if printf '%s\n' "$text" | grep -qF "$pattern"; then ok "$name"; else
    bad "$name (missing: $pattern)"
  fi
}

printf '\nOpenConfig runtime diagnostic fixtures (no model calls)\n\n'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oc-runtime-fixtures.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Agent-list fixtures exercise success, missing visibility, and timeout paths.
FAKE="$TMP/fake-opencode"
cat >"$FAKE" <<'SH'
#!/bin/sh
case "${FAKE_AGENT_MODE:-ok}" in
  timeout) sleep 2 ;;
  missing) printf 'lead (primary)\n' ;;
  *) for f in "$FAKE_AGENTS"/*.md; do n="${f##*/}"; printf '%s (primary)\n' "${n%.md}"; done ;;
esac
SH
chmod +x "$FAKE"
export FAKE_AGENTS="$REPO/agents"
out="$(FAKE_AGENT_MODE=ok oc_agent_visibility_report "$FAKE" "$REPO" 1)"
if ! printf '%s\n' "$out" | grep -q '^BAD|' && printf '%s\n' "$out" | grep -q 'without starting a model'; then
  ok "bounded runtime visibility success"
else bad "runtime visibility success fixture"; fi
out="$(FAKE_AGENT_MODE=missing oc_agent_visibility_report "$FAKE" "$REPO" 1)"
expect_text "runtime-visible gap reported" "$out" "declared but not runtime-visible"
out="$(FAKE_AGENT_MODE=timeout oc_agent_visibility_report "$FAKE" "$REPO" 0.1)"
expect_text "runtime probe timeout bounded" "$out" "timed out"

LOG="$TMP/opencode.log"
cat >"$LOG" <<'EOF'
level=ERROR message="Expected a string starting with 'ses'"
EOF
out="$(oc_log_misuse_report "$LOG")"
expect_text "ses misuse remediation" "$out" "requires the real ses_…"

printf '\nResult: %d passed · %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
