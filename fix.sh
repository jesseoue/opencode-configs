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
#   • normalize the oh-my-* plugin pin
#   • lock skills.paths to repo-local ./skills (drop external ~/.claude, ~/.agents dirs)
# Repairs (oh-my-openagent.json):
#   • agent color -> hex (or removed); strip hidden/steps/thinking/providerOptions
#   • keyword_detector.enabled_expansions -> only valid enum values
#   • lock skills.sources to ./skills; disable the Claude Code bridge (no external imports)
#   • goal.enabled/auto_start + default_mode.goal -> false (OmO 4.19 /start-work footgun)
#   • drop deprecated ralph_loop (Goals replaced Ralph on OmO 4.19)
#   • quarantine broken ~/.omo/omo.jsonc when it contains invalid migrated agents.models
#     (OpenConfig canonical source is oh-my-openagent.json — stale omo.jsonc breaks Sisyphus)
# Usage:
#   ./fix.sh                       repair + format + validate
#   ./fix.sh --dry-run             show what would change, write nothing
#   ./fix.sh --set model=openrouter/z-ai/glm-5.2
#   ./fix.sh --set default_agent=atlas --set small_model=openrouter/deepseek/deepseek-v4-flash

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
BACKUP_ROOT="${OC_BACKUP_ROOT}"; STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0; SETS=()
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY=1; shift ;;
  --set) SETS+=("$2"); shift 2 ;;
  -h|--help) oc_print_script_help "$0"; exit 0 ;;
  *) echo "Unknown flag: $1"; exit 2 ;;
esac; done

export OC_FIX_STAMP="$STAMP"
# OC_BACKUP_ROOT comes from lib/common.sh

c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'

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
KW_ALLOWED = {"ultrawork","team","hyperplan","hyperplan-ultrawork"}
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

# Canonical tool allows — team mode + OpenCode core + MCP helpers
TEAM_TOOLS = (
    "team_create", "team_delete", "team_list", "team_status", "team_send_message",
    "team_shutdown_request", "team_approve_shutdown", "team_reject_shutdown",
    "team_task_create", "team_task_get", "team_task_list", "team_task_update",
)
CORE_TOOLS = (
    "read", "edit", "glob", "grep", "list", "task", "call_omo_agent",
    "skill", "skill_mcp", "todowrite", "todoread",
    "webfetch", "websearch", "question", "doom_loop", "external_directory",
    "interactive_bash", "background_output", "background_cancel", "look_at",
    "session_info", "session_list", "session_read", "session_search",
    "grep_app", "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource",
    "lsp", "lsp_diagnostics", "lsp_find_references", "lsp_goto_definition",
    "lsp_install_decision", "lsp_prepare_rename", "lsp_rename", "lsp_status", "lsp_symbols",
    "monitor_start", "monitor_stop", "monitor_output", "monitor_list",
    "context7_query-docs", "context7_resolve-library-id",
    "grep_app_searchGitHub", "websearch_web_search_exa",
)
oc["permission"] = perm
for t in TEAM_TOOLS + CORE_TOOLS:
    if perm.get(t) != "allow":
        perm[t] = "allow"
        changes.append(f"permission.{t} -> allow")
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
for must in ("AGENTS.md", "prompts/core.md", "prompts/goal.md"):
    if must not in instr:
        instr.append(must); changes.append(f"instructions += {must}")

# normalize plugin pin name (accept oh-my-openagent or oh-my-opencode; keep version)
plug = oc.get("plugin", [])
for i, p in enumerate(plug):
    if "oh-my" in p and "@" in p:
        ver = p.split("@")[-1]
        canon = f"oh-my-openagent@{ver}"
        if p != canon: plug[i] = canon; changes.append(f"plugin pin -> {canon}")

# keep tui.json oh-my-* plugin pin in sync with opencode.json
tui_path = os.path.join(repo, "tui.json")
if os.path.isfile(tui_path) and plug:
    tui = load("tui.json")
    tui_before = copy.deepcopy(tui)
    oc_omo = [p for p in plug if isinstance(p, str) and "oh-my-" in p]
    if oc_omo:
        tui_plug = tui.get("plugin")
        if not isinstance(tui_plug, list):
            tui["plugin"] = list(oc_omo)
            changes.append(f"tui.json plugin -> {oc_omo}")
        else:
            tui_omo = [p for p in tui_plug if isinstance(p, str) and "oh-my-" in p]
            if set(tui_omo) != set(oc_omo):
                rest = [p for p in tui_plug if not (isinstance(p, str) and "oh-my-" in p)]
                tui["plugin"] = rest + list(oc_omo)
                changes.append(f"tui.json plugin pin synced -> {oc_omo}")
    if tui != tui_before and not dry:
        dump("tui.json", tui)

