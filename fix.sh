#!/usr/bin/env bash
# fix.sh — Auto-edit the configs to the known-good shape, then clean-format.
#
# This is the "get it right" tool. It repairs every footgun validate.sh
# detects, applies optional --set edits, pretty-prints stable 2-space JSON, and
# re-validates. Idempotent (running twice changes nothing) and backs up first.
#
# Repairs (opencode.json):
#   • delete experimental.primary_tools            (it denies tools to subagents)
#   • provider options: drop managementKey, rename defaultHeaders -> headers
#   • per model: reasoning_effort -> reasoning.effort; unwrap variant "options";
#     strip model-level options.temperature/top_p/thinking
#   • quantizations lacking "unknown" -> add "unknown" (keeps Claude/DeepSeek routable)
#   • Claude family: require_parameters=false, model temperature=false
#   • permission: drop bogus "write"; drop "doom_loop" inside the bash pattern map
#   • lock skills.paths to repo-local ./skills (drop external ~/.claude, ~/.agents dirs)
# Usage:
#   ./fix.sh                       repair + format + validate
#   ./fix.sh --dry-run             show what would change, write nothing
#   ./fix.sh --set model=openrouter/z-ai/glm-5.3
#   ./fix.sh --set default_agent=build --set small_model=openrouter/deepseek/deepseek-v4.1-flash

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
BACKUP_ROOT="${OC_BACKUP_ROOT}"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0
SETS=()
while [[ $# -gt 0 ]]; do case "$1" in
	--dry-run)
		DRY=1
		shift
		;;
	--set)
		SETS+=("$2")
		shift 2
		;;
	-h | --help)
		oc_print_script_help "$0"
		exit 0
		;;
	*)
		echo "Unknown flag: $1"
		exit 2
		;;
	esac done

export OC_FIX_STAMP="$STAMP"
# OC_BACKUP_ROOT comes from lib/common.sh

c_g=$'\033[32m'
c_y=$'\033[33m'
c_b=$'\033[36m'
c_0=$'\033[0m'

DRY=$DRY python3 - "$REPO" ${SETS[@]+"${SETS[@]}"} <<'PY'
import json, sys, os, re, copy, shutil

repo = sys.argv[1]
sets = sys.argv[2:]
dry = os.environ.get("DRY") == "1"
changes = []
stamp = os.environ.get("OC_FIX_STAMP") or ""
backup_root = os.environ.get("OC_BACKUP_ROOT") or os.path.expanduser("~/.opencode-backups")

def github_repo_url():
    import base64
    sig_path = os.path.join(repo, "signature.json")
    try:
        sig = json.load(open(sig_path, encoding="utf-8"))
    except OSError:
        return "https://github.com/jesseoue/opencode-configs"
    b64 = (sig.get("github_b64") or "").strip()
    if not b64:
        return "https://github.com/jesseoue/opencode-configs"
    try:
        return base64.b64decode(b64).decode("ascii").rstrip("/")
    except Exception:
        return "https://github.com/jesseoue/opencode-configs"

def load(p): return json.load(open(os.path.join(repo, p)))
def dump(p, d):
    with open(os.path.join(repo, p), "w") as f:
        json.dump(d, f, indent=2); f.write("\n")

VALID_EFFORT = {"none","minimal","low","medium","high","xhigh","max"}
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")
THEME_HEX = {"primary":"#00F0FF","accent":"#B967FF","info":"#00FFD1",
             "secondary":"#39FF14","warning":"#FFD400","error":"#FF1744"}

# ─── opencode.json ────────────────────────────────────────────────────────────
oc = load("opencode.json"); before = copy.deepcopy(oc)

exp = oc.get("experimental", {})
if "primary_tools" in exp:
    del exp["primary_tools"]; changes.append("removed experimental.primary_tools")

prov = oc.get("provider", {}).get("openrouter", {})
po = prov.get("options", {})
if "managementKey" in po: del po["managementKey"]; changes.append("dropped provider.options.managementKey")
if "defaultHeaders" in po:
    po.setdefault("headers", po.pop("defaultHeaders")); changes.append("renamed defaultHeaders -> headers")

