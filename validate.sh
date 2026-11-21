#!/usr/bin/env bash
# validate.sh — Validate every OpenCode config in this repo.
# Checks JSON syntax, cross-file model references, and the known
# runtime footguns that pass JSON-schema but silently break at runtime.
# Exit 0 = clean, 1 = errors found. Safe to run anytime.
#
# Usage:
#   ./validate.sh           full report
#   ./validate.sh --quiet   summary only (exit code still set)
#
# Related: oc setup · oc doctor · oc secrets

set -euo pipefail

REPO="${OC_VALIDATE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
QUIET=""
for arg in "$@"; do
	case "$arg" in
	--quiet | -q) QUIET="--quiet" ;;
	-h | --help)
		oc_print_script_help "$0"
		exit 0
		;;
	*)
		echo "Unknown flag: $arg (try --quiet)"
		exit 2
		;;
	esac
done

[[ "$QUIET" == "--quiet" ]] && export VALIDATE_QUIET=1

OC_LIVE_CONFIG="$(oc_live_config_root 2>/dev/null || true)"
export OC_LIVE_CONFIG

if [[ -z "${VALIDATE_QUIET:-}" ]]; then
	oc_section "oc validate"
fi

python3 - "$REPO" <<'PY'
import json, sys, os, re, glob, subprocess

repo = sys.argv[1]
errors, warns, oks = [], [], []
def err(m): errors.append(m)
def warn(m): warns.append(m)
def ok(m): oks.append(m)

def load(path):
    with open(path) as f:
        return json.load(f)

# ---- 1. JSON syntax on every .json in the repo ----
json_files = [os.path.join(repo, "opencode.json"),
              os.path.join(repo, "tui.json"),
              os.path.join(repo, "t3-opencode.json")]
json_files += sorted(glob.glob(os.path.join(repo, "profiles", "*.json")))
parsed = {}
for p in json_files:
    if not os.path.exists(p):
        warn(f"missing file: {os.path.relpath(p, repo)}")
        continue
    try:
        parsed[p] = load(p)
        ok(f"valid JSON: {os.path.relpath(p, repo)}")
    except Exception as e:
        err(f"INVALID JSON: {os.path.relpath(p, repo)} — {e}")

oc_path = os.path.join(repo, "opencode.json")
oc = parsed.get(oc_path)
tui_cfg = parsed.get(os.path.join(repo, "tui.json"))