# apply --set edits (top-level scalar keys; 'plugin' updates the oh-my entry)
for s in sets:
    if "=" not in s: continue
    k, v = s.split("=", 1)
    if k == "plugin":
        pl = oc.setdefault("plugin", [])
        placed = False
        for i, p in enumerate(pl):
            if "oh-my" in p:
                if p != v: pl[i] = v; changes.append(f"set plugin pin -> {v}")
                placed = True; break
        if not placed: pl.append(v); changes.append(f"added plugin {v}")
    elif oc.get(k) != v:
        oc[k] = v; changes.append(f"set {k} = {v}")

# ─── Telemetry / phone-home kill switches (OpenCode) ─────────────────────────
if oc.get("share") != "disabled":
    oc["share"] = "disabled"; changes.append("share -> disabled (no session sharing)")
if oc.get("autoupdate") is not False:
    oc["autoupdate"] = False; changes.append("autoupdate -> false")
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
    if tool_output.get("max_lines") != 300:
        tool_output["max_lines"] = 300; changes.append("tool_output.max_lines -> 300")
    if tool_output.get("max_bytes") != 12000:
        tool_output["max_bytes"] = 12000; changes.append("tool_output.max_bytes -> 12000")
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
    for timeout_key, timeout_value in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 60000)):
        if or_opts.get(timeout_key) != timeout_value:
            or_opts[timeout_key] = timeout_value
            changes.append(f"openrouter.options.{timeout_key} -> {timeout_value}")
    hdrs = or_opts.setdefault("headers", {})
    if isinstance(hdrs, dict):
        want_hdrs = {
            "HTTP-Referer": github_repo_url(),
            "X-Title": "OpenConfig",
            "X-OpenRouter-Title": "OpenConfig",
            "X-OpenRouter-Categories": "cli,agent",
        }
        for hk, hv in want_hdrs.items():
            if hdrs.get(hk) != hv:
                hdrs[hk] = hv
                changes.append(f"openrouter.headers.{hk} -> {hv} (OpenConfig attribution)")
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
        if model_cfg.get("family") == "deepseek":
            want_only = ["deepseek"]
            if provider_cfg.get("only") != want_only:
                provider_cfg["only"] = want_only
                changes.append(f"{model_id}.provider.only -> ['deepseek'] (first-party; skip moderated proxies)")
            if provider_cfg.get("require_parameters") is not False:
                provider_cfg["require_parameters"] = False
                changes.append(f"{model_id}.provider.require_parameters -> false (DeepSeek first-party)")
        elif provider_cfg.get("require_parameters") is not require_parameters:
            provider_cfg["require_parameters"] = require_parameters
            changes.append(f"{model_id}.provider.require_parameters -> {str(require_parameters).lower()}")
        route_id = str(model_cfg.get("id") or model_id)
        if "order" in provider_cfg:
            del provider_cfg["order"]
            changes.append(f"{model_id}.provider.order removed (restore adaptive provider routing)")
        if route_id.endswith((":exacto", ":nitro", ":floor")):
            if "ignore" in provider_cfg:
                del provider_cfg["ignore"]
                changes.append(f"{model_id}.provider.ignore removed (preserve native {route_id.rsplit(':', 1)[1]} coverage)")
            if "sort" in provider_cfg:
                del provider_cfg["sort"]
                changes.append(f"{model_id}.provider.sort removed (routing suffix already selects ranking)")
            for routing_key in ("preferred_min_throughput", "preferred_max_latency", "quantizations"):
                if routing_key in provider_cfg:
                    del provider_cfg[routing_key]
                    changes.append(f"{model_id}.provider.{routing_key} removed (native {route_id.rsplit(':', 1)[1]} ranking)")
        elif "preferred_min_throughput" in provider_cfg or "preferred_max_latency" in provider_cfg:
            for routing_key in ("preferred_min_throughput", "preferred_max_latency"):
                if routing_key in provider_cfg:
                    del provider_cfg[routing_key]
                    changes.append(f"{model_id}.provider.{routing_key} removed (OpenRouter auto-rank)")

# OpenRouter-only: lock enabled_providers and drop direct OpenAI provider block.
if oc.get("enabled_providers") != ["openrouter"]:
    oc["enabled_providers"] = ["openrouter"]
    changes.append("enabled_providers -> ['openrouter'] (OpenRouter-only)")