for mid, m in prov.get("models", {}).items():
    o = m.setdefault("options", {})
    if "reasoning_effort" in o:
        eff = o.pop("reasoning_effort"); o.setdefault("reasoning", {})["effort"] = eff
        changes.append(f"[{mid}] options.reasoning_effort -> reasoning.effort")
    for k in ("temperature", "top_p", "thinking"):
        if k in o: del o[k]; changes.append(f"[{mid}] stripped model-level options.{k}")
    pv = o.get("provider", {})
    # Only claude/deepseek NEED 'unknown' (their first-party endpoints report it).
    # GLM intentionally excludes it to drop fp4 providers — do not touch that.
    q = pv.get("quantizations")
    if isinstance(q, list) and "unknown" not in q and m.get("family") in ("claude","deepseek"):
        pv["quantizations"] = q + ["unknown"]; changes.append(f"[{mid}] quantizations += 'unknown' ({m.get('family')} first-party)")
    if m.get("family") == "claude":
        if pv.get("require_parameters") is True:
            pv["require_parameters"] = False; changes.append(f"[{mid}] Claude require_parameters -> false")
        if m.get("temperature") is True:
            m["temperature"] = False; changes.append(f"[{mid}] Claude temperature -> false")
    for vn, vv in list(m.get("variants", {}).items()):
        if isinstance(vv, dict) and "options" in vv:
            inner = vv.pop("options")
            if isinstance(inner, dict): vv.update(inner)
            changes.append(f"[{mid}].variants.{vn} unwrapped 'options'")
        if isinstance(vv, dict) and "reasoning_effort" in vv:
            vv.setdefault("reasoning", {})["effort"] = vv.pop("reasoning_effort")
            changes.append(f"[{mid}].variants.{vn} reasoning_effort -> reasoning.effort")

perm = oc.get("permission", {})
if "write" in perm: del perm["write"]; changes.append("removed bogus permission.write")
if isinstance(perm.get("bash"), dict) and "doom_loop" in perm["bash"]:
    del perm["bash"]["doom_loop"]; changes.append("removed doom_loop from bash pattern map")

# Canonical tool allows — OpenCode core + MCP helpers
CORE_TOOLS = (
    "edit", "glob", "grep", "list", "task", "skill", "todowrite", "todoread",
    "webfetch", "question", "doom_loop", "external_directory", "lsp",
    "context7_query-docs", "context7_resolve-library-id",
)
for t in CORE_TOOLS:
    if perm.get(t) != "allow":
        perm[t] = "allow"
        changes.append(f"permission.{t} -> allow")
# Official OpenCode default: deny .env reads (https://opencode.ai/docs/permissions)
READ_PERM = {"*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow"}
if perm.get("read") != READ_PERM:
    perm["read"] = READ_PERM
    changes.append("permission.read -> allow with .env deny (OpenCode default)")
# bash: allow-everything with catastrophic denies kept
bash = perm.get("bash")
if not isinstance(bash, dict):
    bash = {"*": "allow"}
    perm["bash"] = bash
    changes.append("permission.bash -> map with * = allow")
elif bash.get("*") != "allow":
    bash["*"] = "allow"
    changes.append("permission.bash.* -> allow")
BASH_DENY = {
    "rm -rf /": "deny", "rm -rf /*": "deny", "rm -rf ~": "deny", "rm -rf ~/*": "deny",
    "rm -fr /": "deny", "rm -fr /*": "deny", "rm -fr ~": "deny", "rm -fr ~/*": "deny",
    ":(){ :|:& };:": "deny", "mkfs*": "deny", "dd if=* of=/dev/*": "deny",
    "sudo *": "deny", "sudo": "deny",
    "git push --force*": "deny", "git push -f*": "deny", "gh repo delete*": "deny",
}
for pat, val in BASH_DENY.items():
    if bash.get(pat) != val:
        bash[pat] = val
        changes.append(f"permission.bash[{pat!r}] -> {val}")