# ---- 2. opencode.json runtime footguns ----
if oc:
    exp = oc.get("experimental", {})
    if "primary_tools" in exp:
        err("opencode.json: experimental.primary_tools present — it DENIES those tools to all subagents. Remove it.")
    else:
        ok("no experimental.primary_tools (subagents keep their tools)")

    prov = oc.get("provider", {}).get("openrouter", {})
    popts = prov.get("options", {})
    if "managementKey" in popts:
        err("opencode.json: provider.openrouter.options.managementKey is not a real key. Remove it.")
    if "defaultHeaders" in popts:
        err("opencode.json: provider.openrouter.options.defaultHeaders is invalid — rename to 'headers'.")
    for timeout_key, expected in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 180000)):
        if popts.get(timeout_key) != expected:
            err(f"opencode.json: provider.openrouter.options.{timeout_key} must be {expected}.")
    import base64
    sig_path = os.path.join(repo, "signature.json")
    want_referer = "https://github.com/jesseoue/opencode-configs"
    if os.path.isfile(sig_path):
        try:
            sig = load(sig_path)
            b64 = (sig.get("github_b64") or "").strip()
            if b64:
                want_referer = base64.b64decode(b64).decode("ascii").rstrip("/")
        except Exception:
            pass
    hdrs = popts.get("headers") if isinstance(popts.get("headers"), dict) else {}
    if hdrs.get("HTTP-Referer") != want_referer:
        err(f"opencode.json: openrouter.headers.HTTP-Referer must match signature github_b64 ({want_referer}). Run: oc fix")
    if hdrs.get("X-Title") != "OpenConfig":
        err("opencode.json: openrouter.headers.X-Title must be OpenConfig")
    if hdrs.get("X-OpenRouter-Title") != "OpenConfig":
        err("opencode.json: openrouter.headers.X-OpenRouter-Title must be OpenConfig")
    # Marketplace categories are hyphenated slugs; "cli,agent" is silently dropped.
    # https://openrouter.ai/docs/app-attribution
    if hdrs.get("X-OpenRouter-Categories") != "cli-agent":
        err("opencode.json: openrouter.headers.X-OpenRouter-Categories must be cli-agent (OpenRouter marketplace). Run: oc fix")
    if (
        hdrs.get("HTTP-Referer") == want_referer
        and hdrs.get("X-Title") == "OpenConfig"
        and hdrs.get("X-OpenRouter-Title") == "OpenConfig"
        and hdrs.get("X-OpenRouter-Categories") == "cli-agent"
    ):
        ok("openrouter attribution headers aligned with signature")
    direct_opts = ((oc.get("provider") or {}).get("openai") or {}).get("options") or {}
    enabled_providers = oc.get("enabled_providers")
    openai_enabled = isinstance(enabled_providers, list) and "openai" in enabled_providers
    if openai_enabled:
        for timeout_key, expected in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 180000)):
            if direct_opts.get(timeout_key) != expected:
                err(f"opencode.json: provider.openai.options.{timeout_key} must be {expected}.")
    elif (oc.get("provider") or {}).get("openai"):
        err("opencode.json: provider.openai present but direct OpenAI disabled — remove block (OpenRouter-only).")
    else:
        ok("direct OpenAI provider absent (OpenRouter-only)")
    for pname in ("venice", "deepseek"):
        popts_p = ((oc.get("provider") or {}).get(pname) or {}).get("options") or {}
        timeout_ok = True
        for timeout_key, expected in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 180000)):
            if popts_p.get(timeout_key) != expected:
                err(f"opencode.json: provider.{pname}.options.{timeout_key} must be {expected}.")
                timeout_ok = False
        if timeout_ok:
            ok(f"provider.{pname} timeout=300s chunkTimeout=180s")
    tool_output = oc.get("tool_output") or {}
    if tool_output.get("max_lines") != 200 or tool_output.get("max_bytes") != 8000:
        err("opencode.json: tool_output must be 200 lines / 8000 bytes.")
    if (oc.get("experimental") or {}).get("mcp_timeout") != 30000:
        err("opencode.json: experimental.mcp_timeout must match the 30000ms Context7 timeout.")
    if oc.get("logLevel") != "ERROR":
        err("opencode.json: logLevel must be ERROR to minimize sensitive runtime logging.")

    # LSP: OpenCode starts with ALL builtins enabled; we must disable extras.
    lsp = oc.get("lsp")
    if lsp is False:
        warn("opencode.json: lsp=false — no language intelligence")
    elif isinstance(lsp, dict):
        enabled = sorted(k for k, v in lsp.items() if isinstance(v, dict) and not v.get("disabled"))
        disabled_n = sum(1 for v in lsp.values() if isinstance(v, dict) and v.get("disabled"))
        expected = {"typescript", "python", "go"}
        if set(enabled) != expected:
            err(f"opencode.json lsp enabled={enabled} — expected exactly {sorted(expected)} (disable other builtins).")
        elif disabled_n < 30:
            warn(f"opencode.json lsp only disables {disabled_n} builtins — OpenCode merges defaults; disable the rest.")
        else:
            ok(f"lsp locked to {sorted(expected)} ({disabled_n} builtins disabled)")
        for name in expected:
            cmd = (lsp.get(name) or {}).get("command") or []
            if not cmd:
                err(f"opencode.json lsp.{name}: missing command")

    models = prov.get("models", {})
    # Whitelist must match models{} keys (orphans / missing entries cause silent routing gaps).
    wl = prov.get("whitelist")
    if isinstance(wl, list):
        wl_set = {x for x in wl if isinstance(x, str) and x.strip()}
        model_keys = set(models.keys())
        missing_models = sorted(wl_set - model_keys)
        orphan_models = sorted(model_keys - wl_set)
        if missing_models:
            err(f"openrouter whitelist entries missing from models{{}}: {missing_models}")
        if orphan_models:
            err(f"openrouter models{{}} not in whitelist: {orphan_models}")
        if not missing_models and not orphan_models and wl_set:
            ok(f"openrouter whitelist ↔ models{{}} synced ({len(wl_set)})")
    # Collect every provider/model id so agent refs to openai/* and openrouter/* both resolve.
    defined_models = set()
    for pname, pcfg in (oc.get("provider") or {}).items():
        if not isinstance(pcfg, dict):
            continue
        for mid in (pcfg.get("models") or {}):
            defined_models.add(f"{pname}/{mid}")
    for mid, m in models.items():
        o = m.get("options", {})
        if "reasoning_effort" in o:
            err(f"opencode.json[{mid}]: options.reasoning_effort is wrong for OpenRouter — use options.reasoning.effort.")
        for k in ("temperature", "top_p", "thinking"):
            if k in o:
                err(f"opencode.json[{mid}]: model-level options.{k} is not honored — set it on the agent (temperature/top_p) or drop it.")
        pv = o.get("provider", {})
        q = pv.get("quantizations")
        fam = m.get("family")
        if pv.get("order"):
            err(f"opencode.json[{mid}]: provider.order disables adaptive load balancing — remove it.")
        if pv.get("data_collection") != "allow":
            err(f"opencode.json[{mid}]: provider.data_collection must be 'allow' for full provider availability.")
        if "zdr" in pv:
            err(f"opencode.json[{mid}]: provider.zdr restricts the provider pool — remove it for availability.")
        expected_require_parameters = fam in ("glm", "minimax")
        # Pin rosters mirror fix.sh want_only — rebuilt from LIVE endpoint data
        # (rechecked 2026-09-08): fp8/full-precision unmoderated hosts only, no
        # fp4, no first-party. glm deliberately unpinned: Auto Exacto +
        # require_parameters pick tool-capable hosts; a static only-roster can
        # blackhole on churn. MiniMax includes parasail (fp8 + tools).
        mid_l = str(mid).lower()
        if "v4.1-flash" in mid_l or "v4-1-flash" in mid_l:
            want_only = ["deepseek", "novita", "deepinfra"]
        else:
            want_only = {
                "deepseek": ["gmicloud", "novita", "siliconflow", "parasail", "deepinfra", "baidu", "fireworks", "digitalocean"],
                "minimax": ["gmicloud", "novita", "deepinfra", "together", "parasail"],
            }.get(fam)
        if want_only is not None:
            if pv.get("only") != want_only:
                err(f"opencode.json[{mid}]: {fam} must pin provider.only={want_only} (live-verified unmoderated hosts, no fp4). Run: oc fix")
            if fam == "deepseek":
                if pv.get("require_parameters") is not False:
                    err(f"opencode.json[{mid}]: deepseek provider.require_parameters must be false. Run: oc fix")
            elif pv.get("require_parameters") is not expected_require_parameters:
                err(
                    f"opencode.json[{mid}]: provider.require_parameters must be "
                    f"{str(expected_require_parameters).lower()} for {fam} routing."
                )
        else:
            if pv.get("only"):
                err(f"opencode.json[{mid}]: stale provider.only pin {pv.get('only')} — {fam or 'this family'} has no live pin roster. Run: oc fix")
            if pv.get("require_parameters") is not expected_require_parameters:
                err(
                    f"opencode.json[{mid}]: provider.require_parameters must be "
                    f"{str(expected_require_parameters).lower()} for {fam} routing."
                )
        # OpenRouter auto-routes by default. :exacto/:nitro/:floor are virtual
        # suffixes (not catalog slugs). Keep provider selection lean: no
        # sort/order/ignore/preferred_* that fights Auto Exacto.
        api_id = m.get("id") or mid
        sort = pv.get("sort")
        if sort in ("price", "throughput", "latency", "exacto"):
            warn(f"opencode.json[{mid}]: provider.sort={sort!r} overrides OpenRouter auto-ranking — prefer dropping sort.")
        if pv.get("order"):
            err(f"opencode.json[{mid}]: provider.order overrides auto-ranking — remove order.")
        if pv.get("ignore"):
            err(f"opencode.json[{mid}]: provider.ignore narrows fallback coverage — remove it.")
        if "preferred_min_throughput" in pv or "preferred_max_latency" in pv:
            err(f"opencode.json[{mid}]: preferred_* fights OpenRouter adaptive ranking — remove (run: oc fix)")
        # Claude and DeepSeek have first-party endpoints reporting quant 'unknown'
        # (DeepSeek first-party is the cheapest + best cache) — filtering without
        # 'unknown' matches ZERO providers for them. GLM excluding low quant
        # (fp4) to keep tool-calling quality is intended and fine.
        if q is not None and "unknown" not in q and fam in ("claude", "deepseek"):
            err(f"opencode.json[{mid}]: quantizations {q} excludes 'unknown' — {fam} first-party endpoints report unknown and will be dropped.")
        if fam == "claude":
            if pv.get("require_parameters") is True:
                err(f"opencode.json[{mid}]: Claude + require_parameters:true blackholes requests (endpoints omit temperature). Set false.")
            if m.get("temperature") is True:
                warn(f"opencode.json[{mid}]: Claude 5 endpoints do not support temperature — set model temperature:false.")
        for vn, vv in m.get("variants", {}).items():
            if isinstance(vv, dict) and "options" in vv:
                err(f"opencode.json[{mid}].variants.{vn}: variant contents merge directly — remove the 'options' wrapper.")
            if isinstance(vv, dict) and "reasoning_effort" in vv:
                err(f"opencode.json[{mid}].variants.{vn}: use reasoning.effort, not reasoning_effort.")

    perm = oc.get("permission", {})
    if "write" in perm:
        warn("opencode.json: permission.write is not a real permission (edit covers writes).")
    if isinstance(perm.get("bash"), dict) and "doom_loop" in perm["bash"]:
        warn("opencode.json: 'doom_loop' inside the bash pattern map is meaningless — use the top-level doom_loop permission.")

    # Core OpenCode tools must be allow (trusted local box)
    for t in ("task", "edit", "external_directory", "doom_loop", "question",
              "lsp", "webfetch"):
        if perm.get(t) != "allow":
            err(f"permission.{t} must be allow (got {perm.get(t)!r})")
    read_perm = perm.get("read")
    if not (
        isinstance(read_perm, dict)
        and read_perm.get("*") == "allow"
        and read_perm.get("*.env") == "deny"
        and read_perm.get("*.env.*") == "deny"
        and read_perm.get("*.env.example") == "allow"
    ):
        err("permission.read must allow * and deny .env / .env.* (OpenCode default). Run: oc fix")
    else:
        ok("permission.read denies .env (OpenCode docs default)")
    if oc.get("subagent_depth") != 1:
        err("opencode.json: subagent_depth must be 1 (OpenCode default; no nested Task storms).")
    else:
        ok("subagent_depth = 1")
    compaction = oc.get("compaction") or {}
    if compaction.get("auto") is not True or compaction.get("prune") is not True or compaction.get("reserved") != 24000:
        err("opencode.json: compaction must be auto+prune with reserved 24000 (docs: auto/prune/reserved).")
    else:
        ok("compaction auto/prune/reserved=24000")
    bash = perm.get("bash")
    if not (isinstance(bash, dict) and bash.get("*") == "allow"):
        err("permission.bash['*'] must be allow (allow-everything mode)")
    else:
        want_deny = {
            "rm -rf /", "rm -rf /*", "rm -rf ~", "rm -rf ~/*",
            "mkfs*", "sudo *", "sudo",
            "git push --force*", "git push -f*", "gh repo delete*",
        }
        missing_deny = sorted(p for p in want_deny if bash.get(p) != "deny")
        if missing_deny:
            err(f"permission.bash missing catastrophic deny: {missing_deny} — run: oc fix")
        else:
            ok("core tools + bash allow-everything (catastrophic denies kept)")
    if not oc.get("enabled_providers"):
        warn("opencode.json: enabled_providers not set — all providers with credentials will load.")
    elif oc.get("enabled_providers") != ["openrouter", "venice", "deepseek"]:
        err("opencode.json: enabled_providers must be ['openrouter', 'venice', 'deepseek']")
    else:
        ok("enabled_providers = openrouter + venice + deepseek")
    vmodels = set(((((oc.get("provider") or {}).get("venice") or {}).get("models")) or {}))
    if "deepseek-v4-pro-0813" not in vmodels:
        err("venice must expose deepseek-v4-pro-0813 (content-aware DeepSeek primary)")
    else:
        ok("venice exposes deepseek-v4-pro-0813 for content-aware")
    if "deepseek-v4-1-flash" not in vmodels:
        err("venice must expose deepseek-v4-1-flash (content-aware-fast / V4.1 Flash)")
    else:
        ok("venice exposes deepseek-v4-1-flash for content-aware-fast")
    vwl = (((oc.get("provider") or {}).get("venice") or {}).get("whitelist"))
    if vwl is None:
        ok("venice has no whitelist (full Venice catalog; curated models{} keep overrides)")
    elif set(vwl) != vmodels:
        err("venice whitelist must match venice.models (keeps T3 Variant/Agent on curated slugs)")
    else:
        ok("venice whitelist matches curated models")
    vprov = ((oc.get("provider") or {}).get("venice") or {})
    vopts = vprov.get("options") or {}
    if vprov.get("npm") != "@ai-sdk/openai-compatible":
        err("provider.venice.npm must be @ai-sdk/openai-compatible (direct Venice API, not OpenRouter)")
    elif str(vopts.get("baseURL") or "") != "https://api.venice.ai/api/v1":
        err("provider.venice.options.baseURL must be https://api.venice.ai/api/v1")
    elif "apiKey" in vprov or "apiKey" in vopts or "{env:VENICE" in json.dumps(vprov):
        err("provider.venice must not embed apiKey / {env:VENICE} — use opencode auth + .env")
    else:
        ok("venice is a first-party provider (api.venice.ai, no key in JSON)")
    VENICE_REASONING_REQUIRED = {"e2ee-glm-5-2-p", "e2ee-glm-5-3-p", "e2ee-kimi-k3-p", "muse-wonder"}  # Venice rejects disable_thinking on these
    VENICE_NO_TOOLS = {"grok-4-20-multi-agent", "e2ee-gemma-4-26b-a4b-uncensored-p", "e2ee-gpt-oss-120b-p", "e2ee-qwen-2-5-7b-p"}  # Venice: no function calling
    venice_thinking_ok = True
    venice_uncensored_ok = True
    for vm, vcfg in ((((oc.get("provider") or {}).get("venice") or {}).get("models")) or {}).items():
        if not isinstance(vcfg, dict):
            continue
        vopts = vcfg.get("options") or {}
        if vopts.get("disable_thinking") is True:
            err(f"venice/{vm} options.disable_thinking is top-level — Venice 400s; nest under venice_parameters")
            venice_thinking_ok = False
        vp = vopts.get("venice_parameters") or {}
        want_thinking_off = vm not in VENICE_REASONING_REQUIRED
        if want_thinking_off and vp.get("disable_thinking") is not True:
            err(f"venice/{vm} options.venice_parameters.disable_thinking must be true (top-level disable_thinking is an unrecognized key)")
            venice_thinking_ok = False
        if not want_thinking_off and "disable_thinking" in vp:
            err(f"venice/{vm} requires reasoning — remove venice_parameters.disable_thinking")
            venice_thinking_ok = False
        if vm in VENICE_NO_TOOLS and vcfg.get("tool_call") is not False:
            err(f"venice/{vm} has no function calling on Venice — set tool_call: false")
        if vp.get("include_venice_system_prompt") is not False:
            err(f"venice/{vm} options.venice_parameters.include_venice_system_prompt must be false (Venice system prompt re-adds content guidance)")
            venice_uncensored_ok = False
        for vn, vv in (vcfg.get("variants") or {}).items():
            if not isinstance(vv, dict):
                continue
            if vv.get("disable_thinking") is True:
                err(f"venice/{vm} variants.{vn}.disable_thinking is top-level — Venice 400s; nest under venice_parameters")
                venice_thinking_ok = False
            if want_thinking_off and (vv.get("venice_parameters") or {}).get("disable_thinking") is not True:
                err(f"venice/{vm} variants.{vn}.venice_parameters.disable_thinking must be true")
                venice_thinking_ok = False
            if not want_thinking_off and "disable_thinking" in (vv.get("venice_parameters") or {}):
                err(f"venice/{vm} variants.{vn} requires reasoning — remove venice_parameters.disable_thinking")
                venice_thinking_ok = False
            if (vv.get("venice_parameters") or {}).get("include_venice_system_prompt") is not False:
                err(f"venice/{vm} variants.{vn}.venice_parameters.include_venice_system_prompt must be false (variant must stay uncensored even if merge semantics change)")
                venice_uncensored_ok = False
    or_models_chk = (((oc.get("provider") or {}).get("openrouter") or {}).get("models")) or {}
    for mid, m in or_models_chk.items() if isinstance(or_models_chk, dict) else []:
        o = (m or {}).get("options") or {}
        if o.get("disable_thinking") is True or (o.get("venice_parameters") or {}).get("disable_thinking") is True:
            err(f"openrouter {mid}: disable_thinking is Venice-only — do not set it on OpenRouter/GLM")
            venice_thinking_ok = False
    ds_models_chk = (((oc.get("provider") or {}).get("deepseek") or {}).get("models")) or {}
    for mid, m in ds_models_chk.items() if isinstance(ds_models_chk, dict) else []:
        o = (m or {}).get("options") or {}
        if o.get("disable_thinking") is True or (o.get("venice_parameters") or {}).get("disable_thinking") is True:
            err(f"deepseek {mid}: disable_thinking is Venice-only — native DeepSeek stays separate")
            venice_thinking_ok = False
    if venice_thinking_ok:
        ok("venice models pin venice_parameters.disable_thinking except reasoning-required ones (OpenRouter/native DeepSeek do not)")
    if venice_uncensored_ok:
        ok("venice models + variants pin include_venice_system_prompt=false (direct lane stays uncensored)")
    or_wl = set((((oc.get("provider") or {}).get("openrouter") or {}).get("whitelist")) or [])
    venice_slugs = {"deepseek-v4-pro-0813", "deepseek-v4-pro", "deepseek-v4-1-flash"}
    leaked_venice = sorted(x for x in or_wl if x in venice_slugs or str(x).startswith("venice/"))
    if leaked_venice:
        err(f"openrouter whitelist must not carry Venice slugs {leaked_venice} — Venice is its own provider")
    dmodels = set(((((oc.get("provider") or {}).get("deepseek") or {}).get("models")) or {}))
    dwl = ((((oc.get("provider") or {}).get("deepseek") or {}).get("whitelist")) or [])
    if "deepseek-v4-pro" not in dmodels or "deepseek-flash" not in dmodels:
        err("deepseek must expose deepseek-v4-pro and deepseek-flash (native DeepSeek lane)")
    elif set(dwl) != dmodels:
        err("deepseek whitelist must match deepseek.models")
    else:
        ok("deepseek exposes native V4 Pro + Flash")
    for vm in vmodels:
        vars_ = ((((oc.get("provider") or {}).get("venice") or {}).get("models") or {}).get(vm) or {}).get("variants") or {}
        if set(vars_) != {"low", "medium", "high", "max"}:
            err(f"venice/{vm} must define variants low/medium/high/max")
        else:
            ok(f"venice/{vm} variants low/medium/high/max")