prov_root = oc.setdefault("provider", {})
if isinstance(prov_root, dict) and "openai" in prov_root:
    del prov_root["openai"]
    changes.append("removed provider.openai (OpenRouter-only)")

# ─── oh-my-openagent.json ─────────────────────────────────────────────────────
omo = load("oh-my-openagent.json"); ombefore = copy.deepcopy(omo)

# Canonical reasoning field (OmO 4.19.4+) — migrate legacy reasoningEffort
REASONING_EFFORT_MAP = {
    "none": "off", "minimal": "minimal", "low": "low", "medium": "medium",
    "high": "high", "xhigh": "xhigh", "max": "max",
}
for section in ("agents", "categories"):
    for n, a in (omo.get(section) or {}).items():
        if not isinstance(a, dict):
            continue
        reff = a.get("reasoningEffort")
        if reff is None:
            continue
        canon = REASONING_EFFORT_MAP.get(str(reff), str(reff))
        if a.get("reasoning") != canon:
            a["reasoning"] = canon
            changes.append(f"{section} {n}: reasoningEffort -> reasoning ({canon})")
        del a["reasoningEffort"]
        changes.append(f"{section} {n}: removed deprecated reasoningEffort")

# Keep $schema URL aligned with pinned OmO version
ver_path = os.path.join(repo, "versions.json")
try:
    omo_pin = json.load(open(ver_path)).get("oh_my_openagent", {}).get("pin")
except Exception:
    omo_pin = None
if omo_pin:
    want_schema = f"https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/v{omo_pin}/assets/oh-my-opencode.schema.json"
    if omo.get("$schema") != want_schema:
        omo["$schema"] = want_schema
        changes.append(f"omo $schema -> v{omo_pin}")

# OpenRouter-only model refs + strip slow kimi from routine fallbacks
def _norm_or_model(m):
    if not isinstance(m, str):
        return m
    if m.startswith("openai/") and not m.startswith("openrouter/"):
        return "openrouter/" + m
    return m
SLOW_FB = ("kimi-k3",)
for section in ("agents", "categories"):
    for n, a in (omo.get(section) or {}).items():
        if not isinstance(a, dict):
            continue
        if a.get("model"):
            nm = _norm_or_model(a["model"])
            if nm != a["model"]:
                a["model"] = nm
                changes.append(f"{section} {n}: model -> {nm}")
        fbs = a.get("fallback_models")
        if not isinstance(fbs, list):
            continue
        cleaned = []
        for fb in fbs:
            fb = _norm_or_model(fb)
            if any(s in str(fb).lower() for s in SLOW_FB):
                changes.append(f"{section} {n}: dropped slow fallback {fb}")
                continue
            cleaned.append(fb)
        if cleaned != fbs:
            a["fallback_models"] = cleaned[:3]

# Recon routes: unmoderated primaries + fallbacks only (no Claude/GPT on explore/librarian/recon chains)
MODERATED_FB = ("anthropic/claude", "openai/gpt", "meta-llama/", "cohere/")
RECON_PRIMARY = {
    "explore": "openrouter/deepseek/deepseek-v4-pro-0813",
    "librarian": "openrouter/deepseek/deepseek-v4-pro-0813",
    "metis": "openrouter/z-ai/glm-5.2-exacto",
    "multimodal-looker": "openrouter/google/gemini-3.1-pro-preview",
    "deep": "openrouter/deepseek/deepseek-v4-pro-0813",
    "arch-review": "openrouter/z-ai/glm-5.2-exacto",
    "content-aware-research": "openrouter/deepseek/deepseek-v4-pro",
    "content-aware-deep": "openrouter/deepseek/deepseek-v4-pro",
    "content-aware-fast": "openrouter/deepseek/deepseek-v4-flash-0731",
}
RECON_FALLBACKS = [
    "openrouter/deepseek/deepseek-v4-pro-0813",
    "openrouter/deepseek/deepseek-v4-flash",
    "openrouter/deepseek/deepseek-v4-flash-0731",
    "openrouter/z-ai/glm-5.2-exacto",
    "openrouter/minimax/minimax-m3",
]
FAST_PRIMARY = "openrouter/deepseek/deepseek-v4-flash"
RECON_ROUTES = {
    "explore", "librarian", "sisyphus-junior", "quick", "unspecified-low",
    "content-aware-fast", "content-aware-deep", "content-aware-research",
    "deep", "arch-review", "metis", "multimodal-looker",
}
for section in ("agents", "categories"):
    for n, a in (omo.get(section) or {}).items():
        if n not in RECON_ROUTES or not isinstance(a, dict):
            continue
        want_primary = RECON_PRIMARY.get(n, FAST_PRIMARY)
        if a.get("model") and any(m in str(a["model"]).lower() for m in MODERATED_FB):
            a["model"] = want_primary
            changes.append(f"{section} {n}: model -> {want_primary} (unmoderated recon)")
        fbs = a.get("fallback_models")
        if not isinstance(fbs, list):
            continue
        cleaned = []
        for fb in fbs:
            fb = _norm_or_model(fb)
            if any(m in str(fb).lower() for m in MODERATED_FB):
                changes.append(f"{section} {n}: dropped moderated fallback {fb}")
                continue
            cleaned.append(fb)
        if not cleaned:
            cleaned = [x for x in RECON_FALLBACKS if x != a.get("model")][:3]
            changes.append(f"{section} {n}: rebuilt unmoderated fallbacks")
        if cleaned != fbs:
            a["fallback_models"] = cleaned[:3]
        if n == "explore":
            perm = a.setdefault("permission", {})
            if isinstance(perm, dict):
                for k, v in (("edit", "deny"), ("webfetch", "allow"), ("question", "allow"), ("task", "allow")):
                    if perm.get(k) != v:
                        perm[k] = v
                        changes.append(f"explore permission.{k} -> {v}")