# Skills: global OpenConfig skills (any cwd — orca, Projects, …) + project-local ./skills.
# Drop ~/.claude / ~/.agents imports; keep ~/.config/opencode/skills (the config symlink).
ALLOWED_SKILL_PATHS = ["~/.config/opencode/skills", "./skills"]
sk = oc.setdefault("skills", {})
paths = [str(p) for p in (sk.get("paths") or [])]
bad = [p for p in paths if p not in ALLOWED_SKILL_PATHS and (".claude" in p or ".agents" in p or (p.startswith(("~", "/")) and "opencode/skills" not in p))]
if bad or paths != ALLOWED_SKILL_PATHS:
    sk["paths"] = list(ALLOWED_SKILL_PATHS)
    changes.append("skills.paths -> %s (global OpenConfig + project ./skills)" % ALLOWED_SKILL_PATHS)

# Goal footgun doc must load every session
instr = oc.get("instructions")
if not isinstance(instr, list):
    instr = []; oc["instructions"] = instr
for must in ("AGENTS.md", "prompts/core.md"):
    if must not in instr:
        instr.append(must); changes.append(f"instructions += {must}")

# vanilla stack: never carry an oh-my-* plugin in opencode.json or tui.json
tui_path = os.path.join(repo, "tui.json")
plug = oc.get("plugin") or []
kept = [p for p in plug if not (isinstance(p, str) and "oh-my-" in p)]
if kept != plug:
    if kept:
        oc["plugin"] = kept
    else:
        oc.pop("plugin", None)
    changes.append("removed oh-my-* plugin pin from opencode.json")
if os.path.isfile(tui_path):
    tui = load("tui.json")
    tp = tui.get("plugin") or []
    tkept = [p for p in tp if not (isinstance(p, str) and "oh-my-" in p)]
    if tkept != tp:
        if tkept:
            tui["plugin"] = tkept
        else:
            tui.pop("plugin", None)
        changes.append("removed oh-my-* plugin pin from tui.json")
        if not dry:
            dump("tui.json", tui)

# apply --set edits (top-level scalar keys)
for s in sets:
    if "=" not in s: continue
    k, v = s.split("=", 1)
    if oc.get(k) != v:
        oc[k] = v; changes.append(f"set {k} = {v}")

# ─── Telemetry / phone-home kill switches (OpenCode) ─────────────────────────
if oc.get("share") != "disabled":
    oc["share"] = "disabled"; changes.append("share -> disabled (no session sharing)")
if oc.get("autoupdate") is not False:
    oc["autoupdate"] = False; changes.append("autoupdate -> false")
if oc.get("subagent_depth") != 1:
    oc["subagent_depth"] = 1; changes.append("subagent_depth -> 1 (OpenCode default; no nested Task storms)")
comp = oc.setdefault("compaction", {})
if isinstance(comp, dict):
    if comp.get("auto") is not True:
        comp["auto"] = True; changes.append("compaction.auto -> true")
    if comp.get("auto") is not True:
        comp["auto"] = True; changes.append("compaction.auto -> true")
    if comp.get("prune") is not True:
        comp["prune"] = True; changes.append("compaction.prune -> true")
    if comp.get("reserved") != 24000:
        comp["reserved"] = 24000; changes.append("compaction.reserved -> 24000")
if oc.get("logLevel") != "ERROR":
    oc["logLevel"] = "ERROR"; changes.append("logLevel -> ERROR (minimize sensitive runtime logs)")
exp = oc.setdefault("experimental", {})
if not isinstance(exp, dict):
    oc["experimental"] = {}; exp = oc["experimental"]
if exp.get("openTelemetry") is not False:
    exp["openTelemetry"] = False; changes.append("experimental.openTelemetry -> false")
if exp.get("mcp_timeout") != 30000:
    exp["mcp_timeout"] = 30000; changes.append("experimental.mcp_timeout -> 30000")
tool_output = oc.setdefault("tool_output", {})
if isinstance(tool_output, dict):
    if tool_output.get("max_lines") != 200:
        tool_output["max_lines"] = 200; changes.append("tool_output.max_lines -> 200")
    if tool_output.get("max_bytes") != 8000:
        tool_output["max_bytes"] = 8000; changes.append("tool_output.max_bytes -> 8000")
srv = oc.get("server")
if isinstance(srv, dict):
    if srv.get("mdns") is not False:
        srv["mdns"] = False; changes.append("server.mdns -> false")
    if srv.get("port") != 4097:
        srv["port"] = 4097; changes.append("server.port -> 4097 (avoid Cursor on 4096)")
    if srv.get("hostname") not in ("127.0.0.1", "localhost"):
        srv["hostname"] = "127.0.0.1"; changes.append("server.hostname -> 127.0.0.1")