# ---- 2b. no plugin pins (vanilla OpenCode) ----
for _name, _cfg in (("opencode.json", oc), ("tui.json", tui_cfg)):
    _pins = [p for p in ((_cfg or {}).get("plugin") or []) if isinstance(p, str) and "oh-my-" in p]
    if _pins:
        err(f"{_name}: oh-my-* plugin pinned ({_pins}); this stack is vanilla OpenCode")
    else:
        ok(f"{_name}: no oh-my-* plugin pin")

# ---- 4. config-only purity (install artifacts must stay gitignored + absent) ----
STRAYS = (
    "node_modules", "package.json", "package-lock.json", "npm-shrinkwrap.json",
    "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", ".omo", ".runtime", ".sisyphus",
    ".codegraph", "command", ".opencode", "plugins",
)

def _is_opencode_sdk_install(repo):
    # opencode >= 1.19 drops @opencode-ai/plugin into the config dir on every
    # startup; tolerate exactly that install, flag anything else.
    pj = os.path.join(repo, "package.json")
    if not os.path.isfile(pj):
        return False
    try:
        d = json.load(open(pj, encoding="utf-8"))
    except Exception:
        return False
    return set(d.get("dependencies") or {}) == {"@opencode-ai/plugin"}

_sdk_install = _is_opencode_sdk_install(repo)
_tol = {"node_modules", "package.json", "package-lock.json"} if _sdk_install else set()
present = [s for s in STRAYS if os.path.lexists(os.path.join(repo, s)) and s not in _tol]
if present:
    err(f"config-only violation — remove install/runtime strays: {present} (run ./cleanup.sh or ./fix.sh)")
