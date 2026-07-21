#!/usr/bin/env bash
# tests/idempotency.sh — Prove writes are skip-if-correct (temp sandbox).
#
# Never touches the live ~/.config/opencode tree. Uses mktemp dirs for
# .env / symlink / zshrc exercises. Also asserts fix.sh is a no-op when clean.
#
# Usage: ./tests/idempotency.sh   |   oc test
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_g="\033[32m"; c_r="\033[31m"; c_b="\033[36m"; c_bold="\033[1m"; c_0="\033[0m"
else
  c_g=""; c_r=""; c_b=""; c_bold=""; c_0=""
fi

pass=0; fail=0
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; pass=$((pass+1)); }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; fail=$((fail+1)); }

printf "\n${c_bold}${c_b}OpenConfig idempotency tests${c_0} (sandbox)\n\n"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/oc-idempotency.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP"' EXIT

# ── 1. .env: never overwrite existing values ──
EXAMPLE="$TMP/example.env"
ENVF="$TMP/.env"
cat >"$EXAMPLE" <<'EOF'
OPENROUTER_API_KEY=
OPENAI_API_KEY=
NEW_KEY_FROM_TEMPLATE=
DO_NOT_TRACK=1
EOF
cat >"$ENVF" <<'EOF'
OPENROUTER_API_KEY=keep-me-secret
CUSTOM_USER_KEY=stay
EOF
chmod 600 "$ENVF"

oc_ensure_env_file "$ENVF" "$EXAMPLE" >/dev/null
v="$(oc_get_env_key "$ENVF" OPENROUTER_API_KEY)"
if [[ "$v" == "keep-me-secret" ]]; then ok "ensure_env_file keeps existing OPENROUTER_API_KEY"
else bad "ensure_env_file clobbered OPENROUTER_API_KEY → $v"; fi

v="$(oc_get_env_key "$ENVF" CUSTOM_USER_KEY)"
if [[ "$v" == "stay" ]]; then ok "ensure_env_file keeps custom keys"
else bad "ensure_env_file lost CUSTOM_USER_KEY"; fi

v="$(oc_get_env_key "$ENVF" NEW_KEY_FROM_TEMPLATE || true)"
# key should exist (possibly empty)
if grep -q '^NEW_KEY_FROM_TEMPLATE=' "$ENVF"; then ok "ensure_env_file adds missing template keys"
else bad "ensure_env_file did not add NEW_KEY_FROM_TEMPLATE"; fi

# if_unset must not clobber
r="$(oc_set_env_key_if_unset "$ENVF" OPENROUTER_API_KEY 'SHOULD_NOT_WIN')"
v="$(oc_get_env_key "$ENVF" OPENROUTER_API_KEY)"
if [[ "$r" == "keep" && "$v" == "keep-me-secret" ]]; then ok "set_env_key_if_unset keeps set values"
else bad "set_env_key_if_unset overwrote ($r / $v)"; fi

r="$(oc_set_env_key_if_unset "$ENVF" BRAND_NEW_KEY 'hello')"
v="$(oc_get_env_key "$ENVF" BRAND_NEW_KEY)"
if [[ "$r" == "set" && "$v" == "hello" ]]; then ok "set_env_key_if_unset writes when empty"
else bad "set_env_key_if_unset failed to set ($r / $v)"; fi

# Second ensure is a no-op on values
before="$(cksum "$ENVF" | awk '{print $1}')"
oc_ensure_env_file "$ENVF" "$EXAMPLE" >/dev/null
oc_set_env_key_if_unset "$ENVF" OPENROUTER_API_KEY 'x' >/dev/null
after="$(cksum "$ENVF" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then ok "second env ensure is checksum-stable"
else bad "env file mutated on second ensure ($before → $after)"; fi

# ── 2. Symlinks: skip if correct; update wrong without nuking target ──
TARGET="$TMP/repo-target"
mkdir -p "$TARGET"
echo ok >"$TARGET/marker"
LINK="$TMP/config-link"

r="$(oc_ensure_symlink "$LINK" "$TARGET" "testlink")"
if [[ "$r" == "created" && -L "$LINK" ]] && oc_link_points_to "$LINK" "$TARGET"; then
  ok "ensure_symlink creates link"
