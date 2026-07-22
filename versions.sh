#!/usr/bin/env bash
# versions.sh — Audit OpenConfig package pins against upstream.
#
# Compares local OpenCode CLI, OmO plugin pin, @opencode-ai/plugin peer,
# and versions.json floors to live npm + GitHub releases. Also scans
# ~/Projects and /Users/Shared for other opencode.json overlays.
#
# Usage:
#   ./versions.sh              local pins + upstream check (default)
#   ./versions.sh --check      same (explicit)
#   ./versions.sh --local      local pins only (no network)
#   ./versions.sh --fix        align ~/.opencode @opencode-ai/plugin to CLI when npm has it
#   ./versions.sh --json       machine-readable
#   oc versions [--check|--local|--fix|--json]
#
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

MODE="check"
DO_JSON=0
DO_FIX=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-c) MODE="check"; shift ;;
    --local|-l) MODE="local"; shift ;;
    --fix) DO_FIX=1; MODE="check"; shift ;;
    --json) DO_JSON=1; shift ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $1 (try --check --local --fix --json)"; exit 2 ;;
  esac
done

if [[ -t 1 && -z "${NO_COLOR:-}" && $DO_JSON -eq 0 ]]; then
  c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"
  c_dim="\033[2m"; c_bold="\033[1m"; c_0="\033[0m"
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_dim=""; c_bold=""; c_0=""
fi

ok(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_g}✓${c_0} %s\n" "$*"; }
info(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_dim}•${c_0} %s\n" "$*"; }
warn(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "  ${c_r}✗${c_0} %s\n" "$*"; }
sec(){ [[ $DO_JSON -eq 1 ]] && return 0; printf "\n${c_b}${c_bold}== %s ==${c_0}\n" "$*"; }

OC_BIN="$(command -v opencode 2>/dev/null || echo "${OC_CLI_BIN:-}")"
CLI_VER=""
[[ -x "$OC_BIN" ]] && CLI_VER="$("$OC_BIN" --version 2>/dev/null | head -1 | tr -d '\r' | awk '{print $NF}')"

REPORT="$(python3 - "$REPO" "$MODE" "$CLI_VER" "$DO_FIX" <<'PY'
import json, os, sys, urllib.request, ssl

repo, mode, cli_ver, do_fix = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
out = {"ok": True, "local": {}, "upstream": {}, "status": [], "actions": [], "other_opencode_json": []}

def get(url, timeout=12):
    ctx = ssl.create_default_context()
    req = urllib.request.Request(url, headers={"User-Agent": "OpenConfig-versions/1.5"})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read().decode("utf-8", errors="replace")

def npm_latest(pkg):
    data = json.loads(get(f"https://registry.npmjs.org/{pkg}"))
    tags = data.get("dist-tags") or {}
    versions = data.get("versions") or {}
    return tags.get("latest"), versions

def tup(v):
    parts = []
    for p in (v or "").lstrip("v").split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple((parts + [0, 0, 0])[:3])

def status(kind, msg):
    out["status"].append({"level": kind, "msg": msg})
    if kind == "bad":
        out["ok"] = False

versions = json.load(open(os.path.join(repo, "versions.json"), encoding="utf-8"))
oc = json.load(open(os.path.join(repo, "opencode.json"), encoding="utf-8"))
pins = [p for p in (oc.get("plugin") or []) if isinstance(p, str) and "oh-my-openagent@" in p]
omo_pin = pins[0].split("@", 1)[1] if pins else ""
omo_want = (versions.get("oh_my_openagent") or {}).get("pin") or ""
oc_min = (versions.get("opencode") or {}).get("min") or ""
product = versions.get("opencode_configs") or ""

peer = ""
peer_path = os.path.expanduser("~/.opencode/package.json")
if os.path.isfile(peer_path):
    try:
        peer = ((json.load(open(peer_path)).get("dependencies") or {}).get("@opencode-ai/plugin")) or ""
    except Exception:
        peer = ""