elif _sdk_install:
    ok("config dir clean (OpenCode plugin-SDK runtime install tolerated)")
else:
    ok("config dir clean (no node_modules/package.json/.omo/.runtime/.sisyphus/command/plugins)")

# git must ignore the common install paths (even when absent)
ignore_targets = [
    "node_modules", "node_modules/pkg", "package.json", "package-lock.json",
    "bun.lock", ".omo", ".runtime", ".sisyphus", ".codegraph", "command", ".opencode",
    ".cursor", "plugins", "stray-not-in-allowlist.txt", "opencode.log", "logs/x.log",
    "vault.local.json",
]
try:
    r = subprocess.run(
        ["git", "check-ignore", "-v", "--"] + ignore_targets,
        cwd=repo, capture_output=True, text=True, check=False,
    )
    ignored = {line.split("\t")[-1] for line in r.stdout.splitlines() if "\t" in line}
    required = {
        "node_modules", "package.json", ".omo", ".runtime", ".sisyphus", ".codegraph",
        "command", ".opencode", ".cursor", "plugins",
        "stray-not-in-allowlist.txt", "opencode.log",
        "vault.local.json",
    }
    missing_ignore = sorted(required - ignored)
    if missing_ignore:
        err(f".gitignore does not cover: {missing_ignore}")
    else:
        ok(".gitignore covers strays + deny-all outside allowlist")
    # Deny-all shape: root /* plus allowlist markers
    gi = open(os.path.join(repo, ".gitignore"), encoding="utf-8").read().splitlines()
    gi_noncomment = [ln.strip() for ln in gi if ln.strip() and not ln.strip().startswith("#")]
    if "/*" not in gi_noncomment:
        err(".gitignore missing root deny-all '/*' (config-only allowlist required)")
    elif "!prompts/" not in gi_noncomment and "!prompts/**" not in gi_noncomment:
        err(".gitignore deny-all missing prompts/ allowlist entries")
    elif "!.github/" not in gi_noncomment and "!.github/**" not in gi_noncomment:
        err(".gitignore deny-all missing .github/ allowlist (CI workflows would be untracked)")
    else:
        ok(".gitignore is deny-all + allowlist (config-only)")
    wf = os.path.join(repo, ".github", "workflows", "check.yml")
    if not os.path.isfile(wf):
        err(".github/workflows/check.yml missing — hermetic CI required")
    else:
        ok("GitHub Actions check.yml present")