# OpenRouter-only gateway: strip GPT from all routes + whitelist (no openai/gpt-*)
GPT_MARKERS = ("openai/gpt", "/gpt-5", "/gpt-4")
DEEP_PRIMARY = "openrouter/deepseek/deepseek-v4-pro-0813"
DEEP_FALLBACKS = [
    "openrouter/z-ai/glm-5.2-exacto",
    "openrouter/deepseek/deepseek-v4-flash",
    "openrouter/minimax/minimax-m3",
]
MAX_PRIMARY = "openrouter/anthropic/claude-fable-5"
MAX_FALLBACKS = [
    "openrouter/deepseek/deepseek-v4-pro-0813",
    "openrouter/z-ai/glm-5.2-exacto",
    "openrouter/deepseek/deepseek-v4-flash",
]
MAX_ROUTES = {"momus", "ultrabrain", "unspecified-high"}

def _is_gpt(ref):
    s = str(ref or "").lower()
    return any(m in s for m in GPT_MARKERS)

for section in ("agents", "categories"):
    for n, a in (omo.get(section) or {}).items():
        if not isinstance(a, dict):
            continue
        want_p = MAX_PRIMARY if n in MAX_ROUTES else None
        want_f = MAX_FALLBACKS if n in MAX_ROUTES else None
        if _is_gpt(a.get("model")):
            repl = want_p or DEEP_PRIMARY
            a["model"] = repl
            changes.append(f"{section} {n}: model -> {repl} (OpenRouter-only, no GPT)")
        fbs = a.get("fallback_models")
        if not isinstance(fbs, list):
            continue
        cleaned = []
        for fb in fbs:
            fb = _norm_or_model(fb)
            if _is_gpt(fb):
                changes.append(f"{section} {n}: dropped GPT fallback {fb}")
                continue
            cleaned.append(fb)
        fill = want_f or DEEP_FALLBACKS
        for x in fill:
            if x != a.get("model") and x not in cleaned:
                cleaned.append(x)
            if len(cleaned) >= 3:
                break
        if cleaned != fbs:
            a["fallback_models"] = cleaned[:3]

or_prov = oc.setdefault("provider", {}).setdefault("openrouter", {})
wl = or_prov.get("whitelist") or []
new_wl = [w for w in wl if isinstance(w, str) and not _is_gpt(w)]
if new_wl != wl:
    or_prov["whitelist"] = new_wl
    changes.append(f"removed GPT from openrouter whitelist ({len(wl) - len(new_wl)} models)")
or_models = or_prov.get("models") or {}
for mk in list(or_models.keys()):
    if _is_gpt(mk):
        del or_models[mk]
        changes.append(f"removed openrouter.models[{mk}] (OpenRouter-only, no GPT)")

# OmO / codegraph telemetry + co-author phone-home off
if omo.get("telemetry") is not False:
    omo["telemetry"] = False; changes.append("omo telemetry -> false")
if omo.get("auto_update") is not False:
    omo["auto_update"] = False; changes.append("omo auto_update -> false")
cg = omo.setdefault("codegraph", {})
if isinstance(cg, dict) and cg.get("telemetry") is not False:
    cg["telemetry"] = False; changes.append("codegraph.telemetry -> false")