out["local"] = {
    "openconfig": product,
    "opencode_cli": cli_ver or None,
    "opencode_min": oc_min,
    "omo_pin": omo_pin,
    "omo_versions_json": omo_want,
    "opencode_ai_plugin": peer or None,
}

if omo_pin and omo_want and omo_pin != omo_want:
    status("bad", f"opencode.json OmO pin {omo_pin} != versions.json {omo_want}")
elif omo_pin:
    status("ok", f"OmO pin aligned ({omo_pin})")

if cli_ver and oc_min:
    if tup(cli_ver) < tup(oc_min):
        status("bad", f"OpenCode CLI {cli_ver} < floor {oc_min}")
    else:
        status("ok", f"OpenCode CLI {cli_ver} ≥ floor {oc_min}")
elif not cli_ver:
    status("warn", "OpenCode CLI not found on PATH")

# Other repos that carry opencode.json (shallow scan)
repo_real = os.path.realpath(repo)
others = []
for root in (os.path.expanduser("~/Projects"), "/Users/Shared"):
    if not os.path.isdir(root):
        continue
    try:
        names = os.listdir(root)
    except OSError:
        continue
    for name in names:
        base = os.path.join(root, name)
        cfg = os.path.join(base, "opencode.json")
        if not os.path.isfile(cfg):
            continue
        try:
            if os.path.realpath(base) == repo_real:
                continue
        except OSError:
            pass
        try:
            data = json.load(open(cfg, encoding="utf-8"))
        except Exception:
            continue
        plugs = [p for p in (data.get("plugin") or []) if isinstance(p, str) and "oh-my" in p]
        others.append({
            "path": cfg,
            "plugin": plugs[0] if plugs else None,
            "model": data.get("model"),
            "default_agent": data.get("default_agent"),
        })
out["other_opencode_json"] = others[:20]
if others:
    status("ok", f"scanned {len(others)} other opencode.json (project overlays; OmO pin is global)")
else:
    status("ok", "no other project opencode.json with local plugin pins (global stack owns OmO)")

if mode == "local":
    print(json.dumps(out, indent=2))
    raise SystemExit(0)

# Upstream
try:
    omo_latest, omo_vers = npm_latest("oh-my-openagent")
    out["upstream"]["oh-my-openagent"] = omo_latest
    if omo_pin and omo_latest:
        if omo_pin == omo_latest:
            status("ok", f"OmO pin {omo_pin} = npm latest")
        elif omo_pin in omo_vers and omo_latest != omo_pin:
            status("warn", f"OmO pin {omo_pin} behind npm latest {omo_latest}")
        elif omo_pin not in omo_vers:
            status("bad", f"OmO pin {omo_pin} not on npm registry")
except Exception as e:
    status("warn", f"npm oh-my-openagent lookup failed: {e}")

try:
    plugin_latest, plugin_vers = npm_latest("@opencode-ai/plugin")
    out["upstream"]["@opencode-ai/plugin"] = plugin_latest
    if cli_ver and plugin_latest:
        if cli_ver == plugin_latest:
            status("ok", f"@opencode-ai/plugin latest {plugin_latest} matches CLI")
        elif cli_ver in plugin_vers:
            status("ok", f"@opencode-ai/plugin@{cli_ver} available on npm (latest {plugin_latest})")
        else:
            status("warn", f"@opencode-ai/plugin@{cli_ver} missing on npm (latest {plugin_latest}) — known lag")
    if peer and cli_ver:
        if peer == cli_ver:
            status("ok", f"~/.opencode @opencode-ai/plugin {peer} matches CLI")
        else:
            status("warn", f"~/.opencode @opencode-ai/plugin {peer} ≠ CLI {cli_ver}")
            if do_fix and cli_ver in (plugin_vers or {}):
                out["actions"].append({"fix_plugin_peer": cli_ver})
except Exception as e:
    status("warn", f"npm @opencode-ai/plugin lookup failed: {e}")