except FileNotFoundError:
    warn("git not available — skipped ignore coverage check")

# ---- 4b1. native agents resolve (models, default agent, read-only lanes) ----
import re as _re
agents_dir = os.path.join(repo, "agents")
REQUIRED_AGENTS = {"lead", "build", "plan", "explore", "librarian", "oracle", "junior",
                   "content-aware-research", "content-aware-fast", "content-aware-deep", "context-aware-hermes"}
READ_ONLY_AGENTS = {"explore", "librarian", "oracle", "content-aware-research", "content-aware-fast",
                    "content-aware-deep", "context-aware-hermes"}
_found = {}
for fn in sorted(os.listdir(agents_dir)) if os.path.isdir(agents_dir) else []:
    if fn.endswith(".md"):
        _text = open(os.path.join(agents_dir, fn), encoding="utf-8").read()
        _m = _re.match(r"---\n(.*?)\n---\n", _text, _re.S)
        _found[fn[:-3]] = _m.group(1) if _m else ""
_missing = REQUIRED_AGENTS - set(_found)
if _missing:
    err(f"agents/: missing required agents {sorted(_missing)}")
else:
    ok(f"{len(_found)} native agents present")
_providers = (oc or {}).get("provider") or {}
for _name, _fm in _found.items():
    _mm = _re.search(r"^model:\s*(\S+)", _fm, _re.M)
    if not _mm:
        err(f"agents/{_name}.md: no model in frontmatter")
        continue
    _prov, _, _model = _mm.group(1).partition("/")
    if _model not in ((_providers.get(_prov) or {}).get("models") or {}):
        err(f"agents/{_name}.md: model {_mm.group(1)} is not in opencode.json provider.{_prov}.models")
    if _name.startswith("content-aware") and _prov != "venice":
        err(f"agents/{_name}.md: content-aware lanes must stay on venice (got {_prov})")
    if _name in READ_ONLY_AGENTS and not _re.search(r"^\s+edit:\s*deny", _fm, _re.M):
        err(f"agents/{_name}.md: read-only agent must set permission.edit: deny")
_default = (oc or {}).get("default_agent")
if _default not in _found:
    err(f"opencode.json: default_agent {_default!r} has no agents/*.md")
else:
    ok(f"default_agent {_default} resolves")
for fn in sorted(os.listdir(os.path.join(repo, "profiles"))):
    if fn.endswith(".json"):
        _da = load(os.path.join(repo, "profiles", fn)).get("default_agent")
        if _da and _da not in _found:
            err(f"profiles/{fn}: default_agent {_da!r} has no agents/*.md")

# ---- 4c. profile instructions[] must resolve (repo-relative from profiles/) ----
prof_missing = []
prof_checked = 0
for pj in sorted(glob.glob(os.path.join(repo, "profiles", "*.json"))):
    try:
        pdata = json.load(open(pj))
    except Exception as e:
        err(f"profiles/{os.path.basename(pj)}: invalid JSON ({e})")
        continue
    for model_field in ("model", "small_model"):
        model_ref = pdata.get(model_field)
        if not model_ref:
            continue
        if model_ref not in defined_models:
            err(f"profiles/{os.path.basename(pj)}: {model_field} references undefined model {model_ref!r}")
        if enabled_providers is not None and model_ref.split("/", 1)[0] not in enabled_providers:
            err(f"profiles/{os.path.basename(pj)}: {model_field} uses disabled provider {model_ref!r}")
    for instr in pdata.get("instructions") or []:
        if not isinstance(instr, str) or not instr.strip():
            continue
        prof_checked += 1
        # profiles use ../AGENTS.md style paths relative to the profile file
        resolved = os.path.normpath(os.path.join(os.path.dirname(pj), instr))
        if not os.path.isfile(resolved):
            # also try repo-root relative
            alt = os.path.normpath(os.path.join(repo, instr.lstrip("./")))
            if not os.path.isfile(alt):
                prof_missing.append(f"{os.path.basename(pj)} -> {instr}")
if prof_missing:
    err(f"profile instructions paths missing: {prof_missing}")
elif prof_checked:
    ok(f"{prof_checked} profile instruction path(s) resolve")

# ---- 4c2. projects.json (oc new home) ----
projects_cfg = os.path.join(repo, "projects.json")
if not os.path.isfile(projects_cfg):
    err("projects.json missing (defines OC_PROJECTS_DIR default for oc new)")