# Team mode must stay on for team_* tools + hyperplan (full OmO 4.19 schema)
tm = omo.setdefault("team_mode", {})
if isinstance(tm, dict):
    if tm.get("enabled") is not True:
        tm["enabled"] = True; changes.append("team_mode.enabled -> true")
    if "tmux_visualization" not in tm:
        tm["tmux_visualization"] = False; changes.append("team_mode.tmux_visualization -> false")
    # Cap fan-out: hyperplan needs ≥5 members; keep parallel low so teams can't runaway.
    if not isinstance(tm.get("max_parallel_members"), int) or tm.get("max_parallel_members") < 1:
        tm["max_parallel_members"] = 4; changes.append("team_mode.max_parallel_members -> 4")
    elif tm.get("max_parallel_members") > 4:
        tm["max_parallel_members"] = 4; changes.append("team_mode.max_parallel_members capped -> 4")
    if not isinstance(tm.get("max_members"), int) or tm.get("max_members") < 5:
        tm["max_members"] = 5; changes.append("team_mode.max_members -> 5 (hyperplan floor)")
    elif tm.get("max_members") > 6:
        tm["max_members"] = 6; changes.append("team_mode.max_members capped -> 6")
    for key, desired in (
        ("max_messages_per_run", 2000),
        ("max_wall_clock_minutes", 45),
        ("max_member_turns", 150),
    ):
        if tm.get(key) != desired:
            tm[key] = desired; changes.append(f"team_mode.{key} -> {desired}")
    for key, default in (
        ("message_payload_max_bytes", 32768),
        ("recipient_unread_max_bytes", 262144),
        ("mailbox_poll_interval_ms", 1000),
    ):
        if not isinstance(tm.get(key), int) or tm.get(key) < 1:
            tm[key] = default; changes.append(f"team_mode.{key} -> {default}")
    if tm.get("mailbox_poll_interval_ms", 0) < 500:
        tm["mailbox_poll_interval_ms"] = 1000; changes.append("team_mode.mailbox_poll_interval_ms floor -> 1000")
    if not isinstance(tm.get("base_dir"), str) or not tm.get("base_dir"):
        tm["base_dir"] = "~/.omo"; changes.append("team_mode.base_dir -> ~/.omo")
# OmO tmux pane layout for team sessions
tx = omo.setdefault("tmux", {})
if isinstance(tx, dict):
    if tx.get("enabled") is not True:
        tx["enabled"] = True; changes.append("tmux.enabled -> true")
    if tx.get("layout") not in ("main-vertical", "main-horizontal", "tiled", "even-horizontal", "even-vertical"):
        tx["layout"] = "main-vertical"; changes.append("tmux.layout -> main-vertical")
    if tx.get("isolation") not in ("inline", "window", "session"):
        tx["isolation"] = "inline"; changes.append("tmux.isolation -> inline")
    if not isinstance(tx.get("main_pane_size"), (int, float)):
        tx["main_pane_size"] = 60; changes.append("tmux.main_pane_size -> 60")
    if not isinstance(tx.get("main_pane_min_width"), (int, float)):
        tx["main_pane_min_width"] = 120; changes.append("tmux.main_pane_min_width -> 120")
    if not isinstance(tx.get("agent_pane_min_width"), (int, float)):
        tx["agent_pane_min_width"] = 40; changes.append("tmux.agent_pane_min_width -> 40")