else
  bad "ensure_symlink create failed ($r)"
fi

r="$(oc_ensure_symlink "$LINK" "$TARGET" "testlink")"
if [[ "$r" == "ok" ]]; then ok "ensure_symlink is no-op when correct"
else bad "ensure_symlink rewrote correct link ($r)"; fi

# Wrong link → update (backup path)
OTHER="$TMP/other"; mkdir -p "$OTHER"
ln -sfn "$OTHER" "$LINK"
r="$(oc_ensure_symlink "$LINK" "$TARGET" "testlink")"
if [[ "$r" == "updated" ]] && oc_link_points_to "$LINK" "$TARGET"; then
  ok "ensure_symlink repairs wrong link"
else
  bad "ensure_symlink repair failed ($r)"
fi
# Target content untouched
if [[ -f "$TARGET/marker" ]]; then ok "symlink repair did not overwrite target contents"
else bad "target contents lost"; fi

# Dry-run does not write
rm -f "$LINK"
OC_LINK_DRY=1 r="$(oc_ensure_symlink "$LINK" "$TARGET" "testlink")"
if [[ "$r" == "would_create" && ! -e "$LINK" ]]; then ok "ensure_symlink dry-run writes nothing"
else bad "ensure_symlink dry-run side effect ($r exists=$([[ -e $LINK ]] && echo y || echo n))"; fi
unset OC_LINK_DRY

# ── 3. fix.sh twice when clean ──
out1="$("$REPO/fix.sh" --dry-run 2>&1 || true)"
if printf '%s' "$out1" | grep -q "already clean"; then
  ok "fix --dry-run reports already clean"
else
  # May have real footguns on dirty tree — still check second pass stability via live fix only if clean
  info_skip=1
  bad "fix --dry-run not clean (skipping double-fix assert) — run oc heal first"
fi

if [[ "${info_skip:-0}" -eq 0 ]]; then
  # Live fix should also report clean and not churn mtimes unnecessarily.
  # Capture mtimes before/after when already clean.
  m1="$(stat -f '%m' "$REPO/opencode.json" 2>/dev/null || stat -c '%Y' "$REPO/opencode.json")"
  out2="$("$REPO/fix.sh" 2>&1)"
  m2="$(stat -f '%m' "$REPO/opencode.json" 2>/dev/null || stat -c '%Y' "$REPO/opencode.json")"
  if printf '%s' "$out2" | grep -q "already clean"; then
    ok "fix.sh no-op when clean"
  else
    bad "fix.sh mutated clean configs"
  fi
  if [[ "$m1" == "$m2" ]]; then ok "fix.sh does not touch mtime when clean"
  else bad "fix.sh bumped opencode.json mtime while clean"; fi
fi

# ── 4. setup must not clobber .env via full cp ──
if awk '
  /Step 3: API keys/ {in3=1}
  in3 && /oc_ensure_env_file/ {found=1}
  in3 && /cp "\$REPO\/\.env\.example"/ {bad=1}
  in3 && /^echo ""$/ && NR>1 {exit}
  END { exit(bad ? 1 : (found ? 0 : 2)) }
' "$REPO/setup.sh"; then
  ok "setup.sh Step 3 uses oc_ensure_env_file (no blind overwrite)"
else
  bad "setup.sh Step 3 missing safe env ensure / still overwrites"
fi

# ── 5. Signature rejects a wrong tree ──
FAKE="$TMP/fake-repo"
mkdir -p "$FAKE"
echo '{"product":"Nope","cli":"x","id":"wrong","files":[],"fingerprint":"abc","markers":[]}' >"$FAKE/signature.json"
if out="$(REPO="$FAKE" oc_verify_signature "$FAKE" 2>/dev/null)"; then
  bad "signature accepted a fake tree ($out)"
else
  ok "signature rejects wrong project ($out)"
fi

# Live tree must verify (after maintainers run --refresh)
if out="$(oc_verify_signature "$REPO" 2>/dev/null)"; then
  ok "live signature verifies ($out)"
else
  bad "live signature failed — run: oc signature --refresh ($out)"
fi