else:
    try:
        pdata = json.load(open(projects_cfg))
        pd = pdata.get("projects_dir")
        dprof = pdata.get("default_profile")
        dws = pdata.get("default_workspace")
        if not isinstance(pd, str) or not pd.strip():
            err("projects.json: projects_dir must be a non-empty string")
        else:
            ok(f"projects.json projects_dir={pd!r}")
        if not isinstance(dprof, str) or not dprof.strip():
            err("projects.json: default_profile must be a non-empty string")
        else:
            pref = os.path.join(repo, "profiles", f"{dprof}.json")
            if not os.path.isfile(pref):
                err(f"projects.json: default_profile {dprof!r} has no profiles/{dprof}.json")
            else:
                ok(f"projects.json default_profile={dprof!r}")
        if dws is None or dws == "":
            ok("projects.json default_workspace defaults to 'workspace'")
        elif not isinstance(dws, str) or "/" in dws or dws in (".", ".."):
            err("projects.json: default_workspace must be a single path segment (e.g. 'workspace')")
        else:
            ok(f"projects.json default_workspace={dws!r}")
    except Exception as e:
        err(f"projects.json: invalid JSON ({e})")

# ---- 4c3. versions.json (supported tool minima) ----
versions_cfg = os.path.join(repo, "versions.json")
if not os.path.isfile(versions_cfg):
    err("versions.json missing (OpenCode / Ghostty / tmux minima for doctor)")
else:
    try:
        vdata = json.load(open(versions_cfg))
        for path in ("opencode.min", "ghostty.min", "tmux.min"):
            cur = vdata
            ok_path = True
            for part in path.split("."):
                if not isinstance(cur, dict) or part not in cur:
                    err(f"versions.json missing {path}")
                    ok_path = False
                    break
                cur = cur[part]
            if ok_path and (not isinstance(cur, str) or not cur.strip()):
                err(f"versions.json {path} must be a non-empty string")
        ok("versions.json present")
    except Exception as e:
        err(f"versions.json: invalid JSON ({e})")

# ---- 4c4. tmux.conf present (Ghostty) ----
tmux_conf = os.path.join(repo, "tmux.conf")
if not os.path.isfile(tmux_conf):
    err("tmux.conf missing")
else:
    body = open(tmux_conf, encoding="utf-8").read()
    missing_tmux = []
    for needle, label in (
        ("allow-passthrough", "allow-passthrough"),
        ("focus-events", "focus-events"),
        ("main-vertical", "main-vertical layout bind"),
        ("pbcopy", "pbcopy clipboard"),
        ("200000", "large history-limit"),
    ):
        if needle not in body:
            missing_tmux.append(label)
    if missing_tmux:
        err(f"tmux.conf missing: {', '.join(missing_tmux)}")
    else:
        ok("tmux.conf has Ghostty essentials")

# ---- 4c5. ghostty.conf essentials ----
ghostty_conf = os.path.join(repo, "ghostty.conf")
if not os.path.isfile(ghostty_conf):
    err("ghostty.conf missing")
else:
    gbody = open(ghostty_conf, encoding="utf-8").read()
    missing_g = []
    for needle, label in (
        ("notify-on-command-finish", "notify-on-command-finish"),
        ("shell-integration", "shell-integration"),
        ("scrollback-limit", "scrollback-limit"),
        ("macos-option-as-alt", "macos-option-as-alt"),
        ("auto-update = off", "auto-update = off"),
    ):
        if needle not in gbody:
            missing_g.append(label)
    if missing_g:
        err(f"ghostty.conf missing: {', '.join(missing_g)}")
    else:
        ok("ghostty.conf has OpenConfig essentials")

# ---- 4c6. OpenConfig CLI surface + required scripts ----
required_scripts = [
    "oc", "install.sh", "setup.sh", "doctor.sh", "validate.sh", "fix.sh",
    "cleanup.sh", "run.sh", "opencode.sh", "openrouter-admin.sh",
    "diagnose.sh", "maintain.sh", "models.sh", "versions.sh", "locate.sh", "signature.sh",
    "deploy-guard.sh", "lib/common.sh",
]
missing_scripts = []
nonexec = []
for rel in required_scripts:
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        missing_scripts.append(rel)
    elif rel != "lib/common.sh" and not os.access(path, os.X_OK):
        nonexec.append(rel)
if missing_scripts:
    err(f"missing required scripts: {missing_scripts}")
else:
    ok(f"{len(required_scripts)} required scripts present")
if nonexec:
    err(f"scripts not executable: {nonexec}")
elif not missing_scripts:
    ok("required scripts are executable")

for leftover in ("cursor.sh", "cursor-openrouter.json", "cursor-venice.json"):
    if os.path.isfile(os.path.join(repo, leftover)):
        err(f"{leftover} must not exist — OpenConfig does not wire Cursor IDE")

t3_spec_path = os.path.join(repo, "t3-opencode.json")
if not os.path.isfile(t3_spec_path):
    err("t3-opencode.json missing")
else:
    try:
        t3 = json.load(open(t3_spec_path, encoding="utf-8"))
        if t3.get("serverUrl") != "http://127.0.0.1:4097":
            err("t3-opencode.json serverUrl must be http://127.0.0.1:4097")
        blob = json.dumps(t3)
        if "sk-" in blob or "VENICE_" in blob or "apiKey" in blob:
            err("t3-opencode.json must not contain keys or apiKey fields")
        _orp = (oc.get("provider") or {}).get("openrouter") or {}
        or_wl = set(_orp.get("whitelist") or _orp.get("models") or {})
        venice_models = set(((((oc.get("provider") or {}).get("venice") or {}).get("models")) or {}))
        extras = []
        for m in (t3.get("catalogModels") or []) + (t3.get("customModels") or []):
            if m.startswith("openrouter/"):
                if m.split("/", 1)[1] not in or_wl:
                    extras.append(m)
            elif m.startswith("venice/"):
                if m.split("/", 1)[1] not in venice_models:
                    extras.append(m)
            else:
                extras.append(m)
        if extras:
            err(f"t3-opencode.json customModels not on curated providers: {extras}")
        else:
            ok(f"t3-opencode.json ({len(t3.get('customModels') or [])} models → 4097)")
    except json.JSONDecodeError as e:
        err(f"t3-opencode.json invalid JSON: {e}")