# Background-task runaway guard — keep concurrency / tool budgets bounded
bt = omo.setdefault("background_task", {})
if isinstance(bt, dict):
    if not isinstance(bt.get("defaultConcurrency"), int) or bt.get("defaultConcurrency") != 10:
        bt["defaultConcurrency"] = 10; changes.append("background_task.defaultConcurrency -> 10 (high-throughput default)")
    pc = bt.setdefault("providerConcurrency", {})
    if isinstance(pc, dict):
        want_pc = {"openrouter": 12}
        for k in list(pc.keys()):
            if k not in want_pc:
                del pc[k]
                changes.append(f"providerConcurrency removed {k} (OpenRouter-only gateway)")
        for prov, cap in want_pc.items():
            if pc.get(prov) != cap:
                pc[prov] = cap
                changes.append(f"providerConcurrency.{prov} -> {cap}")
    mc = bt.setdefault("modelConcurrency", {})
    if isinstance(mc, dict):
        for mk in list(mc.keys()):
            if isinstance(mk, str) and mk.startswith("openai/") and not mk.startswith("openrouter/"):
                del mc[mk]
                changes.append(f"modelConcurrency removed direct alias {mk}")
        def _mc_cap(model_key):
            low = str(model_key).lower()
            if any(x in low for x in ("flash", "floor", "luna", "qwen3.7", "gemini-3.6-flash", "gemini-3-flash", "gemini-3.5-flash-lite")):
                return 10
            if any(x in low for x in ("exacto", "minimax", "glm")):
                return 8
            if any(x in low for x in ("sonnet", "deepseek-v4-pro", "sol", "terra", "gemini-3.1-pro")):
                return 5
            return 2
        wl = (oc.get("provider") or {}).get("openrouter", {}).get("whitelist") or []
        want_mc = {f"openrouter/{w}": _mc_cap(w) for w in wl if isinstance(w, str)}
        if want_mc != mc:
            bt["modelConcurrency"] = want_mc
            changes.append(f"modelConcurrency synced to {len(want_mc)} whitelist models")
    if not isinstance(bt.get("maxToolCalls"), int) or bt.get("maxToolCalls") > 200:
        bt["maxToolCalls"] = 200; changes.append("background_task.maxToolCalls capped -> 200")
    if not isinstance(bt.get("syncPollTimeoutMs"), int) or bt.get("syncPollTimeoutMs") < 60000:
        bt["syncPollTimeoutMs"] = 60000; changes.append("background_task.syncPollTimeoutMs -> 60000 (OmO floor)")
    cb = bt.setdefault("circuitBreaker", {})
    if isinstance(cb, dict):
        cb["enabled"] = True
        if not isinstance(cb.get("maxToolCalls"), int) or cb.get("maxToolCalls") > 160:
            cb["maxToolCalls"] = 160; changes.append("circuitBreaker.maxToolCalls capped -> 160")
rf = omo.setdefault("runtime_fallback", {})
if isinstance(rf, dict):
    desired_retry_codes = [408, 429, 500, 502, 503, 504]
    if rf.get("retry_on_errors") != desired_retry_codes:
        rf["retry_on_errors"] = desired_retry_codes; changes.append("runtime_fallback.retry_on_errors -> transient errors only")
    if rf.get("max_fallback_attempts") != 3:
        rf["max_fallback_attempts"] = 3; changes.append("runtime_fallback.max_fallback_attempts -> 3")
    if rf.get("timeout_seconds") != 120:
        rf["timeout_seconds"] = 120; changes.append("runtime_fallback.timeout_seconds -> 120")
omoexp = omo.setdefault("experimental", {})
if isinstance(omoexp, dict):
    if omoexp.get("aggressive_truncation") is not False:
        omoexp["aggressive_truncation"] = False; changes.append("experimental.aggressive_truncation -> false")
    if omoexp.get("truncate_all_tool_outputs") is not False:
        omoexp["truncate_all_tool_outputs"] = False; changes.append("experimental.truncate_all_tool_outputs -> false")
# OmO 4.19: Goals replace Ralph — drop legacy ralph_loop (ignored when goal is explicit)
if "ralph_loop" in omo:
    del omo["ralph_loop"]; changes.append("removed deprecated ralph_loop (OmO 4.19 Goals replace Ralph)")

# Goal MUST stay off on OmO 4.19.x — chat hook treats /start-work template as setGoal
goal = omo.setdefault("goal", {})
if isinstance(goal, dict):
    if goal.get("enabled") is not False:
        goal["enabled"] = False; changes.append("goal.enabled -> false (protects /start-work)")
    if goal.get("auto_start") is not False:
        goal["auto_start"] = False; changes.append("goal.auto_start -> false")
    if not isinstance(goal.get("default_max_iterations"), int) or goal.get("default_max_iterations") > 24:
        goal["default_max_iterations"] = 24; changes.append("goal.default_max_iterations capped -> 24")
dm = omo.setdefault("default_mode", {})
if isinstance(dm, dict) and dm.get("goal") is not False:
    dm["goal"] = False; changes.append("default_mode.goal -> false")

# Imported Claude MCP configs get no sensitive environment variables.
if omo.get("mcp_env_allowlist") != []:
    omo["mcp_env_allowlist"] = []
    changes.append("mcp_env_allowlist -> [] (no API keys exposed to imported MCPs)")

sw = omo.setdefault("start_work", {})
if isinstance(sw, dict) and sw.get("auto_commit") is not False:
    sw["auto_commit"] = False; changes.append("start_work.auto_commit -> false")

# CodeGraph: keep indexing opt-in, but let OmO manage its pinned daemon runtime.
cg2 = omo.setdefault("codegraph", {})
if isinstance(cg2, dict):
    if cg2.get("auto_init") is not False:
        cg2["auto_init"] = False; changes.append("codegraph.auto_init -> false")
    if cg2.get("auto_provision") is not True:
        cg2["auto_provision"] = True; changes.append("codegraph.auto_provision -> true")
    if cg2.get("daemon") is not True:
        cg2["daemon"] = True; changes.append("codegraph.daemon -> true")