try:
    rel = json.loads(get("https://api.github.com/repos/anomalyco/opencode/releases/latest"))
    tag = (rel.get("tag_name") or "").lstrip("v")
    out["upstream"]["opencode_github"] = tag or None
    if cli_ver and tag:
        if cli_ver == tag:
            status("ok", f"OpenCode CLI {cli_ver} = GitHub latest")
        else:
            status("warn", f"OpenCode CLI {cli_ver} vs GitHub latest {tag}")
except Exception as e:
    status("warn", f"GitHub OpenCode latest lookup failed: {e}")

try:
    rel = json.loads(get("https://api.github.com/repos/code-yeongyu/oh-my-openagent/releases/latest"))
    tag = (rel.get("tag_name") or "").lstrip("v")
    out["upstream"]["omo_github"] = tag or None
    if omo_pin and tag:
        if omo_pin == tag:
            status("ok", f"OmO pin {omo_pin} = GitHub latest")
        else:
            status("warn", f"OmO pin {omo_pin} vs GitHub latest {tag}")
except Exception as e:
    status("warn", f"GitHub OmO latest lookup failed: {e}")

print(json.dumps(out, indent=2))
PY
)" || {
  bad "versions audit failed"
  exit 1
}

if [[ $DO_JSON -eq 1 ]]; then
  printf '%s\n' "$REPORT"
else
  _OC_VER="$(oc_versions_get opencode_configs 2>/dev/null || echo "?")"
  printf "\n${c_b}${c_bold}OpenConfig versions${c_0} ${c_dim}v%s · %s${c_0}\n" "$_OC_VER" "$REPO"
  sec "Pins"
  while IFS='|' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      OK) ok "$msg" ;;
      WARN) warn "$msg" ;;
      BAD) bad "$msg" ;;
      LOC) info "$msg" ;;
      UP) info "upstream $msg" ;;
      INFO) info "$msg" ;;
      *) info "$msg" ;;
    esac
  done < <(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
loc=d.get("local") or {}
for k in ("openconfig","opencode_cli","opencode_min","omo_pin","omo_versions_json","opencode_ai_plugin"):
    print(f"LOC|{k}={loc.get(k)}")
up=d.get("upstream") or {}
for k,v in up.items():
    print(f"UP|{k}={v}")
for s in d.get("status") or []:
    print("%s|%s" % ((s.get("level") or "info").upper(), s.get("msg")))
others=d.get("other_opencode_json") or []
if others:
    print("INFO|other opencode.json files: %d" % len(others))
    for o in others[:8]:
        print("INFO|  %s · model=%s · agent=%s · plugin=%s" % (
            o.get("path"), o.get("model"), o.get("default_agent"), o.get("plugin")))
' "$REPORT")
fi

# Optional peer fix (Python only queues actions when CLI version exists on npm)
if [[ $DO_FIX -eq 1 ]]; then
  WANT="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); acts=d.get("actions") or []; print(next((a.get("fix_plugin_peer") for a in acts if a.get("fix_plugin_peer")), ""))' "$REPORT")"
  if [[ -n "$WANT" && -f "$HOME/.opencode/package.json" ]]; then
    python3 - "$WANT" <<'PY'
import json, os, sys
want = sys.argv[1]
path = os.path.expanduser("~/.opencode/package.json")
d = json.load(open(path, encoding="utf-8"))
deps = d.setdefault("dependencies", {})
old = deps.get("@opencode-ai/plugin")
deps["@opencode-ai/plugin"] = want
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"FIXED|@opencode-ai/plugin {old} -> {want}")
PY
    if command -v bun >/dev/null 2>&1; then
      (cd "$HOME/.opencode" && bun install >/dev/null 2>&1) && ok "bun install @opencode-ai/plugin@$WANT" || warn "bun install failed — run: cd ~/.opencode && bun install"
    fi
  else
    info "no plugin peer fix needed"
  fi
fi

python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("ok") else 1)' "$REPORT"