# ── 7. Launch dir never defaults to the config repo or bare projects home ──
cd "$REPO" >/dev/null
got="$(oc_resolve_launch_dir 2>/dev/null | tail -1)"
projects="$(oc_projects_dir)"
ws_name="$(oc_default_workspace_name)"
want="${projects}/${ws_name}"
# Normalize via expand for macOS case
want="$(oc_expand_path "$want")"
if [[ "$got" == "$want" ]] && [[ -f "$got/AGENTS.md" ]]; then
  ok "launch from config repo → workspace ($got)"
else
  bad "launch from config repo did not use workspace (got=$got want=$want)"
fi
# Bare projects home also → workspace
home_got="$(oc_resolve_launch_dir "$projects" 2>/dev/null | tail -1)"
if [[ "$home_got" == "$want" ]]; then
  ok "launch from bare projects home → workspace"
else
  bad "bare projects home not redirected (got=$home_got)"
fi
forced="$(oc_resolve_launch_dir "$REPO" force 2>/dev/null | tail -1)"
if [[ "$forced" == "$(cd "$REPO" && pwd -P)" ]]; then
  ok "launch --here keeps config repo when forced"
else
  bad "launch force path wrong ($forced)"
fi
# Real project path must pass through (workspace itself is fine)
if [[ -d "$want" ]]; then
  keep="$(oc_resolve_launch_dir "$want" 2>/dev/null | tail -1)"
  if [[ "$keep" == "$(cd "$want" && pwd -P)" ]] || [[ "$keep" == "$want" ]]; then
    ok "launch keeps workspace when already there"
  else
    bad "launch remapped workspace ($keep)"
  fi
fi
cd - >/dev/null 2>&1 || true

# ── 6. Stale inline opencode() migrates to snippet (never wipes the file) ──
ZRC="$TMP/zshrc-stale"
# Pretend a real zshrc (large enough to trip the safety floor if wipe bug returns)
{
  echo "# preamble cockpit"
  for i in $(seq 1 40); do echo "export FAKE_$i=1"; done
  cat <<'Z'
opencode() {
  local x=1
  TERM=xterm-256color command opencode "$@"
}
alias oradmin='~/x'
[[ -d "$HOME/.config/opencode" ]] && [[ ":$PATH:" != *":$HOME/.config/opencode:"* ]] && export PATH="$HOME/.config/opencode:$PATH"
# epilogue
typeset -U path PATH
Z
} >"$ZRC"
before_lines="$(wc -l <"$ZRC" | tr -d ' ')"
if oc_zshrc_inline_stale "$ZRC"; then ok "detects stale inline opencode()"
else bad "failed to detect stale inline"; fi
msg="$(oc_ensure_zshrc_snippet "$ZRC")"
after_lines="$(wc -l <"$ZRC" | tr -d ' ')"
if grep -qF 'source ~/.config/opencode/zshrc.snippet' "$ZRC" \
  && ! grep -qE '^[[:space:]]*opencode[[:space:]]*\(\)' "$ZRC" \
  && grep -q 'preamble cockpit' "$ZRC" \
  && [[ "$after_lines" -gt 30 ]]; then
  ok "migrates stale inline → snippet (kept $after_lines/$before_lines lines; $msg)"
else
  bad "stale inline migration failed or wiped file (lines $before_lines→$after_lines; $msg)"
fi
# Second pass is idempotent
msg2="$(oc_ensure_zshrc_snippet "$ZRC")"
n="$(grep -cF 'source ~/.config/opencode/zshrc.snippet' "$ZRC" || true)"
if [[ "$n" -eq 1 ]] && printf '%s' "$msg2" | grep -q "already OK"; then
  ok "zshrc snippet ensure is idempotent"
else
  bad "zshrc ensure not idempotent (n=$n msg=$msg2)"
fi
# Copy-backup must not move the live file away
Z2="$TMP/zshrc-copybak"
echo 'opencode() { :; }' >"$Z2"
# Force stale
if oc_backup_copy "$Z2" "zshrc-test" >/dev/null \
  && [[ -f "$Z2" ]] && [[ -f "${OC_BACKUP_PATH:-}" ]]; then
  ok "oc_backup_copy keeps source in place"
else
  bad "oc_backup_copy moved or lost source (backup=${OC_BACKUP_PATH:-})"
fi

printf "\n${c_bold}Result:${c_0} %d passed · %d failed\n\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