# Hephaestus needs teammate:allow to be a team member (OmO conditional)
agents = omo.setdefault("agents", {})
heph = agents.setdefault("hephaestus", {})
if isinstance(heph, dict):
    hp = heph.setdefault("permission", {})
    if isinstance(hp, dict) and hp.get("teammate") != "allow":
        hp["teammate"] = "allow"
        changes.append("agents.hephaestus.permission.teammate -> allow")
gm = omo.setdefault("git_master", {})
if isinstance(gm, dict):
    if gm.get("include_co_authored_by") is not False:
        gm["include_co_authored_by"] = False; changes.append("git_master.include_co_authored_by -> false")
    if gm.get("commit_footer") is not False:
        gm["commit_footer"] = False; changes.append("git_master.commit_footer -> false")
oexp = omo.setdefault("experimental", {})
if isinstance(oexp, dict) and oexp.get("disable_omo_env") is not True:
    oexp["disable_omo_env"] = True; changes.append("experimental.disable_omo_env -> true")
# Ensure phone-home MCPs stay disabled
dmcps = omo.setdefault("disabled_mcps", [])
if not isinstance(dmcps, list):
    dmcps = []; omo["disabled_mcps"] = dmcps
for must in ("posthog:posthog", "sentry:sentry", "axiom:axiom"):
    if must not in dmcps:
        dmcps.append(must); changes.append(f"disabled_mcps += {must}")

# Wild but clean neon palette for TUI tabs (valid #RRGGBB only — OmO drops non-hex).
# High-chroma, role-distinct, dark-UI readable. oc fix enforces these.
AGENT_COLORS = {
    "sisyphus": "#00F0FF",
    "hephaestus": "#FF5C00",
    "prometheus": "#B967FF",
    "atlas": "#39FF14",
    "oracle": "#6C63FF",
    "librarian": "#00FFD1",
    "explore": "#FFD400",
    "multimodal-looker": "#FF2D95",
    "metis": "#9DFFFF",
    "momus": "#FF8A3D",
    "sisyphus-junior": "#7A8BFF",
    "content-aware-research": "#FF1744",
}
CATEGORY_COLORS = {
    "visual-engineering": "#FF2D95",
    "ultrabrain": "#B967FF",
    "deep": "#00F0FF",
    "artistry": "#FF5C00",
    "quick": "#39FF14",
    "unspecified-low": "#6B7A99",
    "unspecified-high": "#9DFFFF",
    "writing": "#00FFD1",
    "bug-hunt": "#FFD400",
    "refactor-safe": "#3DDC97",
    "arch-review": "#6C63FF",
    "content-aware-fast": "#FF1744",
    "content-aware-deep": "#C51162",
}

for n, a in omo.get("agents", {}).items():
    c = a.get("color")
    want = AGENT_COLORS.get(n)
    if want is not None and str(c).upper() != want.upper():
        a["color"] = want
        changes.append(f"agent {n}: color -> {want}")
    elif c is not None and not HEX.match(str(c)):
        if str(c) in THEME_HEX:
            a["color"] = THEME_HEX[str(c)]
            changes.append(f"agent {n}: color '{c}' -> {a['color']}")
        else:
            del a["color"]
            changes.append(f"agent {n}: removed non-hex color '{c}'")
    for bad in ("hidden", "steps", "thinking", "providerOptions"):
        if bad in a:
            del a[bad]
            changes.append(f"agent {n}: stripped '{bad}'")

for n, a in omo.get("categories", {}).items():
    if not isinstance(a, dict):
        continue
    c = a.get("color")
    want = CATEGORY_COLORS.get(n)
    if want is not None and str(c).upper() != want.upper():
        a["color"] = want
        changes.append(f"category {n}: color -> {want}")
    elif c is not None and not HEX.match(str(c)):
        if str(c) in THEME_HEX:
            a["color"] = THEME_HEX[str(c)]
            changes.append(f"category {n}: color '{c}' -> {a['color']}")
        else:
            del a["color"]
            changes.append(f"category {n}: removed non-hex color '{c}'")

# OmO skills sources — mirror opencode.json (global config + project ./skills)
ALLOWED_SKILL_SOURCES = ["~/.config/opencode/skills", "./skills"]
osk = omo.setdefault("skills", {})
srcs = []
for s in (osk.get("sources") or []):
    srcs.append(s.get("path") if isinstance(s, dict) else str(s))