# ─── OpenRouter app attribution (OpenConfig — not generic CLI / OpenCode) ─────
or_opts = oc.setdefault("provider", {}).setdefault("openrouter", {}).setdefault("options", {})
if isinstance(or_opts, dict):
    for timeout_key, timeout_value in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 180000)):
        if or_opts.get(timeout_key) != timeout_value:
            or_opts[timeout_key] = timeout_value
            changes.append(f"openrouter.options.{timeout_key} -> {timeout_value}")
    hdrs = or_opts.setdefault("headers", {})
    if isinstance(hdrs, dict):
        want_hdrs = {
            "HTTP-Referer": github_repo_url(),
            "X-Title": "OpenConfig",
            "X-OpenRouter-Title": "OpenConfig",
            "X-OpenRouter-Categories": "cli-agent",
        }
        for hk, hv in want_hdrs.items():
            if hdrs.get(hk) != hv:
                hdrs[hk] = hv
                changes.append(f"openrouter.headers.{hk} -> {hv} (OpenConfig attribution)")
# Venice + native DeepSeek: same documented timeout trio
# (https://opencode.ai/docs/config). chunkTimeout 180s — official default is 300s.
for _pname in ("venice", "deepseek"):
    _opts = oc.setdefault("provider", {}).setdefault(_pname, {}).setdefault("options", {})
    if isinstance(_opts, dict):
        for timeout_key, timeout_value in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 180000)):
            if _opts.get(timeout_key) != timeout_value:
                _opts[timeout_key] = timeout_value
                changes.append(f"{_pname}.options.{timeout_key} -> {timeout_value}")
or_models = oc.setdefault("provider", {}).setdefault("openrouter", {}).setdefault("models", {})
if isinstance(or_models, dict):
    for model_id, model_cfg in or_models.items():
        if not isinstance(model_cfg, dict):
            continue
        provider_cfg = model_cfg.setdefault("options", {}).setdefault("provider", {})
        if not isinstance(provider_cfg, dict):
            continue
        if provider_cfg.get("data_collection") != "allow":
            provider_cfg["data_collection"] = "allow"
            changes.append(f"{model_id}.provider.data_collection -> allow")
        if "zdr" in provider_cfg:
            del provider_cfg["zdr"]
            changes.append(f"{model_id}.provider.zdr removed (preserve provider availability)")
        require_parameters = model_cfg.get("family") in ("glm", "minimax")
        family = model_cfg.get("family")
        # Unmoderated-provider pinning, rebuilt from LIVE endpoints
        # (openrouter.ai/api/v1/models/{id}/endpoints, rechecked 2026-09-08):
        # skip first-party + moderated proxies that add runtime blocks, and skip
        # every fp4 endpoint (fp4 quant degrades tool-calling). Plain provider
        # slugs only — each listed host serves the family at fp8/full precision.
        # glm has NO pin: glm-5.3 now has many hosts; Auto Exacto (on by default
        # for tool requests) + require_parameters is the quality pin. A static
        # provider.only roster would fight that and can 404 if hosts churn.
        # MiniMax: parasail added 2026-09-08 (fp8 + tools; already on DeepSeek roster).
        # V4.1 Flash (2026-09-10): day-one hosts are first-party DeepSeek + novita +
        # deepinfra only. Do NOT stamp the V4 Pro/0731 8-host roster — those 404.
        mid_l = str(model_id).lower()
        if "v4.1-flash" in mid_l or "v4-1-flash" in mid_l:
            want_only = ["deepseek", "novita", "deepinfra"]
        else:
            want_only = {
                "minimax": ["gmicloud", "novita", "deepinfra", "together", "parasail"],
                "deepseek": ["gmicloud", "novita", "siliconflow", "parasail", "deepinfra", "baidu", "fireworks", "digitalocean"],
            }.get(family)
        if want_only is not None:
            if provider_cfg.get("only") != want_only:
                provider_cfg["only"] = want_only
                changes.append(f"{model_id}.provider.only -> {want_only} (live-verified unmoderated hosts; no fp4)")
        elif "only" in provider_cfg:
            del provider_cfg["only"]
            changes.append(f"{model_id}.provider.only removed (stale pin — no live roster for this family)")
        if provider_cfg.get("require_parameters") is not require_parameters:
            provider_cfg["require_parameters"] = require_parameters
            changes.append(f"{model_id}.provider.require_parameters -> {str(require_parameters).lower()}")
        route_id = str(model_cfg.get("id") or model_id)
        if "order" in provider_cfg:
            del provider_cfg["order"]
            changes.append(f"{model_id}.provider.order removed (restore adaptive provider routing)")
        # :exacto/:nitro/:floor are virtual request suffixes, not catalog slugs.
        # Do not persist them as whitelist ids. sort/ignore/preferred_* fight
        # Auto Exacto / adaptive ranking.
        if "sort" in provider_cfg:
            del provider_cfg["sort"]
            changes.append(f"{model_id}.provider.sort removed (OpenRouter auto-rank)")
        if "ignore" in provider_cfg:
            del provider_cfg["ignore"]
            changes.append(f"{model_id}.provider.ignore removed (restore full fallback coverage)")
        for routing_key in ("preferred_min_throughput", "preferred_max_latency", "quantizations"):
            if routing_key in provider_cfg:
                del provider_cfg[routing_key]
                changes.append(f"{model_id}.provider.{routing_key} removed (OpenRouter auto-rank)")