common_sh = open(os.path.join(repo, "lib/common.sh"), encoding="utf-8").read()
missing_helpers = [fn for fn in (
    "oc_banner", "oc_section", "oc_projects_dir", "oc_ensure_launch_workspace", "oc_resolve_launch_dir",
    "oc_agent_visibility_report", "oc_log_misuse_report",
    "oc_version_ge", "oc_write_project_opencode_json", "oc_expand_path",
    "oc_set_env_key_if_unset", "oc_ensure_env_file", "oc_link_points_to", "oc_ensure_symlink",
    "oc_verify_signature", "oc_signature_compute", "oc_signature_refresh",
    "oc_scrub_env_to_allowlist", "oc_import_allowlisted_dotenv", "oc_env_foreign_key_count",
    "oc_secrets_sync", "oc_secrets_backend", "oc_export_vault_allowlist", "oc_vault_op_refs",
    "oc_backup_copy",
) if f"{fn}()" not in common_sh]
if missing_helpers:
    err(f"lib/common.sh missing helpers: {missing_helpers}")
elif "OpenConfig" in common_sh:
    ok("lib/common.sh has OpenConfig banner + path/version helpers")

# Secrets hygiene: .env must never be tracked; launch must not wrap vault CLIs
env_tracked = subprocess.run(
    ["git", "-C", repo, "ls-files", "--error-unmatch", ".env"],
    capture_output=True, text=True,
).returncode == 0
if env_tracked:
    err(".env is tracked by git — remove it immediately (secrets leak)")
else:
    ok(".env is not tracked by git")
wrap_needles = (
    "infisical run --",
    "op run --",
    "doppler run --",
)
for rel in ("opencode.sh", "run.sh", "oc", "launch-desktop.sh", "serve-desktop.sh", "setup.sh", "lib/common.sh"):
    body = open(os.path.join(repo, rel), encoding="utf-8").read()
    hits = [n.strip() for n in wrap_needles if n in body]
    if hits:
        err(f"{rel}: vault process wrap ({', '.join(hits)}) — use oc secrets sync")
vault_path = os.path.join(repo, "vault.json")
if not os.path.isfile(vault_path):
    err("vault.json missing (1Password / Infisical refs)")
else:
    try:
        vault = json.load(open(vault_path, encoding="utf-8"))
        refs = ((vault.get("onepassword") or {}).get("refs") or {})
        bad_refs = [k for k, v in refs.items() if not isinstance(v, str) or not v.startswith("op://")]
        leaked = []
        raw = open(vault_path, encoding="utf-8").read()
        if re.search(r"sk-or-v1-|sk-[A-Za-z0-9]{20,}", raw):
            leaked.append("looks like a live API key")
        if re.search(r"[a-z0-9.-]+\.1password\.com", raw):
            leaked.append("1Password account hostname")
        if re.search(r"op://[a-z0-9]{20,}/", raw):
            leaked.append("live vault/item id")
        vault_id = ((vault.get("onepassword") or {}).get("vault_id") or "")
        if isinstance(vault_id, str) and re.fullmatch(r"[a-z0-9]{16,}", vault_id):
            leaked.append("live vault_id")
        if bad_refs:
            err(f"vault.json refs must be op://… ({bad_refs})")
        elif leaked:
            err(f"vault.json must stay generic — put personal refs in vault.local.json ({', '.join(leaked)})")
        elif not refs:
            ok("vault.json has empty 1Password refs (fill vault.local.json or example op://Vault/Item/field)")
        else:
            ok(f"vault.json ({len(refs)} example 1Password refs, no personal ids)")
    except Exception as e:
        err(f"vault.json invalid: {e}")
if not any(
    needle in open(os.path.join(repo, rel), encoding="utf-8").read()
    for rel in ("opencode.sh", "run.sh", "oc", "launch-desktop.sh", "serve-desktop.sh")
    for needle in ("infisical run --", "op run --", "doppler run --")
):
    ok("launch/run paths do not wrap op/infisical/doppler")
else:
    err("launch/run still wraps a secrets CLI")

oc_cli = open(os.path.join(repo, "oc"), encoding="utf-8").read()
if "OpenConfig" not in oc_cli:
    err("oc CLI missing OpenConfig branding")
elif "do_install" not in oc_cli and 'install)' not in oc_cli:
    err("oc CLI missing install command")
elif "do_heal" not in oc_cli and 'heal)' not in oc_cli:
    err("oc CLI missing heal (self-repair) command")
elif "do_test" not in oc_cli and 'test)' not in oc_cli:
    err("oc CLI missing test command")
elif "locate" not in oc_cli:
    err("oc CLI missing locate command")
elif "signature" not in oc_cli:
    err("oc CLI missing signature command")
elif "do_secrets" not in oc_cli:
    err("oc CLI missing secrets command")
else:
    ok("oc CLI branded OpenConfig with install + heal + locate + test + signature + secrets")

# ---- 4c7. docs / env example / bunfig / zshrc ----
for rel, label in (
    ("AGENTS.md", "AGENTS.md"),
    ("README.md", "README.md"),
    (".env.example", ".env.example"),
    ("bunfig.toml", "bunfig.toml"),
    ("zshrc.snippet", "zshrc.snippet"),
    ("projects.json", "projects.json"),
    ("vault.json", "vault.json"),
):
    if not os.path.isfile(os.path.join(repo, rel)):
        err(f"{label} missing")
    else:
        ok(f"{label} present")

env_ex = open(os.path.join(repo, ".env.example"), encoding="utf-8").read()
for key in ("OPENROUTER_API_KEY", "EXA_API_KEY", "CONTEXT7_API_KEY", "VENICE_API_KEY",
            "DEEPSEEK_API_KEY", "OC_PROJECTS_DIR", "OC_DEFAULT_WORKSPACE", "OC_DEFAULT_PROFILE"):
    if key not in env_ex:
        err(f".env.example missing {key}")
if "OPENROUTER_API_KEY" in env_ex and "OC_PROJECTS_DIR" in env_ex and "OC_DEFAULT_PROFILE" in env_ex:
    ok(".env.example has required/optional key placeholders")

readme = open(os.path.join(repo, "README.md"), encoding="utf-8").read()
if "# OpenConfig" not in readme and "OpenConfig" not in readme[:500]:
    warn("README.md should lead with OpenConfig branding")
else:
    ok("README.md branded OpenConfig")

install_sh = open(os.path.join(repo, "install.sh"), encoding="utf-8").read()
if "githubusercontent.com/openconfig/opencode-configs" in install_sh or "github.com/openconfig/opencode-configs" in install_sh:
    err("install.sh still points at github.com/openconfig/opencode-configs")
else:
    ok("install.sh distribution URL is jesseoue/opencode-configs")

