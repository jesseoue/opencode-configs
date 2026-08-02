#!/usr/bin/env bash
# validate.sh — Validate every OpenCode config in this repo.
# Checks JSON syntax, cross-file model references, and the known
# runtime footguns that pass JSON-schema but silently break at runtime.
# Exit 0 = clean, 1 = errors found. Safe to run anytime.
#
# Usage:
#   ./validate.sh           full report
#   ./validate.sh --quiet   summary only (exit code still set)

set -euo pipefail

REPO="${OC_VALIDATE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
QUIET=""
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET="--quiet" ;;
    -h|--help) oc_print_script_help "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg (try --quiet)"; exit 2 ;;
  esac
done

[[ "$QUIET" == "--quiet" ]] && export VALIDATE_QUIET=1

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
              os.path.join(repo, "oh-my-openagent.json"),
              os.path.join(repo, "tui.json")]
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
omo_path = os.path.join(repo, "oh-my-openagent.json")
oc = parsed.get(oc_path)
omo = parsed.get(omo_path)

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
    for timeout_key, expected in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 60000)):
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
    elif hdrs.get("X-Title") != "OpenConfig":
        err("opencode.json: openrouter.headers.X-Title must be OpenConfig")
    else:
        ok("openrouter attribution headers aligned with signature")
    direct_opts = ((oc.get("provider") or {}).get("openai") or {}).get("options") or {}
    enabled_providers = oc.get("enabled_providers")
    openai_enabled = isinstance(enabled_providers, list) and "openai" in enabled_providers
    if openai_enabled:
        for timeout_key, expected in (("timeout", 300000), ("headerTimeout", 300000), ("chunkTimeout", 60000)):
            if direct_opts.get(timeout_key) != expected:
                err(f"opencode.json: provider.openai.options.{timeout_key} must be {expected}.")
    elif (oc.get("provider") or {}).get("openai"):
        err("opencode.json: provider.openai present but direct OpenAI disabled — remove block (OpenRouter-only).")
    else:
        ok("direct OpenAI provider absent (OpenRouter-only)")
    tool_output = oc.get("tool_output") or {}
    if tool_output.get("max_lines") != 300 or tool_output.get("max_bytes") != 12000:
        err("opencode.json: tool_output must be 300 lines / 12000 bytes.")
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
        if fam == "deepseek":
            if pv.get("only") != ["deepseek"]:
                err(f"opencode.json[{mid}]: deepseek must pin provider.only=['deepseek'] (first-party; no proxy moderation). Run: oc fix")
            if pv.get("require_parameters") is not False:
                err(f"opencode.json[{mid}]: deepseek provider.require_parameters must be false. Run: oc fix")
        elif pv.get("require_parameters") is not expected_require_parameters:
            err(
                f"opencode.json[{mid}]: provider.require_parameters must be "
                f"{str(expected_require_parameters).lower()} for {fam} routing."
            )
        # Exacto: OpenRouter docs say append :exacto to the slug (quality-first tool routing).
        # Do NOT also set sort to price/throughput/latency — that overrides Exacto.
        # Soft preferred_* / tight quant filters fight Exacto's provider ranking.
        api_id = m.get("id") or mid
        is_exacto = api_id.endswith(":exacto") or pv.get("sort") == "exacto" or mid.endswith("-exacto") or mid.endswith(":exacto")
        is_nitro = api_id.endswith(":nitro") or pv.get("sort") == "throughput" or mid.endswith("-nitro") or mid.endswith(":nitro")
        is_floor = api_id.endswith(":floor") or pv.get("sort") == "price" or mid.endswith("-floor") or mid.endswith(":floor")
        if sum((is_exacto, is_nitro, is_floor)) > 1:
            err(f"opencode.json[{mid}]: cannot combine Exacto, Nitro, and Floor routing modes.")
        if is_exacto:
            if not str(api_id).endswith(":exacto"):
                err(f"opencode.json[{mid}]: Exacto models must use id ending in ':exacto' (got '{api_id}'). See https://openrouter.ai/docs/guides/routing/model-variants/exacto")
            sort = pv.get("sort")
            if sort in ("price", "throughput", "latency"):
                err(f"opencode.json[{mid}]: provider.sort={sort!r} overrides Exacto — remove sort (the :exacto suffix already sets quality-first routing).")
            if sort == "exacto":
                warn(f"opencode.json[{mid}]: provider.sort='exacto' is redundant with id ':exacto' — drop sort.")
            if pv.get("order"):
                err(f"opencode.json[{mid}]: provider.order overrides Exacto quality ranking — remove order.")
            if pv.get("ignore"):
                err(f"opencode.json[{mid}]: provider.ignore narrows Exacto fallback coverage — remove it.")
            if "preferred_min_throughput" in pv or "preferred_max_latency" in pv:
                err(f"opencode.json[{mid}]: Exacto + preferred_min_throughput/preferred_max_latency fights quality ranking — remove soft prefs.")
            if q is not None:
                warn(f"opencode.json[{mid}]: Exacto + quantizations filter may drop quality Exacto providers — prefer ignore/max_price only.")
        if is_nitro:
            if not str(api_id).endswith(":nitro") and pv.get("sort") != "throughput":
                err(f"opencode.json[{mid}]: Nitro/speed models should use id ending in ':nitro' (got '{api_id}'). See https://openrouter.ai/docs/guides/routing/provider-selection")
            sort = pv.get("sort")
            if sort in ("price", "latency", "exacto"):
                err(f"opencode.json[{mid}]: provider.sort={sort!r} fights Nitro throughput routing — remove sort (or use :nitro only).")
            if sort == "throughput":
                warn(f"opencode.json[{mid}]: provider.sort='throughput' is redundant with id ':nitro' — drop sort.")
            if pv.get("order"):
                err(f"opencode.json[{mid}]: provider.order overrides Nitro throughput ranking — remove order.")
            if pv.get("ignore"):
                err(f"opencode.json[{mid}]: provider.ignore narrows Nitro fallback coverage — remove it.")
            if "preferred_min_throughput" in pv or "preferred_max_latency" in pv:
                err(f"opencode.json[{mid}]: Nitro + preferred_* fights native :nitro throughput ranking — remove (run: oc fix)")
        if is_floor:
            if not str(api_id).endswith(":floor") and pv.get("sort") != "price":
                err(f"opencode.json[{mid}]: cost routes must use id ending in ':floor' (got '{api_id}').")
            if pv.get("order"):
                err(f"opencode.json[{mid}]: provider.order overrides Floor price ranking — remove order.")
            if pv.get("ignore"):
                err(f"opencode.json[{mid}]: provider.ignore narrows Floor fallback coverage — remove it.")
            if "preferred_min_throughput" in pv or "preferred_max_latency" in pv:
                err(f"opencode.json[{mid}]: Floor + preferred_* fights native :floor price ranking — remove (run: oc fix)")
        if not is_exacto and not is_nitro and not is_floor:
            if "preferred_min_throughput" in pv or "preferred_max_latency" in pv:
                err(f"opencode.json[{mid}]: preferred_* on auto-routed models fights OpenRouter adaptive ranking — remove (run: oc fix)")
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

    # Team tools + core OpenCode tools must be allow (trusted local box)
    TEAM_TOOLS = (
        "team_create", "team_delete", "team_list", "team_status", "team_send_message",
        "team_shutdown_request", "team_approve_shutdown", "team_reject_shutdown",
        "team_task_create", "team_task_get", "team_task_list", "team_task_update",
    )
    missing_team = [t for t in TEAM_TOOLS if perm.get(t) != "allow"]
    if missing_team:
        err(f"team_* tools not allow: {missing_team} — run: oc fix")
    else:
        ok(f"{len(TEAM_TOOLS)} team_* tools allowed")
    for t in ("task", "edit", "external_directory", "doom_loop", "question", "call_omo_agent"):
        if perm.get(t) != "allow":
            err(f"permission.{t} must be allow (got {perm.get(t)!r})")
    bash = perm.get("bash")
    if not (isinstance(bash, dict) and bash.get("*") == "allow"):
        err("permission.bash['*'] must be allow (allow-everything mode)")
    else:
        ok("core tools + bash allow-everything (catastrophic denies kept)")
    if not oc.get("enabled_providers"):
        warn("opencode.json: enabled_providers not set — all providers with credentials will load.")
    plug = oc.get("plugin", [])
    if not any("oh-my-opencode" in p or "oh-my-openagent" in p for p in plug):
        warn("opencode.json: oh-my-openagent plugin not pinned in the plugin array.")