if srcs != ALLOWED_SKILL_SOURCES:
    omo["skills"] = {"sources": list(ALLOWED_SKILL_SOURCES)}
    changes.append("omo skills.sources -> %s" % ALLOWED_SKILL_SOURCES)

# disable the Claude Code bridge — no external MCP/commands/skills/hooks/agents/plugins imports
cc = omo.get("claude_code")
if isinstance(cc, dict):
    for k in ("mcp", "commands", "skills", "hooks", "agents", "plugins"):
        if cc.get(k) is not False:
            cc[k] = False; changes.append(f"claude_code.{k} -> false (no external import)")

kd = omo.get("keyword_detector", {})
if "enabled_expansions" in kd:
    cleaned = [v for v in kd["enabled_expansions"] if v in KW_ALLOWED]
    if cleaned != kd["enabled_expansions"]:
        kd["enabled_expansions"] = cleaned or ["ultrawork"]; changes.append("keyword_detector: dropped invalid enum values")

# hyperplan: plan must stay callable (demoted subagent); combo expansion needs allowlist entry
exps = list(kd.get("enabled_expansions") or [])
if "hyperplan" in exps:
    da = omo.setdefault("disabled_agents", [])
    if any(str(a).lower() == "plan" for a in da):
        omo["disabled_agents"] = [a for a in da if str(a).lower() != "plan"]
        changes.append("removed 'plan' from disabled_agents (required for hyperplan handoff)")
    if "ultrawork" in exps and "hyperplan-ultrawork" not in exps:
        exps.append("hyperplan-ultrawork")
        kd["enabled_expansions"] = exps
        changes.append("added hyperplan-ultrawork to enabled_expansions")
    tm = omo.setdefault("team_mode", {})
    if tm.get("enabled") is not True:
        tm["enabled"] = True
        changes.append("team_mode.enabled -> true (required for hyperplan)")
    sa = omo.setdefault("sisyphus_agent", {})
    if sa.get("planner_enabled") is False:
        sa["planner_enabled"] = True
        changes.append("sisyphus_agent.planner_enabled -> true (hyperplan)")
    if sa.get("replace_plan") is False:
        sa["replace_plan"] = True
        changes.append("sisyphus_agent.replace_plan -> true (demote plan for hyperplan)")

# drop opencode.json plan.disable when OmO demotes plan (disable fights hyperplan handoff)
if "hyperplan" in (kd.get("enabled_expansions") or []):
    plan_agent = (oc.get("agent") or {}).get("plan")
    if isinstance(plan_agent, dict) and plan_agent.get("disable") is True:
        del oc["agent"]["plan"]
        changes.append("removed agent.plan.disable (OmO demotes plan for hyperplan)")

# ─── quarantine broken ~/.omo/omo.jsonc (invalid OmO migrate → breaks Sisyphus) ─
# OpenConfig canonical OmO config lives in oh-my-openagent.json (repo). A partial
# `oh-my-openagent config migrate` can write agents.*.models arrays that OmO 4.19.4
# rejects — plugin doctor flags them and Sisyphus may fail to load routes.
omo_jsonc_path = os.path.expanduser("~/.omo/omo.jsonc")
repo_omo_path = os.path.join(repo, "oh-my-openagent.json")
if os.path.isfile(omo_jsonc_path) and os.path.isfile(repo_omo_path):
    with open(omo_jsonc_path, encoding="utf-8") as f:
        omo_jsonc_raw = f.read()
    if '"[opencode]"' in omo_jsonc_raw and re.search(r'"models"\s*:\s*\[', omo_jsonc_raw):
        if not dry:
            bdir = os.path.join(backup_root, f"fix-{stamp or 'manual'}")
            os.makedirs(bdir, exist_ok=True)
            shutil.copy2(omo_jsonc_path, os.path.join(bdir, "omo.jsonc"))
            os.remove(omo_jsonc_path)
        changes.append("quarantined ~/.omo/omo.jsonc (invalid migrated agents.models — use oh-my-openagent.json)")

# ─── config-only: scrub install/runtime strays OpenCode may drop here ─────────
STRAYS = (
    "node_modules", "package.json", "package-lock.json", "npm-shrinkwrap.json",
    "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", ".omo", ".sisyphus",
    ".codegraph", "command",
)
for name in STRAYS:
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
        for name in ("opencode.json", "oh-my-openagent.json"):
            src = os.path.join(repo, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(bdir, name))
        if oc != before: dump("opencode.json", oc)
        if omo != ombefore: dump("oh-my-openagent.json", omo)
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