zshrc = open(os.path.join(repo, "zshrc.snippet"), encoding="utf-8").read()
if re.search(r"export OPENAI_API_KEY|OPENAI_API_KEY\|", zshrc):
    err("zshrc.snippet must not export OPENAI_API_KEY")
elif "OC_DEFAULT_PROFILE" not in zshrc:
    err("zshrc.snippet missing OC_DEFAULT_PROFILE")
elif "VENICE_API_KEY" not in zshrc or "DEEPSEEK_API_KEY" not in zshrc:
    err("zshrc.snippet must allowlist VENICE_API_KEY and DEEPSEEK_API_KEY")
elif "TERM=xterm-256color" not in zshrc:
    err("zshrc.snippet must launch OpenCode with TERM=xterm-256color")
elif "1049l" in zshrc:
    err("zshrc.snippet must not send \\033[?1049l (clears the visible terminal)")
else:
    ok("zshrc.snippet allowlist + TERM + no alt-screen teardown")

profiles = sorted(glob.glob(os.path.join(repo, "profiles", "*.json")))
if len(profiles) < 7:
    err(f"expected ≥7 profiles, found {len(profiles)}")
else:
    ok(f"{len(profiles)} profiles present")

# ---- 4c9b. Telemetry / phone-home kill switches ----
tel_issues = []
if oc.get("share") != "disabled":
    tel_issues.append(f"share={oc.get('share')!r} (want disabled)")
if oc.get("logLevel") != "ERROR":
    tel_issues.append(f"logLevel={oc.get('logLevel')!r} (want ERROR)")
if oc.get("autoupdate") is not False:
    tel_issues.append("autoupdate not false")
if (oc.get("experimental") or {}).get("openTelemetry") is not False:
    tel_issues.append("experimental.openTelemetry not false")
if (oc.get("server") or {}).get("mdns") is not False:
    tel_issues.append("server.mdns not false")
env_ex = open(os.path.join(repo, ".env.example"), encoding="utf-8").read() if os.path.isfile(os.path.join(repo, ".env.example")) else ""
for key in ("DO_NOT_TRACK=1", "OTEL_SDK_DISABLED=true"):
    if key not in env_ex:
        tel_issues.append(f".env.example missing {key}")
common_body = open(os.path.join(repo, "lib/common.sh"), encoding="utf-8").read()
if "oc_telemetry_off()" not in common_body or "OTEL_SDK_DISABLED" not in common_body:
    tel_issues.append("lib/common.sh oc_telemetry_off incomplete")
for rel in ("opencode.sh", "run.sh", "launch-desktop.sh", "serve-desktop.sh"):
    body = open(os.path.join(repo, rel), encoding="utf-8").read()
    if "oc_telemetry_off" not in body:
        tel_issues.append(f"{rel} missing oc_telemetry_off")
if tel_issues:
    err("telemetry not fully disabled: " + "; ".join(tel_issues))
else:
    ok("telemetry off (OpenCode share/OTel · OTEL_SDK)")

versions_cfg = os.path.join(repo, "versions.json")
if os.path.isfile(versions_cfg):
    try:
        vdata = json.load(open(versions_cfg))
        if vdata.get("product") != "OpenConfig":
            err(f"versions.json product={vdata.get('product')!r} — expected 'OpenConfig'")
        elif vdata.get("cli") != "oc":
            err(f"versions.json cli={vdata.get('cli')!r} — expected 'oc'")
        else:
            ok("versions.json product=OpenConfig cli=oc")
    except Exception:
        pass

# ---- 4c10. Project identity signature ----
v_ver = ""
try:
    v_ver = str((json.load(open(os.path.join(repo, "versions.json"), encoding="utf-8")).get("opencode_configs") or "")).strip()
except Exception:
    v_ver = ""
sig_path = os.path.join(repo, "signature.json")
sig_sh = os.path.join(repo, "signature.sh")
if not os.path.isfile(sig_path):
    err("signature.json missing — cannot prove this is OpenConfig")
elif not os.path.isfile(sig_sh):
    err("signature.sh missing")
else:
    try:
        sig = json.load(open(sig_path, encoding="utf-8"))
        if sig.get("product") != "OpenConfig" or sig.get("cli") != "oc":
            err(f"signature.json product/cli = {sig.get('product')!r}/{sig.get('cli')!r}")
        elif sig.get("id") != "jesseoue/opencode-configs":
            err(f"signature.json id={sig.get('id')!r} — expected jesseoue/opencode-configs")
        elif not (sig.get("fingerprint") or "").strip():
            err("signature.json fingerprint empty — run: oc signature --refresh")
        elif v_ver and str(sig.get("version") or "").strip() != v_ver:
            err(f"signature.json version={sig.get('version')!r} ≠ versions.json {v_ver!r}")
        else:
            import subprocess
            r = subprocess.run(
                [sig_sh, "--json"],
                capture_output=True, text=True, cwd=repo,
            )
            try:
                payload = json.loads(r.stdout or "{}")
            except Exception:
                payload = {}
            if r.returncode == 0 and payload.get("ok"):
                ok(f"signature ok ({payload.get('id')}, {payload.get('fingerprint_prefix')}…)")
            else:
                reason = payload.get("error") or (r.stderr or r.stdout or f"exit {r.returncode}").strip()
                err(f"signature verify failed: {reason}")
    except Exception as e:
        err(f"signature.json: {e}")

# ---- 5. agent markdown frontmatter sanity ----
for md in sorted(glob.glob(os.path.join(repo, "agents", "*.md"))):
    txt = open(md).read()
    rel = os.path.relpath(md, repo)
    if not txt.startswith("---"):
        warn(f"{rel}: no YAML frontmatter")
        continue
    fm = txt.split("---", 2)
    if len(fm) < 3:
        err(f"{rel}: unterminated frontmatter block")
    else:
        ok(f"frontmatter present: {rel}")

# ---- report ----
color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
G = "\033[32m" if color else ""; Y = "\033[33m" if color else ""
R = "\033[31m" if color else ""; C = "\033[36m" if color else ""
B = "\033[1m" if color else ""; Z = "\033[0m" if color else ""
q = os.environ.get("VALIDATE_QUIET") == "1"
if not q:
    for m in oks: print(f"  {G}✓{Z} {m}")
for m in warns: print(f"  {Y}⚠{Z} {m}")
for m in errors: print(f"  {R}✗{Z} {m}")
print()
if not q:
    print(f"  {C}{B}── summary ──{Z}")
print(f"  {len(oks)} ok · {len(warns)} warnings · {len(errors)} errors")
sys.exit(1 if errors else 0)
PY