# Gateways: OpenRouter (default) + Venice (content-aware) + native DeepSeek.
want_enabled = ["openrouter", "venice", "deepseek"]
if oc.get("enabled_providers") != want_enabled:
    oc["enabled_providers"] = want_enabled
    changes.append("enabled_providers -> ['openrouter', 'venice', 'deepseek']")
prov_root = oc.setdefault("provider", {})
venice_models = prov_root.setdefault("venice", {}).setdefault("models", {})
VENICE_REASONING_REQUIRED = {"e2ee-glm-5-2-p", "e2ee-glm-5-3-p", "e2ee-kimi-k3-p", "muse-wonder"}  # Venice rejects disable_thinking on these
VENICE_NO_TOOLS = {"grok-4-20-multi-agent", "e2ee-gemma-4-26b-a4b-uncensored-p", "e2ee-gpt-oss-120b-p", "e2ee-qwen-2-5-7b-p"}  # Venice: no function calling
if isinstance(venice_models, dict):
    for vm, vcfg in venice_models.items():
        if not isinstance(vcfg, dict):
            continue
        for field, default in (
            ("id", vm),
            ("family", "deepseek"),
            ("temperature", True),
            ("attachment", False),
            ("status", "active"),
        ):
            if vcfg.get(field) != default:
                vcfg[field] = default
                changes.append(f"venice.models.{vm}.{field} -> {default!r}")
        # Venice DeepSeek spends max_tokens in reasoning_content unless thinking
        # is off. disable_thinking is a venice_parameters key — top-level is
        # unrecognized and 400s (Flash and Pro). OpenRouter/native DeepSeek stay clean.
        # include_venice_system_prompt=false on every model + variant keeps Venice's
        # injected system prompt (and its content guidance) off the direct lane —
        # enforced here so repairs can never silently re-enable it.
        if vm in VENICE_NO_TOOLS and vcfg.get("tool_call") is not False:
            vcfg["tool_call"] = False
            changes.append(f"venice.models.{vm}.tool_call -> False (no function calling on Venice)")
        vopts = vcfg.setdefault("options", {})
        if isinstance(vopts, dict):
            if "disable_thinking" in vopts:
                del vopts["disable_thinking"]
                changes.append(f"venice.models.{vm}.options.disable_thinking removed (top-level 400s)")
            vp = vopts.setdefault("venice_parameters", {})
            if isinstance(vp, dict) and vm in VENICE_REASONING_REQUIRED and "disable_thinking" in vp:
                del vp["disable_thinking"]
                changes.append(f"venice.models.{vm}.options.venice_parameters.disable_thinking removed (reasoning required)")
            elif isinstance(vp, dict) and vm not in VENICE_REASONING_REQUIRED and vp.get("disable_thinking") is not True:
                vp["disable_thinking"] = True
                changes.append(f"venice.models.{vm}.options.venice_parameters.disable_thinking -> true")
            if isinstance(vp, dict) and vp.get("include_venice_system_prompt") is not False:
                vp["include_venice_system_prompt"] = False
                changes.append(f"venice.models.{vm}.options.venice_parameters.include_venice_system_prompt -> false (uncensored: no Venice system prompt)")
        for vn, vv in list((vcfg.get("variants") or {}).items()):
            if not isinstance(vv, dict):
                continue
            if "disable_thinking" in vv:
                del vv["disable_thinking"]
                changes.append(f"venice.models.{vm}.variants.{vn}.disable_thinking removed (top-level 400s)")
            vvp = vv.setdefault("venice_parameters", {})
            if isinstance(vvp, dict) and vm in VENICE_REASONING_REQUIRED and "disable_thinking" in vvp:
                del vvp["disable_thinking"]
                changes.append(f"venice.models.{vm}.variants.{vn}.venice_parameters.disable_thinking removed (reasoning required)")
            elif isinstance(vvp, dict) and vm not in VENICE_REASONING_REQUIRED and vvp.get("disable_thinking") is not True:
                vvp["disable_thinking"] = True
                changes.append(f"venice.models.{vm}.variants.{vn}.venice_parameters.disable_thinking -> true")
            if isinstance(vvp, dict) and vvp.get("include_venice_system_prompt") is not False:
                vvp["include_venice_system_prompt"] = False
                changes.append(f"venice.models.{vm}.variants.{vn}.venice_parameters.include_venice_system_prompt -> false (uncensored: no Venice system prompt)")