# ---- 2b. tui.json plugin pin must match opencode.json ----
tui_path = os.path.join(repo, "tui.json")
if oc and os.path.isfile(tui_path):
    try:
        tui = json.load(open(tui_path))
        oc_pins = [p for p in (oc.get("plugin") or []) if isinstance(p, str) and "oh-my-" in p]
        tui_pins = [p for p in (tui.get("plugin") or []) if isinstance(p, str) and "oh-my-" in p]
        if oc_pins and tui_pins and set(oc_pins) != set(tui_pins):
            err(f"tui.json plugin pin {tui_pins} != opencode.json {oc_pins} — bump both together")
        elif oc_pins and tui_pins:
            ok(f"tui.json plugin pin matches opencode.json ({oc_pins[0]})")
        elif oc_pins and not tui_pins:
            warn("tui.json has no oh-my-* plugin pin (opencode.json does)")
    except Exception as e:
        err(f"tui.json: failed to parse for plugin pin check: {e}")

# ---- 3. oh-my-openagent.json footguns + cross-file refs ----
if omo:
    # Schema URL must resolve (upstream asset basename is still oh-my-opencode.schema.json)
    schema = omo.get("$schema") or ""
    if not schema:
        err("oh-my-openagent.json: missing $schema")
    elif "oh-my-openagent.schema.json" in schema:
        err(
            "oh-my-openagent.json: $schema uses oh-my-openagent.schema.json which 404s upstream — "
            "use assets/oh-my-opencode.schema.json (legacy asset basename; plugin package name stays oh-my-openagent)"
        )
    elif "oh-my-opencode.schema.json" not in schema:
        warn(f"oh-my-openagent.json: unexpected $schema URL: {schema}")
    elif os.environ.get("OC_VALIDATE_OFFLINE") == "1":
        ok("$schema URL shape valid (reachability skipped by OC_VALIDATE_OFFLINE)")
    else:
        try:
            import urllib.request
            req = urllib.request.Request(schema, method="HEAD")
            with urllib.request.urlopen(req, timeout=8) as resp:
                code = getattr(resp, "status", 200)
            if int(code) >= 400:
                err(f"oh-my-openagent.json: $schema URL returned HTTP {code}: {schema}")
            else:
                ok("$schema URL reachable (oh-my-opencode.schema.json asset)")
        except Exception as e:
            warn(f"oh-my-openagent.json: could not HEAD $schema ({e}) — skipped reachability check")

    hexre = re.compile(r"^#[0-9A-Fa-f]{6}$")
    agents = omo.get("agents", {})
    disabled_agents = {str(a).lower() for a in (omo.get("disabled_agents") or [])}
    for n, a in agents.items():
        c = a.get("color")
        if c is not None and not hexre.match(str(c)):
            err(f"oh-my-openagent.json[{n}]: color '{c}' is not hex #RRGGBB — the ENTIRE agents section will be dropped at runtime.")
        if isinstance(a, dict) and "reasoningEffort" in a:
            err(f"oh-my-openagent.json agents.{n}: reasoningEffort deprecated on OmO 4.19.4 — use reasoning (run: oc fix)")
        for bad in ("hidden", "steps", "providerOptions"):
            if bad in a:
                warn(f"oh-my-openagent.json[{n}]: key '{bad}' is not in the plugin agent schema (stripped/ignored).")
    if agents:
        ok(f"{len(agents)} plugin agents, all colors valid")

    # Sisyphus is the only supported default/team lead in this pinned stack.
    default_agent = (oc or {}).get("default_agent")
    if default_agent != "sisyphus":
        err(f"opencode.json: default_agent must be 'sisyphus' (got {default_agent!r})")
    if omo.get("default_run_agent") != "sisyphus":
        err(f"oh-my-openagent.json: default_run_agent must be 'sisyphus' (got {omo.get('default_run_agent')!r})")
    order = omo.get("agent_order") or []
    if not isinstance(order, list) or not order or order[0] != "sisyphus":
        err("oh-my-openagent.json: agent_order must start with 'sisyphus'")
    elif not all(isinstance(name, str) and name for name in order):
        err("oh-my-openagent.json: agent_order entries must be non-empty strings")
    elif len(order) != len(set(order)):
        err("oh-my-openagent.json: agent_order contains duplicate agents")
    elif any(name not in agents for name in order):
        err(f"oh-my-openagent.json: agent_order references undeclared agents: {sorted(set(order) - set(agents))}")
    else:
        ok("Sisyphus is first in agent_order and all ordered agents resolve")
    sis = agents.get("sisyphus")
    if not isinstance(sis, dict):
        err("oh-my-openagent.json: agents.sisyphus missing")
    elif sis.get("mode") != "primary":
        err("oh-my-openagent.json: agents.sisyphus.mode must be 'primary'")
    elif "sisyphus" in disabled_agents:
        err("oh-my-openagent.json: sisyphus must not appear in disabled_agents")
    else:
        ok("Sisyphus declared primary and enabled")
    if isinstance(sis, dict):
        sm = sis.get("model") or ""
        if sm and not str(sm).startswith("openrouter/"):
            err(f"oh-my-openagent.json: agents.sisyphus.model must be openrouter/* (got {sm!r})")
        for fb in sis.get("fallback_models") or []:
            fbm = fb if isinstance(fb, str) else (fb.get("model") if isinstance(fb, dict) else "")
            if fbm and not str(fbm).startswith("openrouter/"):
                err(f"oh-my-openagent.json: agents.sisyphus fallback must be openrouter/* (got {fbm!r})")
        uw = sis.get("ultrawork") or {}
        uwm = uw.get("model") if isinstance(uw, dict) else None
        if uwm and not str(uwm).startswith("openrouter/"):
            err(f"oh-my-openagent.json: agents.sisyphus.ultrawork.model must be openrouter/* (got {uwm!r})")
        elif sm:
            ok("Sisyphus routes OpenRouter-only (primary + fallbacks + ultrawork)")
    sa = omo.get("sisyphus_agent") or {}
    if sa.get("disabled") is True:
        err("oh-my-openagent.json: sisyphus_agent.disabled must be false")
    else:
        ok("sisyphus_agent enabled")
    omo_jsonc = os.path.expanduser("~/.omo/omo.jsonc")
    if os.path.isfile(omo_jsonc):
        with open(omo_jsonc, encoding="utf-8") as f:
            ojc = f.read()
        if '"[opencode]"' in ojc and re.search(r'"models"\s*:\s*\[', ojc):
            err(
                "~/.omo/omo.jsonc has invalid migrated agents.models — breaks Sisyphus. "
                "Run: oc fix (OpenConfig canonical source is oh-my-openagent.json)"
            )
    else:
        ok("~/.omo/omo.jsonc absent (oh-my-openagent.json is canonical)")

    # OmO injects security-* via a loopback skills.urls server; OpenCode can
    # deadlock fetching that index during `opencode run` bootstrap. Keep them disabled.
    disabled_skills = {str(s).lower() for s in (omo.get("disabled_skills") or [])}
    if not {"security-research", "security-review"} <= disabled_skills:
        err(
            "oh-my-openagent.json: disable security-research and security-review "
            "(OmO runtime skills.urls self-fetch can hang headless `opencode run`)."
        )
    else:
        ok("disabled_skills blocks OmO runtime skills.urls hang")

    # Local skills that replace OmO security-* (fenced under skills/)
    for skill_name in ("content-aware-recon", "content-aware-audit"):
        skill_md = os.path.join(repo, "skills", skill_name, "SKILL.md")
        if not os.path.isfile(skill_md):
            err(
                f"skills/{skill_name}/SKILL.md missing "
                "(replaces disabled OmO security-* skills)"
            )
        else:
            head = open(skill_md, encoding="utf-8").read(2000)
            if f"name: {skill_name}" not in head and f'name: "{skill_name}"' not in head:
                warn(f"skills/{skill_name}/SKILL.md should set frontmatter name: {skill_name}")
            else:
                ok(f"local skill {skill_name}")

    # CodeGraph: must stay enabled; install_dir must not point at the broken cache path
    # (OmO does not expand ~ in provisionedBinFromInstallDir — default ~/.omo/codegraph).
    cg = omo.get("codegraph") or {}
    if cg.get("enabled") is False:
        err("oh-my-openagent.json: codegraph.enabled is false")
    elif cg.get("auto_provision") is not True:
        err("oh-my-openagent.json: codegraph.auto_provision must be true (keeps OmO's pinned runtime current)")
    elif cg.get("daemon") is not True:
        err("oh-my-openagent.json: codegraph.daemon must be true (OmO 4.19.4 managed-daemon default)")
    else:
        idir = cg.get("install_dir")
        if idir and "cache/opencode/codegraph" in str(idir):
            err(
                f"oh-my-openagent.json: codegraph.install_dir={idir!r} is wrong — "
                "omit install_dir (OmO default ~/.omo/codegraph) or use an absolute path that exists."
            )
        else:
            ok("codegraph enabled (default ~/.omo/codegraph)")

    # Fallback lists must not repeat the primary model (wastes a slot).
    def _check_fallbacks(kind, name, primary, fallbacks):
        if not primary or not isinstance(fallbacks, list):
            return
        if len(fallbacks) > 3:
            err(f"oh-my-openagent.json[{kind}.{name}]: fallback_models exceeds three attempts")
        primary_l = str(primary).lower()
        for fb in fallbacks:
            if str(fb).lower() == primary_l:
                err(f"oh-my-openagent.json[{kind}.{name}]: fallback_models repeats primary {primary}")
                return
        lows = [str(x).lower() for x in fallbacks]
        if len(lows) != len(set(lows)):
            warn(f"oh-my-openagent.json[{kind}.{name}]: fallback_models has duplicate entries")

    for n, a in (omo.get("agents") or {}).items():
        _check_fallbacks("agents", n, a.get("model"), a.get("fallback_models"))
    for n, c in (omo.get("categories") or {}).items():
        if isinstance(c, dict) and "reasoningEffort" in c:
            err(f"oh-my-openagent.json categories.{n}: reasoningEffort deprecated on OmO 4.19.4 — use reasoning (run: oc fix)")
        _check_fallbacks("categories", n, c.get("model") if isinstance(c, dict) else None, (c.get("fallback_models") if isinstance(c, dict) else None))
    ok("agent/category fallback lists have no primary duplicates")

    # Fast/recon routes must not fall back to slow/premium models (availability + latency).
    SLOW_IN_FAST = ("kimi-k3", "claude-opus", "claude-fable", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-sol-pro")
    FAST_ROUTES = {"librarian", "explore", "sisyphus-junior", "quick", "unspecified-low", "content-aware-fast"}
    RECON_ROUTES = FAST_ROUTES | {"content-aware-deep", "content-aware-research", "deep", "arch-review", "metis", "multimodal-looker"}
    MODERATED_MARKERS = ("anthropic/claude", "openai/gpt", "meta-llama/", "cohere/")
    slow_fb_ok = True
    mod_recon_ok = True
    for n in FAST_ROUTES:
        cfg = (agents or {}).get(n) or (omo.get("categories") or {}).get(n)
        if not isinstance(cfg, dict):
            continue
        for fb in cfg.get("fallback_models") or []:
            low = str(fb).lower()
            if any(s in low for s in SLOW_IN_FAST):
                slow_fb_ok = False
                err(f"oh-my-openagent.json: slow model {fb!r} in fast route '{n}' fallbacks — use Flash/Nitro/Exacto/MiniMax")
    for n in RECON_ROUTES:
        cfg = (agents or {}).get(n) or (omo.get("categories") or {}).get(n)
        if not isinstance(cfg, dict):
            continue
        for slot, model_ref in (("model", cfg.get("model")),):
            if not model_ref:
                continue
            low = str(model_ref).lower()
            if any(m in low for m in MODERATED_MARKERS):
                mod_recon_ok = False
                err(f"oh-my-openagent.json: moderated primary {model_ref!r} on recon route '{n}' — use DeepSeek/GLM/MiniMax/Gemini")
        for fb in cfg.get("fallback_models") or []:
            low = str(fb).lower()
            if any(m in low for m in MODERATED_MARKERS):
                mod_recon_ok = False
                err(f"oh-my-openagent.json: moderated fallback {fb!r} on recon route '{n}' — use DeepSeek/GLM/MiniMax/Gemini")
    for section, items in (("agents", agents or {}), ("categories", omo.get("categories") or {})):
        for n, cfg in items.items():
            if not isinstance(cfg, dict):
                continue
            for fb in cfg.get("fallback_models") or []:
                if "kimi-k3" in str(fb).lower():
                    slow_fb_ok = False
                    err(f"oh-my-openagent.json[{section}.{n}]: kimi-k3 in fallback_models — whitelist-only (slow, single-provider)")
    if slow_fb_ok:
        ok("fast routes avoid slow/premium fallbacks; kimi-k3 not in routine chains")
    if mod_recon_ok:
        ok("recon routes use unmoderated primaries and fallbacks (DeepSeek/GLM/MiniMax/Gemini)")

    kd = omo.get("keyword_detector", {})
    allowed = {"ultrawork", "team", "hyperplan", "hyperplan-ultrawork"}
    expansions = set(kd.get("enabled_expansions", []) or [])
    for v in expansions:
        if v not in allowed:
            err(f"oh-my-openagent.json: keyword_detector.enabled_expansions has invalid value '{v}' — the section drops and ALL expansions fire. Allowed: {sorted(allowed)}.")

    # hyperplan prerequisites (OmO skill: team + 4 required categories + demoted plan handoff)
    tm = omo.get("team_mode") or {}
    cats = omo.get("categories") or {}
    for cname, category in cats.items():
        cap = category.get("maxTokens") if isinstance(category, dict) else None
        if not isinstance(cap, int) or cap < 1 or cap > 32768:
            err(f"category {cname!r}: maxTokens must be an explicit 1–32768 cost ceiling (got {cap!r}).")
    sa = omo.get("sisyphus_agent") or {}
    hp_on = "hyperplan" in expansions
    if hp_on:
        if tm.get("enabled") is not True:
            err("hyperplan enabled but team_mode.enabled is not true — hyperplan requires team_* tools.")
        for req in ("unspecified-low", "unspecified-high", "ultrabrain", "artistry"):
            if req not in cats:
                err(f"hyperplan requires category '{req}' (adversarial roster).")
        if "deep" not in cats:
            warn("hyperplan: category 'deep' missing — roster will run 4 members (researcher dropped).")
        if "plan" in disabled_agents:
            err("hyperplan Phase 6 handoff needs task(subagent_type=\"plan\") — remove 'plan' from disabled_agents (OmO demotes it when replace_plan is true).")
        if sa.get("planner_enabled") is False:
            err("hyperplan needs sisyphus_agent.planner_enabled (plan/prometheus planner family).")
        if sa.get("replace_plan") is False:
            warn("sisyphus_agent.replace_plan is false — plan stays a primary tab agent; hyperplan still works but tab UX differs.")
        if "hyperplan-ultrawork" not in expansions and "ultrawork" in expansions:
            warn("enabled_expansions has hyperplan+ultrawork but not hyperplan-ultrawork — combo keyword won't fire (allowlist).")
        max_members = tm.get("max_members")
        if isinstance(max_members, int) and max_members < 5:
            err(f"team_mode.max_members={max_members} < 5 — hyperplan needs 5 category members.")
        ok("hyperplan prerequisites OK (team + categories + plan handoff)")

    # ---- concurrency ceilings (match fix.sh / doctor) ----
    bt = omo.get("background_task") or {}
    pc = bt.get("providerConcurrency") or {}
    dc = bt.get("defaultConcurrency")
    if not isinstance(dc, int) or dc < 1 or dc > 6:
        err(f"background_task.defaultConcurrency must be 1–6 (got {dc!r})")
    elif dc != 6:
        err(f"background_task.defaultConcurrency must be 6 (got {dc!r}) — run: oc fix")
    else:
        ok(f"background_task.defaultConcurrency={dc}")
    for prov, cap in (("openrouter", 8),):
        v = pc.get(prov)
        if not isinstance(v, int) or v < 1 or v > cap:
            err(f"providerConcurrency.{prov} must be 1–{cap} (got {v!r})")
        elif v != cap:
            err(f"providerConcurrency.{prov} must be {cap} (got {v!r}) — run: oc fix")
        else:
            ok(f"providerConcurrency.{prov}={v}")
    extra_pc = sorted(k for k in pc if k != "openrouter")
    if extra_pc:
        err(f"providerConcurrency must be OpenRouter-only — remove: {extra_pc} (run: oc fix)")
    wl = ((oc.get("provider") or {}).get("openrouter") or {}).get("whitelist") or []
    gpt_wl = [w for w in wl if isinstance(w, str) and "gpt" in w.lower()]
    if gpt_wl:
        err(f"openrouter whitelist must not include GPT models: {gpt_wl} — run: oc fix")
    else:
        ok("openrouter whitelist has no GPT models")
    gpt_routes = []
    for section in ("agents", "categories"):
        for n, cfg in (omo.get(section) or {}).items():
            if not isinstance(cfg, dict):
                continue
            for ref in [cfg.get("model")] + list(cfg.get("fallback_models") or []):
                r = ref if isinstance(ref, str) else (ref.get("model") if isinstance(ref, dict) else "")
                if r and "gpt" in str(r).lower():
                    gpt_routes.append(f"{section}.{n}:{r}")
    if gpt_routes:
        err(f"GPT models in active routes (OpenRouter-only stack): {gpt_routes[:5]} — run: oc fix")
    else:
        ok("no GPT models in agent/category routes")
    if not isinstance(bt.get("maxToolCalls"), int) or bt.get("maxToolCalls") > 200:
        err(f"background_task.maxToolCalls must be ≤200 (got {bt.get('maxToolCalls')!r})")
    circuit = bt.get("circuitBreaker") or {}
    if not isinstance(circuit.get("maxToolCalls"), int) or circuit.get("maxToolCalls") > 160:
        err(f"background_task.circuitBreaker.maxToolCalls must be ≤160 (got {circuit.get('maxToolCalls')!r})")
    mp = tm.get("max_parallel_members")
    if isinstance(mp, int) and (mp < 1 or mp > 4):
        err(f"team_mode.max_parallel_members={mp} — want 1–4")
    elif isinstance(mp, int):
        ok(f"team_mode.max_parallel_members={mp}")
    # Full OmO 4.19 team_mode schema — pin required keys (Zod defaults alone hide drift)
    for k in (
        "tmux_visualization", "max_messages_per_run", "max_wall_clock_minutes",
        "max_member_turns", "message_payload_max_bytes", "recipient_unread_max_bytes",
        "mailbox_poll_interval_ms", "base_dir",
    ):
        if k not in tm:
            err(f"team_mode.{k} missing — run: oc fix")
    for key, expected in (("max_messages_per_run", 2000), ("max_wall_clock_minutes", 45), ("max_member_turns", 150)):
        if tm.get(key) != expected:
            err(f"team_mode.{key} must be {expected} (got {tm.get(key)!r})")
    if tm.get("enabled") is not True:
        err("team_mode.enabled must be true")
    if not isinstance(tm.get("tmux_visualization"), bool):
        err("team_mode.tmux_visualization must be a boolean")
    poll = tm.get("mailbox_poll_interval_ms")
    if not isinstance(poll, int) or poll < 500:
        err(f"team_mode.mailbox_poll_interval_ms={poll!r} — OmO minimum 500")
    else:
        ok(f"team_mode.mailbox_poll_interval_ms={poll}")
    base = tm.get("base_dir") or "~/.omo"
    if not isinstance(base, str) or not base:
        err("team_mode.base_dir must be a non-empty string (want ~/.omo)")
    else:
        ok(f"team_mode.base_dir={base}")
    runtime_fallback = omo.get("runtime_fallback") or {}
    if runtime_fallback.get("retry_on_errors") != [408, 429, 500, 502, 503, 504]:
        err("runtime_fallback.retry_on_errors must contain transient HTTP failures only.")
    if runtime_fallback.get("max_fallback_attempts") != 3:
        err("runtime_fallback.max_fallback_attempts must be 3.")
    if runtime_fallback.get("timeout_seconds") != 120:
        err("runtime_fallback.timeout_seconds must be 120.")
    omo_experimental = omo.get("experimental") or {}
    if omo_experimental.get("aggressive_truncation") is not False or omo_experimental.get("truncate_all_tool_outputs") is not False:
        err("OmO blanket tool-output truncation must stay disabled; use dynamic_context_pruning.")
    tx = omo.get("tmux") or {}
    if tx.get("enabled") is True and tx.get("layout") == "main-vertical" and tx.get("isolation") in ("inline", "window", "session"):
        ok(f"tmux team panes ready (layout={tx.get('layout')} isolation={tx.get('isolation')})")
    else:
        err("tmux must be enabled with layout=main-vertical for team mode — run: oc fix")
    # OmO 4.19: Goals replace Ralph — ralph_loop is deprecated/ignored when goal is explicit
    if "ralph_loop" in omo:
        warn("ralph_loop present — deprecated on OmO 4.19 (ignored; /ralph-loop removed) — run: oc fix")
    else:
        ok("no ralph_loop (OmO 4.19 Goal replaced Ralph)")
    goal = omo.get("goal") or {}
    dm = omo.get("default_mode") or {}
    goal_md = os.path.join(repo, "prompts", "goal.md")
    oc_instr = oc.get("instructions") or []
    # OmO 4.19.x: goal chat hook treats /start-work's ~5541-char template as setGoal → InvalidObjectiveError
    if goal.get("enabled") is True:
        err("goal.enabled=true breaks /start-work on OmO 4.19.x — set false (see prompts/goal.md)")
    else:
        ok("goal disabled (protects /start-work)")
    if goal.get("auto_start") is True:
        err("goal.auto_start=true — must be false (run: oc fix)")
    if dm.get("goal") is True:
        err("default_mode.goal=true — must be false while OmO goal hook is unsafe")
    elif isinstance(dm, dict) and dm.get("goal") is False:
        ok("default_mode.goal=false")
    if not os.path.isfile(goal_md):
        err("prompts/goal.md missing — documents OmO goal//start-work footgun")
    elif "prompts/goal.md" not in oc_instr:
        err("opencode.json instructions[] must include prompts/goal.md")
    else:
        ok("goal footgun documented (prompts/goal.md in instructions)")
    allow = list(omo.get("mcp_env_allowlist") or [])
    if allow:
        err(f"mcp_env_allowlist must be empty so imported MCP configs cannot access secrets: {allow}")
    else:
        ok("mcp_env_allowlist empty (imported MCPs receive no API keys)")
    if not isinstance(omo.get("start_work"), dict):
        warn("start_work block missing — run: oc fix")
    else:
        ok(f"start_work.auto_commit={omo['start_work'].get('auto_commit')}")
    # modelConcurrency should cover every referenced model id (openai/X ↔ openrouter/openai/X)
    mc = bt.get("modelConcurrency") or {}
    def _mc_aliases(mid):
        out = {mid}
        if mid.startswith("openrouter/"):
            out.add(mid[len("openrouter/"):])
        elif mid.startswith("openai/"):
            out.add("openrouter/" + mid)
        elif "/" in mid:
            out.add("openrouter/" + mid)
        return out
    ref_ids = set()
    for section in ("agents", "categories"):
        for cfg in (omo.get(section) or {}).values():
            if not isinstance(cfg, dict):
                continue
            if isinstance(cfg.get("model"), str):
                ref_ids.add(cfg["model"])
            for fb in cfg.get("fallback_models") or []:
                if isinstance(fb, str):
                    ref_ids.add(fb)
    mc_keys = set(mc)
    miss_mc = sorted(i for i in ref_ids if not (_mc_aliases(i) & mc_keys))
    if miss_mc:
        warn(f"modelConcurrency missing {len(miss_mc)} model(s): {', '.join(miss_mc[:5])}"
             + ("…" if len(miss_mc) > 5 else ""))
    elif ref_ids:
        ok(f"modelConcurrency covers {len(ref_ids)} referenced models")

    # team specs (~/.omo/teams via repo teams/) — OmO hard-rejects read-only agents as members
    # https://omo.vibetip.help/docs + docs/guide/team-mode.md
    TEAM_ELIGIBLE = {"sisyphus", "atlas", "sisyphus-junior"}
    TEAM_CONDITIONAL = {"hephaestus"}  # needs agents.hephaestus.permission.teammate == allow
    TEAM_HARD_REJECT = {
        "oracle", "librarian", "explore", "multimodal-looker",
        "metis", "momus", "prometheus", "plan",
    }
    TEAM_KEYS = {"version", "name", "description", "lead", "members"}
    LEAD_KEYS = {"kind", "subagent_type", "category", "prompt"}
    MEMBER_KEYS = {"kind", "subagent_type", "category", "name", "prompt"}
    DEPENDENCY_GATES = {
        "debug-team": {"root-cause": "reproducer"},
        "refactor-team": {"executor": "analyzer"},
        "content-aware-audit": {"deep": "recon"},
        "ship-feature": {"verifier": "forge"},
    }
    NAME_RE = re.compile(r"^[a-z0-9-]+$")
    team_cfgs = sorted(glob.glob(os.path.join(repo, "teams", "*", "config.json")))
    if not team_cfgs:
        warn("no teams/*/config.json found")
    else:
        hep_perm = ((agents.get("hephaestus") or {}).get("permission") or {}).get("teammate")
        for cfg_path in team_cfgs:
            rel = os.path.relpath(cfg_path, repo)
            try:
                team = load(cfg_path)
            except Exception as e:
                err(f"{rel}: invalid JSON ({e})")
                continue
            unknown = sorted(set(team) - TEAM_KEYS)
            if unknown:
                err(f"{rel}: unknown top-level keys: {unknown}")
            if team.get("version") != 1:
                err(f"{rel}: version must be 1 (got {team.get('version')!r})")
            if not isinstance(team.get("description"), str) or not team.get("description", "").strip():
                err(f"{rel}: description must be a non-empty string")
            tname = team.get("name") or ""
            dirname = os.path.basename(os.path.dirname(cfg_path))
            if tname != dirname:
                err(f"{rel}: name '{tname}' must match directory '{dirname}'")
            if tname and not NAME_RE.match(tname):
                err(f"{rel}: name must match ^[a-z0-9-]+$")
            lead = team.get("lead") or {}
            if lead:
                lead_unknown = sorted(set(lead) - LEAD_KEYS)
                if lead_unknown:
                    err(f"{rel}: lead has unknown keys: {lead_unknown}")
                lk = lead.get("kind")
                if lk == "subagent_type":
                    lst = lead.get("subagent_type")
                    if lst in TEAM_HARD_REJECT:
                        err(f"{rel}: lead subagent_type '{lst}' is hard-rejected for team mode")
                    elif lst not in TEAM_ELIGIBLE and lst not in TEAM_CONDITIONAL:
                        err(f"{rel}: lead subagent_type '{lst}' is not team-eligible (use sisyphus/atlas/sisyphus-junior/hephaestus)")
                    elif lst == "hephaestus" and hep_perm != "allow":
                        err(f"{rel}: lead hephaestus needs agents.hephaestus.permission.teammate=allow")
                    elif lst in disabled_agents:
                        err(f"{rel}: lead subagent_type '{lst}' is disabled")
                    elif lst not in agents:
                        err(f"{rel}: lead subagent_type '{lst}' is not declared in agents")
                elif lk == "category":
                    lcat = lead.get("category")
                    if not lcat or not lead.get("prompt"):
                        err(f"{rel}: lead kind=category requires category + prompt")
                    elif lcat not in cats:
                        err(f"{rel}: lead category '{lcat}' is not declared")
                else:
                    err(f"{rel}: lead.kind must be subagent_type or category")
            else:
                err(f"{rel}: lead must be a non-empty object")
            members = team.get("members") or []
            if not isinstance(members, list) or not (1 <= len(members) <= 8):
                err(f"{rel}: members must be an array of length 1..8 (got {len(members) if isinstance(members, list) else type(members).__name__})")
                continue
            seen_names = set()
            for i, m in enumerate(members):
                if not isinstance(m, dict):
                    err(f"{rel}: members[{i}] must be an object")
                    continue
                member_unknown = sorted(set(m) - MEMBER_KEYS)
                if member_unknown:
                    err(f"{rel}: members[{i}] has unknown keys: {member_unknown}")
                mname = m.get("name") or ""
                if not mname or not NAME_RE.match(mname):
                    err(f"{rel}: members[{i}].name must match ^[a-z0-9-]+$")
                elif mname in seen_names:
                    err(f"{rel}: duplicate member name '{mname}'")
                else:
                    seen_names.add(mname)
                kind = m.get("kind")
                prompt = (m.get("prompt") or "").strip()
                if not prompt:
                    err(f"{rel}: members[{i}] ({mname or i}) requires non-empty inline prompt")
                else:
                    clauses = {
                        "ROLE:": "ROLE:" in prompt,
                        "METHOD:/DELIVERABLE:": "METHOD:" in prompt or "DELIVERABLE:" in prompt,
                        "OWNERSHIP:": "OWNERSHIP:" in prompt,
                        "Mailbox": "mailbox" in prompt.lower(),
                        "VERIFY:": "VERIFY:" in prompt,
                        "SHUTDOWN:": "SHUTDOWN:" in prompt and "approval" in prompt.lower(),
                    }
                    missing_clauses = [name for name, present in clauses.items() if not present]
                    if missing_clauses:
                        err(
                            f"{rel}: members[{i}] ({mname}) prompt missing team contract clauses: "
                            f"{', '.join(missing_clauses)}"
                        )
                if kind == "category":
                    cat = m.get("category")
                    if not cat:
                        err(f"{rel}: members[{i}] kind=category missing category")
                    elif cat not in cats:
                        err(f"{rel}: members[{i}] unknown category '{cat}'")
                elif kind == "subagent_type":
                    st = m.get("subagent_type")
                    if st in TEAM_HARD_REJECT:
                        err(f"{rel}: members[{i}] subagent_type '{st}' is hard-rejected (cannot write team mailbox). Use kind=category or delegate-task.")
                    elif st in TEAM_CONDITIONAL:
                        if hep_perm != "allow":
                            err(f"{rel}: members[{i}] hephaestus needs agents.hephaestus.permission.teammate=allow")
                    elif st not in TEAM_ELIGIBLE:
                        err(f"{rel}: members[{i}] subagent_type '{st}' not team-eligible (sisyphus/atlas/sisyphus-junior/hephaestus)")
                    elif st in disabled_agents:
                        err(f"{rel}: members[{i}] subagent_type '{st}' is disabled")
                    elif st not in agents:
                        err(f"{rel}: members[{i}] subagent_type '{st}' is not declared in agents")
                else:
                    err(f"{rel}: members[{i}].kind must be category or subagent_type")

            # Dependency-gated phases must name their upstream owner explicitly.
            by_name = {m.get("name"): m for m in members if isinstance(m, dict)}
            for downstream, upstream in DEPENDENCY_GATES.get(tname, {}).items():
                prompt = str((by_name.get(downstream) or {}).get("prompt") or "")
                if "DEPENDENCY:" not in prompt or upstream not in prompt:
                    err(
                        f"{rel}: member '{downstream}' must include DEPENDENCY: naming upstream '{upstream}'"
                    )

            # Two editing members cannot claim the same explicit ownership scope.
            ownership = {}
            for m in members:
                if not isinstance(m, dict):
                    continue
                prompt = str(m.get("prompt") or "")
                low = prompt.lower()
                read_only = any(marker in low for marker in (
                    "read-only", "do not edit", "findings only", "proposals only",
                    "reproduce only", "plan only",
                ))
                match = re.search(r"OWNERSHIP:\s*([^.\n]+)", prompt, re.I)
                if read_only or not match:
                    continue
                scope = re.sub(r"\s+", " ", match.group(1).strip().lower())
                if scope in ownership:
                    err(
                        f"{rel}: overlapping edit ownership '{scope}' for "
                        f"'{ownership[scope]}' and '{m.get('name')}'"
                    )
                else:
                    ownership[scope] = m.get("name")
        ok(f"{len(team_cfgs)} team spec(s) checked against OmO eligibility and lifecycle rules")
        # Provisioned ~/.omo/teams entries must be symlinks into this repo
        base = (tm.get("base_dir") or "~/.omo")
        if isinstance(base, str) and base.startswith("~/"):
            base = os.path.join(os.path.expanduser("~"), base[2:])
        elif isinstance(base, str) and base == "~":
            base = os.path.expanduser("~")
        ldir = os.path.join(base, "teams") if isinstance(base, str) else ""
        if ldir and os.path.isdir(ldir):
            bad_links = []
            for cfg_path in team_cfgs:
                name = os.path.basename(os.path.dirname(cfg_path))
                link = os.path.join(ldir, name)
                want = os.path.realpath(os.path.dirname(cfg_path))
                if not os.path.lexists(link):
                    bad_links.append(f"{name} (missing — run oc setup)")
                elif not os.path.islink(link):
                    bad_links.append(f"{name} (directory copy — run oc setup)")
                elif os.path.realpath(link) != want:
                    bad_links.append(f"{name} (symlink drift — run oc setup)")
            if bad_links:
                err(f"~/.omo/teams provision drift: {', '.join(bad_links)}")
            else:
                ok(f"{len(team_cfgs)} team specs symlinked under {ldir}")

    # cross-file: every agent/category model + fallback resolves to a defined model
    if oc:
        def refs_of(d):
            out = []
            if d.get("model"): out.append(d["model"])
            for fm in d.get("fallback_models", []) or []:
                out.append(fm if isinstance(fm, str) else fm.get("model"))
            uw = d.get("ultrawork") or {}
            if isinstance(uw, dict) and uw.get("model"): out.append(uw["model"])
            return [r for r in out if r]
        unknown = set()
        disabled_provider_refs = set()
        enabled_providers = oc.get("enabled_providers")
        enabled_providers = set(enabled_providers) if isinstance(enabled_providers, list) else None
        for n, a in agents.items():
            for r in refs_of(a):
                if r not in defined_models: unknown.add(f"{n}->{r}")
                if enabled_providers is not None and r.split("/", 1)[0] not in enabled_providers:
                    disabled_provider_refs.add(f"{n}->{r}")
        for cn, cv in omo.get("categories", {}).items():
            for r in refs_of(cv):
                if r not in defined_models: unknown.add(f"category:{cn}->{r}")
                if enabled_providers is not None and r.split("/", 1)[0] not in enabled_providers:
                    disabled_provider_refs.add(f"category:{cn}->{r}")
        if unknown:
            err(f"oh-my-openagent.json: model references not defined in opencode.json: {sorted(unknown)}")
        else:
            ok("all agent/category model references resolve to opencode.json models")
        if disabled_provider_refs:
            err(f"oh-my-openagent.json: active routes use disabled providers: {sorted(disabled_provider_refs)}")
        else:
            ok("all active model routes use enabled providers")

# ---- 4. config-only purity (install artifacts must stay gitignored + absent) ----
STRAYS = (
    "node_modules", "package.json", "package-lock.json", "npm-shrinkwrap.json",
    "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", ".omo", ".sisyphus",
    ".codegraph", "command", ".opencode", "plugins",
)
present = [s for s in STRAYS if os.path.lexists(os.path.join(repo, s))]
if present:
    err(f"config-only violation — remove install/runtime strays: {present} (run ./cleanup.sh or ./fix.sh)")
else:
    ok("config dir clean (no node_modules/package.json/.omo/.sisyphus/command/plugins)")

# git must ignore the common install paths (even when absent)
ignore_targets = [
    "node_modules", "node_modules/pkg", "package.json", "package-lock.json",
    "bun.lock", ".omo", ".sisyphus", ".codegraph", "command", ".opencode",
    ".cursor", "plugins", "stray-not-in-allowlist.txt", "opencode.log", "logs/x.log",
]
try:
    r = subprocess.run(
        ["git", "check-ignore", "-v", "--"] + ignore_targets,
        cwd=repo, capture_output=True, text=True, check=False,
    )
    ignored = {line.split("\t")[-1] for line in r.stdout.splitlines() if "\t" in line}
    required = {
        "node_modules", "package.json", ".omo", ".sisyphus", ".codegraph",
        "command", ".opencode", ".cursor", "plugins",
        "stray-not-in-allowlist.txt", "opencode.log",
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
    else:
        ok(".gitignore is deny-all + allowlist (config-only)")
except FileNotFoundError:
    warn("git not available — skipped ignore coverage check")

# ---- 4b. prompt_append file:// URIs must resolve ----
def resolve_prompt_uri(uri):
    if not uri.startswith("file://"):
        return None  # inline text — ok
    raw = uri[7:]
    try:
        from urllib.parse import unquote
        raw = unquote(raw)
    except Exception:
        pass
    if raw.startswith("~/"):
        raw = os.path.join(os.path.expanduser("~"), raw[2:])
    elif raw.startswith("./") or not os.path.isabs(raw):
        raw = os.path.normpath(os.path.join(repo, raw.lstrip("./")))
    return raw

missing_prompts = []
checked = 0
for section, blob in (("agents", omo.get("agents") or {}), ("categories", omo.get("categories") or {})):
    for name, cfg in blob.items():
        if not isinstance(cfg, dict):
            continue
        for field in ("prompt_append", "prompt"):
            val = cfg.get(field)
            if not isinstance(val, str) or not val.strip():
                continue
            if not val.startswith("file://"):
                continue
            checked += 1
            path = resolve_prompt_uri(val)
            if path is None or not os.path.isfile(path):
                missing_prompts.append(f"{section}.{name}.{field} -> {val}")

if missing_prompts:
    err(f"prompt file:// paths missing: {missing_prompts}")
elif checked:
    ok(f"{checked} prompt file:// path(s) resolve")
else:
    warn("no file:// prompt_append entries found")

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

# ---- 4c1. content-aware-research agent + profile alignment ----
ca_md = os.path.join(repo, "agents", "content-aware-research.md")
ca_prof = os.path.join(repo, "profiles", "content-aware.json")
if not os.path.isfile(ca_md):
    err("agents/content-aware-research.md missing (OpenCode-native content-aware agent)")
else:
    body = open(ca_md, encoding="utf-8").read()
    # content-aware frontmatter uses YAML "edit: deny"
    if re.search(r"(?m)^\s*edit:\s*deny\s*$", body) is None:
        err("agents/content-aware-research.md: permission.edit must be deny")
    else:
        ok("agents/content-aware-research.md present (edit deny)")
if not os.path.isfile(ca_prof):
    err("profiles/content-aware.json missing")
else:
    try:
        gp = json.load(open(ca_prof))
        if gp.get("default_agent") != "content-aware-research":
            err(f"profiles/content-aware.json default_agent must be content-aware-research (got {gp.get('default_agent')!r})")
        elif (gp.get("permission") or {}).get("edit") != "deny":
            err("profiles/content-aware.json permission.edit must be deny")
        else:
            ok("profiles/content-aware.json → content-aware-research (edit deny)")
    except Exception as e:
        err(f"profiles/content-aware.json: invalid JSON ({e})")

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
    err("versions.json missing (OpenCode / OmO / Ghostty / tmux minima for doctor)")
else:
    try:
        vdata = json.load(open(versions_cfg))
        for path in ("opencode.min", "oh_my_openagent.pin", "codegraph.pin", "ghostty.min", "tmux.min"):
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
        # pin in opencode.json should match versions.json
        pin = None
        for p in (oc.get("plugin") or []):
            if isinstance(p, str) and "oh-my-openagent@" in p:
                pin = p.split("@", 1)[1]
                break
        want = ((vdata.get("oh_my_openagent") or {}).get("pin") or "")
        if pin and want and pin != want:
            err(f"oh-my-openagent pin {pin!r} ≠ versions.json {want!r}")
        elif pin and want:
            ok(f"versions.json aligned with plugin pin {pin}")
        else:
            ok("versions.json present")
    except Exception as e:
        err(f"versions.json: invalid JSON ({e})")

# ---- 4c4. tmux.conf present (team mode / Ghostty) ----
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
        ok("tmux.conf has OmO/Ghostty essentials")

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
    "diagnose.sh", "maintain.sh", "models.sh", "versions.sh", "locate.sh", "signature.sh", "lib/common.sh",
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

common_sh = open(os.path.join(repo, "lib/common.sh"), encoding="utf-8").read()
missing_helpers = [fn for fn in (
    "oc_banner", "oc_projects_dir", "oc_ensure_launch_workspace", "oc_resolve_launch_dir",
    "oc_prune_stale_omo_plugin_caches", "oc_ensure_omo_plugin_cache",
    "oc_agent_visibility_report", "oc_log_misuse_report",
    "oc_version_ge", "oc_write_project_opencode_json", "oc_expand_path",
    "oc_set_env_key_if_unset", "oc_ensure_env_file", "oc_link_points_to", "oc_ensure_symlink",
    "oc_verify_signature", "oc_signature_compute", "oc_signature_refresh",
    "oc_scrub_env_to_allowlist", "oc_import_allowlisted_dotenv", "oc_env_foreign_key_count",
    "oc_backup_copy",
) if f"{fn}()" not in common_sh]
if missing_helpers:
    err(f"lib/common.sh missing helpers: {missing_helpers}")
elif "OpenConfig" in common_sh:
    ok("lib/common.sh has OpenConfig banner + path/version helpers")

# Secrets hygiene: .env must never be tracked; launch must not Infisical-wrap
env_tracked = subprocess.run(
    ["git", "-C", repo, "ls-files", "--error-unmatch", ".env"],
    capture_output=True, text=True,
).returncode == 0
if env_tracked:
    err(".env is tracked by git — remove it immediately (secrets leak)")
else:
    ok(".env is not tracked by git")
for rel in ("opencode.sh", "run.sh", "oc"):
    body = open(os.path.join(repo, rel), encoding="utf-8").read()
    if "infisical run --env=ops" in body or "infisical run --env=prod" in body:
        err(f"{rel}: Infisical process wrap injects vault secrets — remove (use oc setup --sync-env)")
if not any(
    "infisical run --env=ops" in open(os.path.join(repo, rel), encoding="utf-8").read()
    for rel in ("opencode.sh", "run.sh", "oc")
):
    ok("launch/run paths do not Infisical-wrap the agent process")
else:
    err("lib/common.sh missing OpenConfig branding")

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
else:
    ok("oc CLI branded OpenConfig with install + heal + locate + test + signature")

# ---- 4c7. docs / env example / bunfig / zshrc ----
for rel, label in (
    ("AGENTS.md", "AGENTS.md"),
    ("README.md", "README.md"),
    (".env.example", ".env.example"),
    ("bunfig.toml", "bunfig.toml"),
    ("zshrc.snippet", "zshrc.snippet"),
    ("projects.json", "projects.json"),
):
    if not os.path.isfile(os.path.join(repo, rel)):
        err(f"{label} missing")
    else:
        ok(f"{label} present")

env_ex = open(os.path.join(repo, ".env.example"), encoding="utf-8").read()
for key in ("OPENROUTER_API_KEY", "EXA_API_KEY", "CONTEXT7_API_KEY", "OC_PROJECTS_DIR", "OC_DEFAULT_WORKSPACE"):
    if key not in env_ex:
        err(f".env.example missing {key}")
if "OPENROUTER_API_KEY" in env_ex and "OC_PROJECTS_DIR" in env_ex and "OC_DEFAULT_WORKSPACE" in env_ex:
    ok(".env.example has required/optional key placeholders")

readme = open(os.path.join(repo, "README.md"), encoding="utf-8").read()
if "# OpenConfig" not in readme and "OpenConfig" not in readme[:500]:
    warn("README.md should lead with OpenConfig branding")
else:
    ok("README.md branded OpenConfig")

# ---- 4c8. teams + profiles completeness ----
teams_dir = os.path.join(repo, "teams")
if not os.path.isdir(teams_dir):
    err("teams/ directory missing")
else:
    team_specs = []
    for name in sorted(os.listdir(teams_dir)):
        cfg = os.path.join(teams_dir, name, "config.json")
        if os.path.isfile(cfg):
            try:
                t = json.load(open(cfg))
                if not t.get("lead"):
                    err(f"teams/{name}/config.json missing lead")
                elif not t.get("members"):
                    err(f"teams/{name}/config.json missing members")
                else:
                    team_specs.append(name)
            except Exception as e:
                err(f"teams/{name}/config.json invalid: {e}")
    if len(team_specs) < 7:
        err(f"expected ≥7 team specs, found {len(team_specs)}: {team_specs}")
    else:
        ok(f"{len(team_specs)} team specs valid: {', '.join(team_specs)}")

profiles = sorted(glob.glob(os.path.join(repo, "profiles", "*.json")))
if len(profiles) < 7:
    err(f"expected ≥7 profiles, found {len(profiles)}")
else:
    ok(f"{len(profiles)} profiles present")

# ---- 4c9. OmO tmux + OpenConfig product fields ----
if omo:
    tmux = omo.get("tmux") or {}
    if tmux.get("enabled") is True and tmux.get("layout") == "main-vertical":
        ok("OmO tmux enabled (main-vertical)")
    else:
        warn(f"OmO tmux config unexpected: {tmux}")

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
if omo:
    if omo.get("telemetry") is not False:
        tel_issues.append("omo.telemetry not false")
    if omo.get("auto_update") is not False:
        tel_issues.append("omo.auto_update not false")
    if (omo.get("codegraph") or {}).get("telemetry") is not False:
        tel_issues.append("codegraph.telemetry not false")
    gm = omo.get("git_master") or {}
    if gm.get("include_co_authored_by") is not False:
        tel_issues.append("git_master.include_co_authored_by not false")
    if (omo.get("experimental") or {}).get("disable_omo_env") is not True:
        tel_issues.append("experimental.disable_omo_env not true")
    if omo.get("mcp_env_allowlist"):
        tel_issues.append("mcp_env_allowlist must be empty")
    dmcps = set(omo.get("disabled_mcps") or [])
    for must in ("posthog:posthog", "sentry:sentry"):
        if must not in dmcps:
            tel_issues.append(f"disabled_mcps missing {must}")
env_ex = open(os.path.join(repo, ".env.example"), encoding="utf-8").read() if os.path.isfile(os.path.join(repo, ".env.example")) else ""
for key in ("DO_NOT_TRACK=1", "OMO_DISABLE_POSTHOG=1", "OMO_SEND_ANONYMOUS_TELEMETRY=0",
            "CODEGRAPH_TELEMETRY=0", "OTEL_SDK_DISABLED=true", "OMO_CODEX_DISABLE_POSTHOG=1"):
    if key not in env_ex:
        tel_issues.append(f".env.example missing {key}")
common_body = open(os.path.join(repo, "lib/common.sh"), encoding="utf-8").read()
if "oc_telemetry_off()" not in common_body or "OTEL_SDK_DISABLED" not in common_body:
    tel_issues.append("lib/common.sh oc_telemetry_off incomplete")
if tel_issues:
    err("telemetry not fully disabled: " + "; ".join(tel_issues))
else:
    ok("telemetry off (OpenCode share/OTel · OmO PostHog · codegraph · OTEL_SDK)")

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

# ---- 4d. stale Opus-primary ultrawork wording (config uses Fable max) ----
stale_opus = []
for root, _, files in os.walk(os.path.join(repo, "prompts")):
    for fn in files:
        if not fn.endswith(".md"):
            continue
        path = os.path.join(root, fn)
        try:
            txt = open(path, encoding="utf-8").read()
        except OSError:
            continue
        low = txt.lower()
        if "opus max" in low or "ultrawork/opus" in low or "ultrawork → claude opus" in low:
            stale_opus.append(os.path.relpath(path, repo))
agents_txt = open(os.path.join(repo, "AGENTS.md"), encoding="utf-8").read().lower()
if "ultrawork" in agents_txt and "opus max path" in agents_txt:
    stale_opus.append("AGENTS.md")
if stale_opus:
    warn(f"stale Opus-primary ultrawork wording (config uses Fable max): {stale_opus}")
else:
    ok("no stale Opus-primary ultrawork wording in prompts")

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
R = "\033[31m" if color else ""; Z = "\033[0m" if color else ""
q = os.environ.get("VALIDATE_QUIET") == "1"
if not q:
    for m in oks: print(f"  {G}✓{Z} {m}")
for m in warns: print(f"  {Y}⚠{Z} {m}")
for m in errors: print(f"  {R}✗{Z} {m}")
print()
print(f"  {len(oks)} ok · {len(warns)} warnings · {len(errors)} errors")
sys.exit(1 if errors else 0)
PY
