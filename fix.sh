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
#
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

c_g="\033[32m"; c_y="\033[33m"; c_b="\033[36m"; c_0="\033[0m"

DRY=$DRY python3 - "$REPO" ${SETS[@]+"${SETS[@]}"} <<'PY'
import json, sys, os, re, copy, shutil

repo = sys.argv[1]
sets = sys.argv[2:]
dry = os.environ.get("DRY") == "1"
changes = []
stamp = os.environ.get("OC_FIX_STAMP") or ""
backup_root = os.environ.get("OC_BACKUP_ROOT") or os.path.expanduser("~/.opencode-backups")

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

# lock skills to the repo — no loading from ~/.claude, ~/.agents, or other external dirs
sk = oc.setdefault("skills", {})
ext = [p for p in sk.get("paths", []) if str(p).startswith(("~", "/")) or ".claude" in str(p) or ".agents" in str(p)]
if ext:
    sk["paths"] = ["./skills"]; changes.append("skills.paths -> ['./skills'] (dropped external skill dirs %s)" % ext)

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
exp = oc.setdefault("experimental", {})
if not isinstance(exp, dict):
    oc["experimental"] = {}; exp = oc["experimental"]
if exp.get("openTelemetry") is not False:
    exp["openTelemetry"] = False; changes.append("experimental.openTelemetry -> false")
srv = oc.get("server")
if isinstance(srv, dict):
    if srv.get("mdns") is not False:
        srv["mdns"] = False; changes.append("server.mdns -> false")
    if srv.get("port") != 4097:
        srv["port"] = 4097; changes.append("server.port -> 4097 (avoid Cursor on 4096)")
    if srv.get("hostname") not in ("127.0.0.1", "localhost"):
        srv["hostname"] = "127.0.0.1"; changes.append("server.hostname -> 127.0.0.1")

# ─── No OpenCode / agent attribution on OpenRouter requests ───────────────────
or_opts = oc.setdefault("provider", {}).setdefault("openrouter", {}).setdefault("options", {})
if isinstance(or_opts, dict):
    hdrs = or_opts.setdefault("headers", {})
    if isinstance(hdrs, dict):
        want_hdrs = {
            "HTTP-Referer": "https://openrouter.ai",
            "X-Title": "CLI",
            "X-OpenRouter-Title": "CLI",
            "X-OpenRouter-Categories": "cli",
        }
        for hk, hv in want_hdrs.items():
            if hdrs.get(hk) != hv:
                hdrs[hk] = hv
                changes.append(f"openrouter.headers.{hk} -> {hv} (no OpenCode attribution)")

# ─── oh-my-openagent.json ─────────────────────────────────────────────────────
omo = load("oh-my-openagent.json"); ombefore = copy.deepcopy(omo)

# OmO / codegraph telemetry + co-author phone-home off
if omo.get("telemetry") is not False:
    omo["telemetry"] = False; changes.append("omo telemetry -> false")
if omo.get("auto_update") is not False:
    omo["auto_update"] = False; changes.append("omo auto_update -> false")
cg = omo.setdefault("codegraph", {})
if isinstance(cg, dict) and cg.get("telemetry") is not False:
    cg["telemetry"] = False; changes.append("codegraph.telemetry -> false")
# Team mode must stay on for team_* tools + hyperplan
tm = omo.setdefault("team_mode", {})
if isinstance(tm, dict):
    if tm.get("enabled") is not True:
        tm["enabled"] = True; changes.append("team_mode.enabled -> true")
    # Cap fan-out: hyperplan needs ≥5 members; keep parallel low so teams can't runaway.
    if not isinstance(tm.get("max_parallel_members"), int) or tm.get("max_parallel_members") < 1:
        tm["max_parallel_members"] = 4; changes.append("team_mode.max_parallel_members -> 4")
    elif tm.get("max_parallel_members") > 4:
        tm["max_parallel_members"] = 4; changes.append("team_mode.max_parallel_members capped -> 4")
    if not isinstance(tm.get("max_members"), int) or tm.get("max_members") < 5:
        tm["max_members"] = 5; changes.append("team_mode.max_members -> 5 (hyperplan floor)")
    elif tm.get("max_members") > 6:
        tm["max_members"] = 6; changes.append("team_mode.max_members capped -> 6")

# Background-task runaway guard — keep concurrency / tool budgets bounded
bt = omo.setdefault("background_task", {})
if isinstance(bt, dict):
    if not isinstance(bt.get("defaultConcurrency"), int) or bt.get("defaultConcurrency") > 4:
        bt["defaultConcurrency"] = 4; changes.append("background_task.defaultConcurrency capped -> 4")
    pc = bt.setdefault("providerConcurrency", {})
    if isinstance(pc, dict):
        if not isinstance(pc.get("openrouter"), int) or pc.get("openrouter") > 6:
            pc["openrouter"] = 6; changes.append("providerConcurrency.openrouter capped -> 6")
        if not isinstance(pc.get("openai"), int) or pc.get("openai") > 4:
            pc["openai"] = 4; changes.append("providerConcurrency.openai capped -> 4")
    if not isinstance(bt.get("maxToolCalls"), int) or bt.get("maxToolCalls") > 400:
        bt["maxToolCalls"] = 400; changes.append("background_task.maxToolCalls capped -> 400")
    if not isinstance(bt.get("syncPollTimeoutMs"), int) or bt.get("syncPollTimeoutMs") < 60000:
        bt["syncPollTimeoutMs"] = 60000; changes.append("background_task.syncPollTimeoutMs -> 60000 (OmO floor)")
    cb = bt.setdefault("circuitBreaker", {})
    if isinstance(cb, dict):
        cb["enabled"] = True
        if not isinstance(cb.get("maxToolCalls"), int) or cb.get("maxToolCalls") > 400:
            cb["maxToolCalls"] = 400; changes.append("circuitBreaker.maxToolCalls capped -> 400")
rl = omo.setdefault("ralph_loop", {})
if isinstance(rl, dict) and (not isinstance(rl.get("default_max_iterations"), int) or rl.get("default_max_iterations") > 8):
    rl["default_max_iterations"] = 8; changes.append("ralph_loop.default_max_iterations capped -> 8")
# codegraph: never auto-build giant indexes
cg2 = omo.setdefault("codegraph", {})
if isinstance(cg2, dict):
    if cg2.get("auto_init") is not False:
        cg2["auto_init"] = False; changes.append("codegraph.auto_init -> false")
    if cg2.get("auto_provision") is not False:
        cg2["auto_provision"] = False; changes.append("codegraph.auto_provision -> false")

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

# lock omo skills to the repo (mirror opencode.json)
osk = omo.get("skills")
osk_ext = isinstance(osk, dict) and any(
    str(s).startswith(("~", "/")) or ".claude" in str(s) or ".agents" in str(s)
    for s in (osk.get("sources") or [])
)
if osk_ext or (isinstance(osk, dict) and osk.get("sources") not in (["./skills"], None) and any(
        (s.get("path") if isinstance(s, dict) else s) not in ("./skills",) for s in (osk.get("sources") or []))):
    omo["skills"] = {"sources": ["./skills"]}; changes.append("omo skills.sources -> ['./skills']")

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
  printf "${c_b}==>${c_0} Re-validating\n"
  validate_out="$($REPO/validate.sh 2>&1)"
  validate_rc=$?
  printf '%s\n' "$validate_out" | tail -1
  exit "$validate_rc"
fi