if isinstance(prov_root, dict) and "openai" in prov_root:
    del prov_root["openai"]
    changes.append("removed provider.openai (OpenRouter-only)")

# ─── config-only: scrub install/runtime strays OpenCode may drop here ─────────
STRAYS = (
    "node_modules", "package.json", "package-lock.json", "npm-shrinkwrap.json",
    "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", ".omo", ".runtime", ".sisyphus",
    ".codegraph", "command",
)

def _is_opencode_sdk_install(repo):
    # opencode >= 1.19 drops @opencode-ai/plugin here on every startup; tolerate.
    pj = os.path.join(repo, "package.json")
    if not os.path.isfile(pj):
        return False
    try:
        d = json.load(open(pj, encoding="utf-8"))
    except Exception:
        return False
    return set(d.get("dependencies") or {}) == {"@opencode-ai/plugin"}

_tol = {"node_modules", "package.json", "package-lock.json"} if _is_opencode_sdk_install(repo) else set()
for name in STRAYS:
    if name in _tol:
        continue
    path = os.path.join(repo, name)
    if os.path.lexists(path):
        if not dry:
            if os.path.islink(path) or os.path.isfile(path):
                os.unlink(path)
            else:
                shutil.rmtree(path)
        changes.append(f"removed stray {name} (config-only repo)")

# ─── write + report ───────────────────────────────────────────────────────────
if not changes:
    print("  \033[32m✓ already clean — nothing to fix\033[0m")
else:
    for m in changes: print(f"  \033[36m⟳\033[0m {m}")
    if dry:
        print("\n  \033[33m[dry-run] no files written\033[0m")
    else:
        # Backup only when we will actually write
        bdir = os.path.join(backup_root, f"fix-{stamp or 'manual'}")
        os.makedirs(bdir, exist_ok=True)
        for name in ("opencode.json",):
            src = os.path.join(repo, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(bdir, name))
        if oc != before: dump("opencode.json", oc)
        print(f"\n  \033[32mapplied {len(changes)} fix(es)\033[0m")
        print(f"  backup: {bdir}")
sys.exit(0)
PY

echo ""
if [[ $DRY -eq 0 ]]; then
	_oai_scrub="$(oc_scrub_openai_env_key "$REPO/opencode.json" "$REPO/.env" 2>/dev/null || true)"
	if [[ "$_oai_scrub" == CLEARED* ]]; then
		printf "  ${c_g}✓${c_0} %s\n" "${_oai_scrub#CLEARED|}"
	fi
	unset _oai_scrub
	printf "${c_b}==>${c_0} Re-validating\n"
	validate_out="$($REPO/validate.sh 2>&1)"
	validate_rc=$?
	printf '%s\n' "$validate_out" | tail -1
	exit "$validate_rc"
fi
