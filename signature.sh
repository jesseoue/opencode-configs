#!/usr/bin/env bash
# signature.sh — Verify / refresh OpenConfig project identity.
#
# Proves this tree is openconfig/opencode-configs (OpenConfig / oc), not a
# random OpenCode config clone. Markers check branding; fingerprint hashes
# a stable file list in signature.json.
#
# Usage:
#   ./signature.sh                 verify (default)
#   ./signature.sh verify
#   ./signature.sh --refresh       recompute fingerprint after intentional edits
#   ./signature.sh --json          machine-readable verify result
#   oc signature [--refresh|--json]
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

REFRESH=0
JSON=0
MODE=verify
while [[ $# -gt 0 ]]; do
  case "$1" in
    verify|check) MODE=verify; shift ;;
    --refresh|-r|refresh) REFRESH=1; MODE=refresh; shift ;;
    --json) JSON=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
done

if [[ -t 1 && -z "${NO_COLOR:-}" && $JSON -eq 0 ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_dim="\033[2m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_dim=""; c_0=""
fi

if [[ $REFRESH -eq 1 ]]; then
  # Ensure markers still pass conceptually — compute+write, then verify
  fp="$(oc_signature_refresh "$REPO")" || {
    echo "  failed to refresh fingerprint" >&2
    exit 1
  }
  if [[ $JSON -eq 1 ]]; then
    python3 -c 'import json,sys; print(json.dumps({"ok":True,"action":"refresh","fingerprint":sys.argv[1],"repo":sys.argv[2]}, indent=2))' "$fp" "$REPO"
  else
    printf "  ${c_g}✓${c_0} signature refreshed\n"
    printf "  ${c_dim}fingerprint: %s${c_0}\n" "$fp"
    printf "  ${c_dim}id: openconfig/opencode-configs · product OpenConfig · cli oc${c_0}\n\n"
  fi
  # Verify after write (fingerprint file itself is not hashed)
  out="$(oc_verify_signature "$REPO")" || {
    printf "  ${c_r}✗${c_0} verify failed after refresh: %s\n" "$out" >&2
    exit 1
  }
  exit 0
fi

out="$(oc_verify_signature "$REPO")"
rc=$?
if [[ $JSON -eq 1 ]]; then
  python3 - "$out" "$rc" "$REPO" <<'PY'
import json, sys
out, rc, repo = sys.argv[1], int(sys.argv[2]), sys.argv[3]
parts = out.split("|", 2)
ok = rc == 0 and parts[0] == "ok"
payload = {"ok": ok, "repo": repo, "raw": out}
if ok:
    payload["id"] = parts[1] if len(parts) > 1 else None
    payload["fingerprint_prefix"] = parts[2] if len(parts) > 2 else None
else:
    payload["error"] = parts[1] if len(parts) > 1 else out
print(json.dumps(payload, indent=2))
sys.exit(0 if ok else 1)
PY
  exit $?
fi

if [[ $rc -eq 0 ]]; then
  id="${out#ok|}"; id="${id%%|*}"
  short="${out##*|}"
  printf "\n${c_b}OpenConfig signature${c_0}\n"
  printf "  ${c_g}✓${c_0} identity ok — %s\n" "$id"
  printf "  ${c_dim}fingerprint: %s…${c_0}\n" "$short"
  printf "  ${c_dim}repo: %s${c_0}\n\n" "$REPO"
  exit 0
fi

reason="${out#fail|}"
printf "\n${c_b}OpenConfig signature${c_0}\n"
printf "  ${c_r}✗${c_0} %s\n" "$reason"
printf "  ${c_dim}repo: %s${c_0}\n" "$REPO"
printf "  ${c_b}↳${c_0} ${c_dim}wrong tree? clone OpenConfig (signature.json → github_b64)${c_0}\n"
printf "  ${c_b}↳${c_0} ${c_dim}intentional edit? oc signature --refresh${c_0}\n\n"
exit 1
