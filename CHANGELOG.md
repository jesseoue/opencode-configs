# Changelog

All notable changes to **OpenConfig** (`opencode-configs` / `oc`) are documented here.

## [1.5.60] — 2026-08-19

### Live-endpoint alignment: provider pins rebuilt, Flash 0731 revert, Hermes research lane

Every pin re-verified against the live `openrouter.ai/api/v1/models` catalog + per-model endpoint rosters (2026-08-19). All 11 whitelisted models live; context/tool/vision flags confirmed exact.

- **GLM 5.3 routing blackhole fixed**: the `provider.only` roster stamped by `oc fix` was glm-5.2-era (novita/gmicloud/streamlake/…) and matched **zero** live glm-5.3 endpoints — every default-model request would 404 ("All providers have been ignored"). glm-5.3 is z-ai-exclusive today, so it now routes **unpinned**; `fix.sh` removes stale pins and `validate.sh` errors on them.
- **DeepSeek pins rebuilt from live endpoints**: `["gmicloud","novita","siliconflow","parasail","deepinfra","baidu","fireworks","digitalocean"]` — fp8/full-precision unmoderated hosts only. Drops `baseten/fp4` (fp4 degrades tool-calling), degraded `together`, and first-party `deepseek` (endpoint down, uptime 0). Prompts/README no longer claim "first-party only".
- **MiniMax M3 pin widened**: `["together"]` (single host, half-context) → `["gmicloud","novita","deepinfra","together"]` — all healthy, fp8/unknown, still skips first-party.
- **DeepSeek Flash reverted to `-0731`**: the 07-31 snapshot is the *newest* Flash revision (1.31M ctx); the plain `deepseek-v4-flash` slug is the older 04-24 build. GA `deepseek-v4-pro` def removed; whitelist now 11 models. `fix.sh`/`diagnose.sh`/`models.sh` invariants track `-0731`.
- **content-aware-research → Hermes 4 405B** (nebius/fp8, uncensored): tool-less by design — it reasons over pasted context; edit stays denied; fallbacks glm-5.3 → laguna → qwen3.8-max remain tool-capable. Removed Hermes from `fix.sh` RECON_FALLBACKS (a no-tools model must never back a tool-using recon agent); dropped dead `hermes-4-70b` ref.
- **New `validate.sh` guards**: (1) vision chains (multimodal-looker / visual-engineering / artistry) must be `attachment:true` end-to-end; (2) every agent/category chain must be `tool_call:true` except content-aware-research; (3) stale `provider.only` pins on unpinned families now error.
- **Category colors removed**: OmO 4.19.4 schema allows `color` on agents only — `fix.sh` no longer re-adds category colors it had just stripped (idempotency restored; agent colors unchanged).
- **Fallback chains deepened**: third fallback (qwen3.8-max / longcat-2.0 / minimax-m3) added across agents + categories; `modelConcurrency` gains pro-0813 (5, six healthy hosts) and hermes-4-405b (2).
- Newer catalog arrivals evaluated, deliberately skipped: `kimi-k3` ($3/$15 — 4× k2.7-code for the same fallback role), `qwen3.8-2.4t-a95b` (qwen3.8-max price, no vision), `grok-4.6` (off-stack, pricier than GLM/DeepSeek lanes).
- `launch-desktop.sh` removed (v1.5.59 helper superseded; no remaining references).
- RECON_PRIMARY aligned to actual primaries (metis / arch-review → glm-5.3).

## [1.5.59] — 2026-08-19

### Model refresh: GLM 5.3 default + Flash GA + Gemini 3.7 Flash
- **Default model** `xiaomi/mimo-v2.5-pro` → **`z-ai/glm-5.3`** (new Z.ai flagship, 1M ctx, reasoning + tool-call, unmoderated). Applied everywhere: `opencode.json` default + small-model, all `oh-my-openagent.json` agents/fallbacks, all six profiles (fast/low/high/debug/writing/research), and `fix.sh` recon fallbacks. `mimo-v2.5-pro` fully removed from whitelist + model defs.
- **DeepSeek Flash GA**: `deepseek/deepseek-v4-flash-0731` (pre-GA) → **`deepseek/deepseek-v4-flash`** (GA). Updated content-aware-fast primary, profile small-model, and all fallback chains.
- **Gemini 3.7 Flash**: `google/gemini-3.6-flash` → **`google/gemini-3.7-flash`** in multimodal-looker / ultrabrain / quick / bug-hunt fallbacks + modelConcurrency.
- `fix.sh` invariants updated: `DEEP_PRIMARY`/`MAX_PRIMARY` → `glm-5.3`, `content-aware-fast` → `deepseek-v4-flash`.
- `_mc_cap` already routes `glm` → 8, `flash` → 10 (no change needed).
- README model-routing table refreshed (GLM 5.3 orchestration, Flash GA, Gemini 3.7 Flash).
- Whitelist + model defs updated in `opencode.json` (glm-5.3, gemini-3.7-flash, deepseek-v4-flash).

## [1.5.58] — 2026-08-12

### Fix: `oc doctor` self-sabotage (OmO config-migration ate canonical config)
- **Root cause**: `oc doctor` ran `bunx oh-my-openagent doctor` and `opencode agent list`. Both load the OmO plugin, whose config-migration treats the repo's canonical `oh-my-openagent.json` as a legacy source and **moves it into a backup**, regenerating a broken `~/.omo/omo.jsonc`. Every full doctor run silently deleted the repo's canonical config.
- **Fix**: `doctor.sh` no longer invokes the OmO CLI or `opencode agent list`. Plugin health is verified statically (pin match + cache version). Runtime agent-visibility probe skipped with an explanatory note.
- **Fix**: `cleanup.sh` plugin-pin check now reads the cache version statically instead of `bunx … doctor`.
- Result: `oc doctor` verdict went from `core_ready` (6 optional warnings) to **`ready`** (0 critical, 0 optional), and the repo file stays intact across all runs.
- Verified: validate 87 ok · smoke 29 passed · deploy check green (except expected uncommitted state).

## [1.5.57] — 2026-08-12

### OpenCode CLI 1.18.17 (patch upgrade)
- Upgrade OpenCode CLI **1.18.16 → 1.18.17** (released today, patch-only bugfixes)
- Key fixes: compaction keeps complete recent turns + clearer summaries for smaller models; capped automatic session retries + jitter (reduces retry storms); **correct sampling defaults for DeepSeek V4 Flash** (directly relevant to our Flash routes); MERGE Gateway reasoning variants; Copilot PDF support; Muse system prompt routing
- No breaking changes — safe patch upgrade
- `@opencode-ai/plugin` stays at `1.18.15` (no 1.18.16/17 published yet for plugin)
- OmO stays at `4.19.4` (npm latest, no new release)
- `versions.json` floor: `opencode.min` 1.18.16 → 1.18.17

## [1.5.56] — 2026-08-12

### Deployment protection + repo cleanup + SEO
- **New `oc deploy` command** (`deploy-guard.sh`): pre-deployment gate (credits, model probes, rate limits, git cleanliness, signature), deployment lock with TTL, quarantine mode (auto-swap to cheaper models on credit pressure), continuous credit heartbeat
- **Hardened circuit breaker**: added cooldown (30s), half-open retries (3), fallback-on-trip, notify-on-trip
- **Cost-aware runtime fallback**: `cost_aware_routing`, `max_cost_per_request` ($0.50), budget warning/critical thresholds (80%/95%), degrade-on-budget-pressure
- **README cleanup**: fixed stale version refs (1.5.53 → 1.5.55) and stale concurrency values (6/8/3/1 → 10/12/5/2), added Features table, Deployment protection docs, SEO keywords
- **GitHub SEO**: repo description rewritten, topics refreshed (model-gateway, config-as-code, circuit-breaker, cost-aware)
- Whitelist unchanged at 19 models — all probed healthy

### Docs alignment (AGENTS.md + README.md)
- **AGENTS.md**: commands list now includes `oc deploy`; routing logic split into GA recon vs pre-GA content-aware lanes; Deep implement line notes Qwen 3.8 Max / Kimi K2.7 Code fallbacks; content-aware line marked pre-GA + edit denied
- **README.md**: model routing table split recon (GA DeepSeek Pro 0813) from content-aware (pre-GA); subagent/primary/category/profile tables disambiguated "DeepSeek Pro 0813" vs "DeepSeek Pro (pre-GA)"; removed stale "Direct OpenAI stays defined" note (OpenRouter-only); Safety line corrected to OpenRouter-only; layout tree lists all 16 scripts incl. `deploy-guard.sh`; CLI + Verify sections now surface `oc deploy check` / `quarantine` / `status`
- `oc signature --refresh` re-run after edits; `validate.sh` 87 ok, `tests/smoke.sh` 29 passed, `oc fix` clean, `oc deploy check` green (except expected uncommitted state)

## [1.5.55] — 2026-08-12

### New models + routing refresh for non-content-aware routes
- Add **Qwen 3.8 Max** (`qwen/qwen3.8-max`) — new Qwen flagship, 1M ctx, unmoderated, $2/$6. Added to hephaestus/oracle/deep fallback chains (replaces minimax)
- Add **Kimi K2.7 Code** (`moonshotai/kimi-k2.7-code`) — coding-focused, 262K ctx, $0.67/$3.40, 5x cheaper than kimi-k3. Added to bug-hunt/refactor-safe/sisyphus fallbacks
- Whitelist: **19 models** (was 17 — added 2 new, content-aware still on pre-GA deepseek-v4-pro)
- `fix.sh` `_mc_cap` updated for qwen3.8-max + kimi-k2.7 (cap 5 each)
- `fix.sh` `DEEP_FALLBACKS`/`MAX_FALLBACKS`/`RECON_FALLBACKS` updated to include new models
- `deepseek-v4-pro` price drop confirmed: $0.43/$0.87 (now matches 0813 GA — better value for content-aware)
- All 19 models probed live: **19/19 HTTP 200**

## [1.5.54] — 2026-08-12

### Uncensored route → pre-GA DeepSeek models
- **content-aware-research** agent → `deepseek/deepseek-v4-pro` (pre-GA, unaligned) — the older non-GA release, less alignment baked in
- **content-aware-deep** category → `deepseek/deepseek-v4-pro` (pre-GA)
- **content-aware-fast** category → `deepseek/deepseek-v4-flash-0731` (pre-GA flash, $0.08/$0.18)
- `profiles/content-aware.json` model → `deepseek-v4-pro`, small_model → `deepseek-v4-flash-0731`
- Whitelist + model defs added: `deepseek/deepseek-v4-pro` (`:exacto`) and `deepseek/deepseek-v4-flash-0731` (`:nitro`)
- `fix.sh` RECON_PRIMARY maps content-aware-* to pre-GA models; `flash-0731` added to RECON_FALLBACKS
- All other routes (explore/librarian/deep/ultrabrain/etc.) stay on GA `deepseek-v4-pro-0813`
- Whitelist: 17 models (was 15 — added 2 pre-GA variants)

## [1.5.53] — 2026-08-12

### Model refresh — upgrade to latest from OpenRouter API
- **Claude Opus 5** (`anthropic/claude-opus-5`) replaces Opus 4.8 — new Anthropic flagship, same price ($5/$25)
- **Claude Opus 5 Fast** (`anthropic/claude-opus-5-fast`) replaces Opus 4.8 Fast — same price ($10/$50)
- **DeepSeek V4 Pro 0813** (`deepseek/deepseek-v4-pro-0813`) replaces `deepseek-v4-pro` — GA release, **63% cheaper** ($0.43/$0.87 vs $1.17/$2.34), supports `:exacto` routing
- Remove `anthropic/claude-opus-4.7` (obsolete — Opus 5 supersedes at same price)
- All 15 whitelisted models verified against live OpenRouter API: **15/15 HTTP 200**
- Whitelist: 15 models (was 16 — removed 3 old, added 2 new)

## [1.5.52] — 2026-08-11

### Version refresh — OpenCode CLI 1.18.11 → 1.18.16
- Upgrade OpenCode CLI to **1.18.16** (5 patch releases: 1.18.12–1.18.16, Aug 4–10)
- `@opencode-ai/plugin` peer **1.18.11 → 1.18.15** (1.18.16 not yet published for plugin)
- OmO stays **4.19.4** (npm `latest` stable). 5.0.0-beta.x is a **breaking beta** (renames `omo` → `omo-agent-toolkit`, changes config format) — skipped
- `versions.json` floor: `opencode.min` 1.18.11 → 1.18.16

## [1.5.51] — 2026-08-11

### Live OpenRouter audit — capacity + new models
- Raise `background_task.defaultConcurrency` **6 → 10**, `providerConcurrency.openrouter` **8 → 12** for big parallel loads
- Model caps up: flash/floor/qwen3.7-flash/gemini flash-lite **10**, exacto/minimax **8**, pro/sonnet **5**, claude opus/fable/kimi **2**
- Add `qwen/qwen3.7-flash` ($0.03/$0.13, 1M ctx, 76t/s) as ultra-cheap fast lane
- Add `google/gemini-3.5-flash-lite` ($0.30/$2.50, 1M ctx, 220t/s) as cheap high-throughput fallback
- All 16 whitelisted models verified against live OpenRouter API (`/api/v1/models`): **16/16 HTTP 200**
- OpenCode CLI 1.18.11 (GitHub latest 1.18.16 — optional upgrade); OmO 4.19.4 = npm latest; `@opencode-ai/plugin` 1.18.11 pinned to CLI

## [1.5.50] — 2026-08-01

### CLI clarity — aliases + OpenRouter-only help
- Add `oc` aliases: `health`/`ready` → check, `repair` → heal, `verify` → validate (plus existing `where`, `sig`, `pins`, `omo`)
- Help/examples: remove stale direct-OpenAI wording; document aliases; list `runtime` in `oc test`
- Unknown-command tips for `clean`, `probe`, `repair`, `verify`
- README/AGENTS version sync

## [1.5.49] — 2026-08-01

### OpenRouter-only — no GPT models
- Remove all `openai/gpt-*` from whitelist, model defs, and active agent/category routes
- Hephaestus / Oracle → DeepSeek Pro; Momus / ultrabrain / unspecified-high → Claude Fable 5
- `providerConcurrency` → OpenRouter gateway only (`openrouter: 8`); no openai/anthropic sub-keys
- `oc fix` / `oc validate` enforce no GPT in routes or whitelist

## [1.5.48] — 2026-08-01

### Fast provider concurrency
- Raise parallel throughput: `defaultConcurrency` **6**, `providerConcurrency` openrouter **8** / openai **6** / anthropic **4**
- Model caps tuned for speed: Flash/Luna **6**, GLM Exacto/MiniMax **5**, Pro/Sol/Terra **3**, Opus/Fable/Kimi **1**
- `oc fix` / `validate` / `doctor` pin the new ceilings (OpenRouter-only; circuit breaker unchanged)

## [1.5.47] — 2026-08-01

### Sisyphus fix + OpenRouter-only hardening
- `oc fix` quarantines broken `~/.omo/omo.jsonc` when a partial OmO migrate wrote invalid `agents.*.models` arrays (OmO 4.19.4 rejects them — Sisyphus fails to load; canonical config stays `oh-my-openagent.json`)
- `oc validate` checks Sisyphus is OpenRouter-only (primary/fallbacks/ultrawork), `sisyphus_agent` enabled, and no conflicting `omo.jsonc`

## [1.5.46] — 2026-08-01

### Unmoderated smart recon routing
- **Explore / Librarian** primaries → DeepSeek Pro (unmoderated); Flash → GLM Exacto → MiniMax fallbacks
- **Explore** gets explicit permissions: `webfetch`, `question`, `task` (edit denied); prompts + `explorers` team scouts use full Exa/webfetch stack
- **deep**, **arch-review**, **metis**, **multimodal-looker** → unmoderated primaries (DeepSeek Pro / GLM Exacto / Gemini 3.1 Pro)
- Fast categories (`quick`, `content-aware-fast`, …) escalate to Pro on fallback — no Claude/GPT on recon chains
- `oc validate` / `oc fix` guard recon routes against moderated primaries and fallbacks

## [1.5.45] — 2026-08-01

### Fast model/provider testing
- `oc models --probe` — parallel live probes (8 workers) for all whitelisted models: latency, HTTP status, `is_moderated`, routing pin, fastest endpoint host
- `oc models --moderation` — instant policy catalog (no chat calls): `moderationRequired` providers, per-model routing pins, data retention/training flags
- `oc admin health` model section delegates to `--probe` (was sequential — ~10× faster on 18 models)

## [1.5.44] — 2026-08-01

### DeepSeek uncensored routing + question tool
- Pin all DeepSeek models to first-party OpenRouter host (`provider.only: ["deepseek"]`) — skips proxy providers that may add content moderation
- Set DeepSeek `require_parameters: false` (GLM/MiniMax unchanged)
- `question` tool explicitly allowed on content-aware-research agent/profile; Prometheus + core prompts encourage clarifying questions freely

## [1.5.43] — 2026-08-01

### New-user hygiene (no host-specific literals)
- OpenRouter `HTTP-Referer` syncs from `signature.json` → `github_b64` via `oc fix` (no hardcoded owner URLs in config)
- Distribution identity → `https://github.com/jesseoue/opencode-configs` (`github_b64` + install bootstrap)
- `oc versions` scans `projects.json` / `OC_PROJECTS_DIR` only — removed host-specific directory scan
- README / prompts: generic clone/install docs; drop `Cursor-pace` product naming; sync version pins to 1.5.43
- Validate checks OpenRouter attribution headers match signature distribution URL
- `review-panel` arch member → `arch-review` category (architecture lens; bugs stay on `bug-hunt`)

## [1.5.42] — 2026-08-01

### OpenRouter provider system cleanup
- Probe all 18 whitelisted models across 40+ OpenRouter provider hosts (live endpoints + HTTP 200 chat probes)
- Strip redundant `preferred_min_throughput` / `preferred_max_latency` from every model — native `:exacto`/`:nitro`/`:floor` suffixes and OpenRouter auto-ranking handle provider selection
- Sync `modelConcurrency` exactly to the 18-model whitelist with tier caps (Flash/Luna 4 · Exacto/MiniMax 3 · Pro/Sol 2 · Opus/Fable/Kimi 1)
- Pin `providerConcurrency` to openrouter=6, openai=4, anthropic=2 (OmO gateway limits for OpenRouter-routed backends)
- Validate rejects any remaining `preferred_*` soft prefs on Exacto, Nitro, Floor, and auto-routed models

## [1.5.41] — 2026-08-01

### Routing availability + concurrency hardening
- Live-probe all 18 whitelisted OpenRouter models (HTTP 200); OpenRouter-only, no direct providers
- Remove Kimi K3 from routine fallback chains (whitelist-only — slow, single-provider, expensive)
- Rebuild fast-agent fallbacks around DeepSeek Flash Nitro, GLM Exacto, and MiniMax M3
- Cap premium model concurrency (Sol/Terra/Opus/Fable/Kimi at 1–2; Flash/Exacto/Luna at 3–4)
- Add validate + fix guards against slow models in fast routes and kimi in fallbacks
- Fix Prometheus `reasoning`/`variant` mismatch and multimodal-looker primary duplicate fallback

## [1.5.40] — 2026-08-01

### OpenCode 1.18.11 + OmO 4.19.4
- Upgrade OpenCode CLI floor and `@opencode-ai/plugin` peer from 1.18.8 to **1.18.11** (MCP SSE reconnect fix, interleaved reasoning field support)
- Bump `oh-my-openagent` pin from 4.19.2 to **4.19.4** (final pre–Native CLI release: unified reasoning vocabulary, runtime fallback status patterns, category chain tuning, codegraph daemon hardening)
- Migrate all agent/category `reasoningEffort` → canonical `reasoning` field; `oc fix` and `validate.sh` enforce the new shape
- Refresh OmO `$schema` URL to v4.19.4; sync schema URL from `versions.json` pin in `oc fix`

## [1.5.39] — 2026-07-28

### OpenCode 1.18.8 + OmO 4.19.2
- Upgrade the OpenCode CLI and `@opencode-ai/plugin` peer from 1.18.5 to **1.18.8**
- Bump the `oh-my-openagent` pin from 4.19.1 to **4.19.2** and refresh its schema URL
- Keep `/goal` disabled while adopting notification-driven coordination, managed CodeGraph lifecycle fixes, and MCP compatibility fixes
- Enable OmO's managed CodeGraph **1.4.1** daemon and pinned-runtime auto-provisioning while keeping automatic indexing off
- Remove superseded Gemini 3.5 Flash and unused GPT-5.5 routing, align model output limits with the live catalog, and let native `:nitro` / `:exacto` routing adapt across the full eligible provider pool
- Remove unsupported OpenCode compaction config and the nonexistent direct Sol Pro alias; mark GPT temperature unsupported and align Momus/deep with Terra
- Harden OmO cache checks to verify the pinned main package, platform package, and executable; document `/start-work --make-pr|--ship`
- Preserve broad OpenRouter availability (`data_collection=allow`, no ZDR filter), minimize OpenCode logs, isolate MCP secrets, and redact credentials from maintenance logs
- Replace volatile provider-name pins with adaptive routing: Nitro for throughput, Exacto/Auto Exacto for tool quality, and Floor for cheap title/summary/compaction work
- Route active GPT agents through healthy OpenRouter endpoints, keep direct OpenAI dormant, and trim/demote slow or expensive fallback chains (especially Kimi and duplicate Opus/GPT entries)
- Bound premium outputs and runaway team/tool loops; retry only transient failures with three model attempts and a 120-second fallback window
- Replace 15-minute stream stalls with 300-second request / 60-second chunk limits, align MCP timeouts at 30 seconds, and prefer selective context pruning over blanket 4 KB truncation

## [1.5.38] — 2026-07-26

### Prompt contract hardening
- Align Momus with its narrow plan-executability role and Atlas with the injected `/start-work` contract
- Make Prometheus delegation conditional and require evidence-backed, implementation-ready plan steps
- Clarify layered verification, background-task continuation, edit-capable refusal recovery, and exact team identifiers
- Remove volatile/unusable model-lane prose from behavioral prompts; retain routing in configuration
- Make content-aware deliverables fit both vulnerability and non-vulnerability research
- Remove stale gpt-5.5 concurrency entries and a duplicate Opus 4.7 JSON key

## [1.5.37] — 2026-07-26

### Color polish + `oc plugin`
- Fix CLI help colors: use `$'\033[…m'` so `cat` heredocs emit real ANSI (was printing literal `\033[…]`)
- Same quoting fix across doctor/versions/setup/install/cleanup/… scripts
- Add `oc plugin doctor|cache|--fix` (alias `oc omo`) for OmO pin-cache doctor

## [1.5.36] — 2026-07-26

### Doctor harden
- OmO plugin: verify pin-cache `package.json` version; detect stale sibling caches that make `bunx doctor` false-report “outdated”
- `oc doctor --fix` / `oc versions --fix`: prune stale OmO caches + ensure pin cache + align `@opencode-ai/plugin` peer
- `modelConcurrency` orphans → soft advisory; whitelist + `openai/X`↔`openrouter/openai/X` aliases count as covered
- Runtime log: suppress historical `@opencode-ai/plugin` npm-miss when peer matches CLI; tip prettier/`BUN_BE_BUN` formatter noise
- `oc_prune_stale_omo_plugin_caches` helper in `lib/common.sh`

## [1.5.35] — 2026-07-26

### Team / parallel agent routing hygiene
- `explorers` scout-code → `content-aware-fast` (DeepSeek Flash) instead of GPT Sol `deep`
- `debug-team` root-cause → `content-aware-deep`; `review-panel` arch → `content-aware-deep`
- AUTHORIZED stance on all team member prompts + explore / junior / deep / quick / bug-hunt / ultrabrain / arch-review / hephaestus / librarian / content-aware-*
- Sisyphus: auth·danger·vuln recon prefers content-aware lanes; teammate soften → respawn same brief on content-aware-*

## [1.5.34] — 2026-07-25

### OpenCode 1.18.5 + live provider re-rank
- Upgrade OpenCode CLI 1.18.4 → **1.18.5** (Claude adaptive thinking, OpenAI Responses phase, MiniMax M3 thinking, grep symlink paths)
- Align `@opencode-ai/plugin` peer 1.18.4 → **1.18.5**; bump `versions.json` floor to 1.18.5
- OmO stays **4.19.1** (still npm + GitHub latest)
- Re-rank OpenRouter `provider.order` from live endpoints:
  - GLM Exacto → BaseTen / Cloudflare / Fireworks first (Baidu demoted; Friendli/Together absent — ignored)
  - DeepSeek Flash → DeepSeek / Baidu / Alibaba / Novita (Fireworks demoted on 95% uptime)
  - DeepSeek Pro → DeepSeek / Novita / Baidu / Alibaba (Venice demoted on 90% uptime)
  - MiniMax M3 → MiniMax / AtlasCloud / DeepInfra first

## [1.5.33] — 2026-07-24

### Fix — empty OmO plugin cache wiped agents
- Root cause: `~/.cache/opencode/packages/oh-my-openagent@4.19.1` was empty after pin bump, so Prometheus / Sisyphus / Atlas / etc. silently failed to load
- Restored plugin + platform binary via bun install into the OpenCode cache
- Add `oc_ensure_omo_plugin_cache` / `oc_omo_plugin_cache_ok` in `lib/common.sh`
- `oc setup` and `oc heal` now reinstall the cache when empty/broken
- Doctor checks for `node_modules/oh-my-openagent/package.json` (not just a non-empty dir)

## [1.5.32] — 2026-07-23

### OmO 4.19.1 pin bump
- Bump `oh-my-openagent` pin 4.19.0 → 4.19.1 (stability patch: process sweep, parent-liveness watchdogs, CodeGraph 1.4.1, sharper LSP diagnostics, ulw-loop batch efficiency)
- Update schema URL to v4.19.1, plugin pin in `opencode.json` / `tui.json`, `setup.sh` fallback
- Update all 4.19.0 goal-footgun references to 4.19.x (bug persists in 4.19.1)

### gpt-5.5 fallback purge (align with OmO 4.19.1)
- Remove `openai/gpt-5.5` and `openrouter/openai/gpt-5.5` from all OmO `fallback_models` arrays (Hephaestus, Oracle, Momus, ultrabrain, deep, arch-review)
- Remove gpt-5.5 from `modelConcurrency` map
- Update agent prompts (hephaestus, oracle, momus, fast profile) to drop 5.5 from fallback chain descriptions
- gpt-5.5 model definitions retained in `opencode.json` (still valid for direct use, just not a fallback rung)

## [1.5.31] — 2026-07-23

### Live provider re-rank + new models
- Re-rank GLM 5.2 Exacto `provider.order` from live endpoints (Alibaba 73 thr promoted above Friendli 72)
- Re-rank DeepSeek V4 Flash Nitro `provider.order` — Fireworks (79 thr, #1) promoted to #2 behind DeepSeek official
- Re-rank DeepSeek V4 Pro Exacto `provider.order` — Novita/SiliconFlow (55 thr each) promoted above Baidu/Alibaba
- Add `openai/gpt-5.6-luna` to whitelist + OpenRouter/OpenAI model defs — fast GPT lane ($1/$6, 145 thr)
- Add `openai/gpt-5.6-sol-pro` to whitelist + model defs — higher-quality reasoning mode, wired into Hephaestus/Oracle/Momus/ultrabrain/arch-review fallbacks
- Add `anthropic/claude-opus-4.7` to whitelist + model def — next-gen Opus for async agents ($5/$25), wired into Momus/ultrabrain/arch-review/unspecified-high fallbacks
- Add new models to `modelConcurrency` map (Luna=4, Sol Pro=3, Opus 4.7=1)

### Prompt tuning
- `prompts/core.md`: add Luna fast-lane routing note, update escalation path to Sol Pro
- `prompts/agents/sisyphus.md`: add Sol Pro fallback note for Hephaestus, Luna for fast GPT lane
- `AGENTS.md`: routing logic table updated with Sol Pro, Luna, Opus 4.7

## [1.5.30] — 2026-07-21

### Package pin audit
- Add `oc versions` (`versions.sh`) — compare OpenCode / OmO / `@opencode-ai/plugin` pins to npm + GitHub
- Scan other `opencode.json` under `~/Projects` (project overlays; OmO stays global)
- `oc versions --fix` aligns `~/.opencode` `@opencode-ai/plugin` peer to the installed CLI when npm has it
- Pins verified current: OpenCode `1.18.4`, OmO `4.19.0`, plugin peer `1.18.4`
- README: Package pins section + verify/install flows include `oc versions`

## [1.5.29] — 2026-07-21

### Team member prompts
- Rewrite all `teams/*/config.json` inline member prompts to ROLE / METHOD / DELIVERABLE / Mailbox shape
- Align with category skills (content-aware-recon/audit) and category Do/Don't
- Validate: every member needs a non-empty prompt; warn if ROLE:/Mailbox missing

## [1.5.28] — 2026-07-21

### Doctor + tooling
- Doctor: `soft` advisories (latency/network) no longer count as “optional missing”
- Doctor: `--json` machine summary (`critical` / `optional` / `soft` / `verdict`) for heal/check
- Doctor: inventory fenced skills; require `content-aware-recon` + `content-aware-audit`
- Doctor: accurate OpenRouter/OpenAI key auth failures (`401`/`403` → critical)
- Validate: assert local content-aware skills exist; smoke covers `doctor --json`
- Heal: log doctor JSON verdict after quick pass

## [1.5.27] — 2026-07-21

### Prompts · skills · profiles
- Deepen all agent / category / profile prompts (method, deliverable shape, routing tables)
- Add fenced local skills: `content-aware-recon`, `content-aware-audit` (replace OmO `security-*`)
- Strengthen `oc new` profiles: research/debug large tool_output; writing Gemini small_model; fast→Hephaestus; content-aware edit deny retained
- Retune GLM Exacto `provider.order` from live endpoints (baidu / cloudflare / baseten first)

## [1.5.26] — 2026-07-21

### Docs + identity
- Rewrite README as a clean technical reference (no keyword dumps / hype)
- Soften product tagline; document tool enablement matrix (Context7, Exa, grep_app, look_at, codegraph)

## [1.5.25] — 2026-07-21

### Prompts + docs hygiene
- Rewrite thin agent / category / profile prompts to a consistent OpenConfig voice (role + model, Do/Don't, deliverable, tool routing)
- Sync `agents/content-aware-research.md` with `prompts/agents/content-aware-research.md`
- README: prompts layout section; Atlas / Metis / Momus / multimodal roles accurate

## [1.5.24] — 2026-07-21

### Ecosystem hygiene (config-only)
- Re-enable OmO `look_at` (was disabled while multimodal-looker + permission.allow existed — vision path half-wired)
- Sync content-aware-research OmO prompt with OpenCode-native agent brief
- Writing docs/profile: Gemini **3.6** Flash (was stale 3.5)
- `oc models --providers` — live endpoint health vs `provider.order`/`ignore`
- `.env.example`: document `OPENCODE_DISABLE_*` launch hygiene (already forced by `oc_telemetry_off`)
- MiniMax Nitro: prefer official MiniMax host first

## [1.5.23] — 2026-07-21

### Provider routing (live endpoints)
- Re-rank `provider.order` / `ignore` from OpenRouter `/models/.../endpoints` health + throughput
- GLM Exacto → Friendli-first; DeepSeek Flash/Pro order matched live leaders; drop fp4/baseten & down hosts
- Gemini 3.1 Pro → Google AI Studio first (Vertex status=-2); Opus → Vertex-first; Fable → Bedrock-first (Anthropic/Azure down)
- MiniMax: allow Venice as fallback; keep Together/MiniMax primary
- Live probe: all workhorse models complete with intended providers

## [1.5.22] — 2026-07-21

### Hygiene — no personal host paths · deny-all gitignore
- `zshrc.snippet`: remove host-specific denylist/redirect paths; resolve workspace via `OC_*` / `projects.json` / `~/Projects` only
- `.gitignore`: default-deny root (`/*`) + explicit allowlist — logs, secrets, runtime junk, and anything outside the config set stay untracked
- Respect `OC_PROJECTS_DIR` / `OC_DEFAULT_WORKSPACE` (no longer stomp with a hard-coded `~/Projects` when that dir exists)

### OpenRouter catalog + routing tune
- Add `google/gemini-3.6-flash` (Nitro) — writing primary; visual/artistry fallbacks updated
- `artistry` → Gemini 3.1 Pro (was Kimi K3) to match the visual lane
- Refresh GLM / DeepSeek / MiniMax `provider.order` + `ignore` from live `/models/.../endpoints` (drop parasail/-5, fix `atlas-cloud` slug)
- OpenRouter attribution headers → OpenConfig (`HTTP-Referer` + `X-Title`)
- Skills: `~/.config/opencode/skills` + `./skills` so global stack works from any cwd (orca, Projects, …)
- `models.sh`: strip `:exacto`/`:nitro` for catalog/drift; recognize Gemini 3.6
- `.gitignore` deny-all + allowlist (config-only; blocks personal/runtime junk)
- `zshrc.snippet` reads projects home from `projects.json` (no host-path hardcoding)

## [1.5.21] — 2026-07-21

### Doctor / fix completeness (OmO 4.19)
- Doctor detects `@opencode-ai/plugin` CLI↔npm skew + recent install WARN / `InvalidObjectiveError` log signatures
- Doctor/validate: `ralph_loop` deprecated (Goals replaced Ralph) — flag leftover config; `oc fix` removes it
- `oc fix` now **enforces** `goal.enabled=false`, `auto_start=false`, `default_mode.goal=false`, `prompts/goal.md` in instructions, `mcp_env_allowlist`, `start_work.auto_commit=false`
- Doctor checks mcp_env_allowlist + start_work; smoke runs `bash -n doctor.sh` + `doctor --quick`
- Drop inert `ralph_loop` block from `oh-my-openagent.json`

## [1.5.20] — 2026-07-21

### Doctor safety
- Stop flagging live `lsp-daemon` children of running `opencode` / Cursor sessions as “stale”
- `oc doctor --harden` no longer kills open TUI sessions (only OpenCode.app + true orphan daemons)

## [1.5.19] — 2026-07-21

### Team mode hardened
- Pin full OmO 4.19 `team_mode` schema (`tmux_visualization`, message/turn/payload caps, `mailbox_poll_interval_ms=1000`)
- Complete `tmux` pane sizing (`main_pane_size` / min widths) for team layouts
- `oc setup` replaces directory *copies* under `~/.omo/teams` with symlinks (macOS `ln -sfn` nests inside dirs)
- Doctor/validate fail on team provision drift; smoke tests symlink health
- `oc fix` backfills missing team_mode / tmux keys

## [1.5.18] — 2026-07-21

### Critical — disable OmO `/goal` (unblocks `/start-work`)
- OmO 4.19.0 chat-message goal hook treats **every** user message as `setGoal`, including `/start-work`'s ~5541-char template
- That exceeds the 2000-char `validateObjective` hard cap → `InvalidObjectiveError` → sessions fail / flash-exit
- Set `goal.enabled: false` + `default_mode.goal: false`; keep `prompts/goal.md` as the decision log
- Doctor/validate **error** if goal is re-enabled on this OmO pin
- Prefer `/start-work` → Atlas for plan execution

## [1.5.17] — 2026-07-21

### Doctor / hygiene
- Fix doctor Concurrency Python `tip()` NameError that aborted the rest of the section (MCP/provider timeouts never ran after goal)
- Doctor now verifies `prompts/goal.md` is in `instructions` and that Prometheus/Sisyphus/Atlas/core know the 2000-char `/goal` cap
- Scrub `plugins/` as config-dir runtime stray (Herdr/etc.) — gitignore + `OC_CONFIG_STRAYS` + validate purity
- Hephaestus prompt: same `/goal` objective guardrail

## [1.5.16] — 2026-07-21

### Goal loop (Prometheus footgun)
- OmO hard-caps `/goal` objectives at **2000 characters** (`InvalidObjectiveError`) — not configurable
- Add `prompts/goal.md` and load it via `opencode.json` `instructions`
- Prometheus / Sisyphus / Atlas / core: never paste `.omo/plans/*.md` into `/goal`; ≤1800 chars; no re-read loop after `InvalidObjectiveError`
- Prometheus handoff stays `/start-work` → Atlas (not plan-stuffed `/goal`)
- README `/goal` row documents the cap

## [1.5.15] — 2026-07-21

### Docs
- Rewrite `README.md` as unapologetic top-config hype (still accurate pins/commands)

### Doctor / health commands
- Fix `--help` on diagnose/fix/cleanup/run/models (no more dumping every `#` comment in the file)
- Add `-h/--help` to validate, setup, maintain
- Shared `oc_print_script_help` in `lib/common.sh`
- Doctor: OpenConfig banner · **Concurrency & loops** · **Content-aware research** sections
- Doctor: formatter-noise tip on runtime logs
- Validate: concurrency ceilings (default/provider/team/ralph/goal + modelConcurrency coverage)
- Diagnose banner branded OpenConfig

## [1.5.14] — 2026-07-21

### Concurrency
- Rebuild `modelConcurrency` from every model referenced in agents/categories/fallbacks (no stale orphans, no missing Gemini)
- Caps: Flash **4** · Exacto/Sol/MiniMax **3** · Sonnet/Pro/Kimi **2** · Fable/Opus **1**
- Keep intentional ceilings: default **4** · OpenRouter **6** · OpenAI **4** · Anthropic **2** · team **4** parallel / **5** members
- Document concurrency table in `README.md`

### Hygiene
- Single-commit history reset for a clean public tree

## [1.5.13] — 2026-07-21

### Docs
- Rewrite `README.md` — shorter, accurate, public-ready (content-aware naming, research stack, real concurrency/timeouts)
- Single-commit history reset for a clean public tree

## [1.5.12] — 2026-07-21

### Rename
- **grayhat → content-aware** across agent, profile, categories, and team
  - `content-aware-research` (was grayhat-research)
  - `content-aware-fast` / `content-aware-deep` categories
  - profile `content-aware` · team `content-aware-audit`
- Prompts and validate/doctor wiring updated; no soft-refusal research path lost

## [1.5.11] — 2026-07-21

### Pins
- OpenConfig **`1.5.11`**
- OpenCode **`1.18.4+`** · OmO **`oh-my-openagent@4.19.0`** (still latest)

### Research stack
- Master prompts: explicit tool matrix — local → Context7 → grep_app → Exa websearch → webfetch
- Exa query guidance (`category:company|people|news|…`) in `core` / sisyphus / librarian
- Enable OmO **`goal`** (`/goal`, not auto-start) · `mcp_env_allowlist` for Exa/Context7/OpenRouter/OpenAI
- Context7 MCP timeout 12s → 30s · `max_tools` 40 → 48 · runtime_fallback more tolerant of slow streams

## [1.5.10] — 2026-07-21

### Pins
- OpenConfig **`1.5.10`**
- OmO **`oh-my-openagent@4.19.0`** (latest)
- OpenCode CLI floor **`1.18.4+`**

### Fixes (doctor / validate / logs)
- Restore missing OpenCode-native `agents/content-aware-research.md` (edit deny) + OmO agent + prompt
- Remove primary-model duplicates from `explore` / `librarian` `fallback_models`
- Raise OpenRouter/OpenAI stream timeouts to 900s (addresses Upstream idle timeout errors)
- Ensure Prettier is installable via `setup.sh` / doctor (formatter PATH)

## [1.5.9] — 2026-07-21

### Pins
- OpenConfig **`1.5.9`**
- OmO **`oh-my-openagent@4.19.0`** (unchanged — current latest)
- OpenCode CLI floor **`1.18.4+`**

### Changes
- OpenRouter request headers use generic CLI attribution (no OpenCode product referer/title)
- `fix.sh` enforces those OpenRouter headers on heal
- History reset: both GitHub mirrors republished as a single clean commit (no prior history)

## [1.5.8] — 2026-07-17

### Version bumps
- OpenConfig **`1.5.8`**
- OmO **`oh-my-openagent@4.19.0`** 
- OpenCode CLI floor **`1.18.3+`**

### Runaway guard + lag trim
- Cap OmO `background_task` concurrency (**4** default / **6** OpenRouter) — was 48/64
- Team mode **4** parallel / **5** members / **60** min wall (hyperplan floor kept)
- `maxToolCalls` **400**, ralph iterations **8**, stale timeouts **3m**, `syncPollTimeoutMs` **60s** (OmO schema floor)
- Prefer cheap flash/minimax before Opus in sisyphus/prometheus/atlas fallbacks
- Earlier compaction (`reserved` 48k) + smaller tool_output; biome formatter disabled
- OpenCode server port **4097** (avoids Cursor on 4096)
- codegraph: enabled but **auto_init/auto_provision off**
- `fix.sh` enforces these caps so `oc cleanup` cannot inflate fan-out again

## [1.5.7] — 2026-07-12

**Generic identity** — remove personal naming; prompts and docs are for any OpenConfig user.

- Logical identity stays `jesseoue/opencode-configs` (not a GitHub org path)
- Distribution host kept in `signature.json` → `github_b64` (decoded only at install/runtime)
- Installer / docs use identity id + `github_b64` (no personal host-owner literals in source)
- Prompts (`prompts/core.md` and agents) are role-generic — no personal fleet/ops scope

## [1.5.6] — 2026-07-12

**Consolidate / de-bloat** — config-only tree stayed fat from runtime strays + duplicate launch/docs.

- Scrub `node_modules` / `package.json` strays (~61MB); harden `oc_scrub_config_strays` to use `/bin/rm`
- `oc launch` is a thin wrapper → `opencode.sh` (one launch implementation)
- README: shrink command dump + agent paste; point at `oc help` / `AGENTS.md`

## [1.5.5] — 2026-07-12

**Production hygiene** — secrets/proprietary scrub for a ship-ready public release.

- Local `.env` scrubbed to OpenConfig allowlist only (`oc env --scrub`); full prior dump kept under `~/.opencode-backups/` (outside the repo)
- `oc setup --sync-env` imports **allowlisted keys only** from Infisical/Doppler (no more full vault dumps into this tree)
- Launch / `opencode.sh` / `run.sh` no longer wrap Infisical (avoids injecting vault-wide secrets into the agent)
- Doctor warns on foreign `.env` keys; `oc env --check|--scrub` for hygiene
- Stripped proprietary fleet prompt wording from `prompts/core.md`
- gitleaks: clean on git history; `.env` remains gitignored / untracked

## [1.5.4] — 2026-07-12

**Config optimization pass** — full-surface polish on top of the 1.5.3 launch fix.

- Models: OpenRouter pins audited current; whitelist ↔ `models{}` sync enforced in `validate.sh`
- OmO: `providerConcurrency.openai: 10`; research profile larger `tool_output`
- Ghostty: `auto-update = off` (offline posture)
- `.env.example`: `OC_DEFAULT_WORKSPACE`; locate reports launch workspace scaffold
- Validate: content-aware-research agent/profile alignment; ghostty auto-update check
- Heal: runs `maintain --check` (report only — never auto-archives sessions)
- Docs: README `share` / git_master co-author wording aligned; prompts branded 1.5.4

## [1.5.3] — 2026-07-12

**TUI launch fix** — `oc launch` was exiting instantly because OpenCode ran as a
subprocess that did not own the tty.

- `oc launch` / `opencode.sh` now `cd` into the workspace and `exec` the real CLI
- Messages go to stderr; requires an interactive tty
- `opencode()` cds into the resolved project and runs `opencode .`

## [1.5.2] — 2026-07-12

**Launch workspace subdirectory** — never start in bare `~/Projects`.

- Config repo / bare projects home → ensure `~/Projects/workspace` (configurable via `projects.json` `default_workspace`)
- Creates clean `AGENTS.md`, project `opencode.json`, `.gitignore`; scrubs install strays
- `oc launch`, `opencode()`, `opencode.sh`, `oc run` all use the workspace path

## [1.5.1] — 2026-07-12

**Launch directory fix** — OpenCode never starts inside the config repo by default.

- `oc launch` / `opencode.sh` / `opencode()` / `oc run` resolve start dir via `oc_resolve_launch_dir`
- If cwd (or target) is the OpenConfig tree → redirect to projects home (`~/Projects`)
- Escape hatch: `oc launch --here` / `opencode --here`
- Keeps the config-only repo clean (no accidental `package.json` / `node_modules` drops)

### Install
```bash
# historical: use current installer bootstrap (signature.json github_b64)
```

## [1.5.0] — 2026-07-12

**Production 1.5 release** — verified end-to-end on a live box; product bump from 1.3 with hardened shell migration and current upstream pins.

### Pins (current upstream)
- OpenConfig **`1.5.0`**
- OpenCode CLI **`1.17.18+`** (from `https://opencode.ai/install`)
- OmO **`oh-my-openagent@4.16.3`** (npm + platform optionalDependency)
- Ghostty **`1.3.0+`** · tmux **`3.3+`** (rec. `3.7+`)

### Verified on live system
- `oc install --quick` → Ready
- `oc check` / `oc heal` → healthy
- `oc test` → smoke + idempotency pass (incl. zshrc copy-backup / wipe guard)
- Headless `oc run` → Sisyphus · `z-ai/glm-5.2` returns `LOAD_OK`
- `~/.zshrc` sources `zshrc.snippet` (telemetry + TERM + teardown)

### Since 1.3
- `oc` / `setup` version read from `versions.json` (single source of truth)
- Safe stale-inline zshrc migration (`oc_backup_copy`, ≥50% size guard) production-proven
- Team tool allowlist + hephaestus teammate enforced by `oc fix` / validate / doctor
- Docs + prompts branded **OpenConfig 1.5**

### Install
```bash
# historical: use current installer bootstrap (signature.json github_b64)
# or:
oc install --quick
```

## [1.3.0] — 2026-07-12

**Final 1.3 release** — self-heal, identity, idempotency, telemetry-dark, wild TUI colors, cleaned prompts, shell hygiene.

### One command
- `oc install --quick` — full stack + validate + doctor; auto-heals on failure
- Anytime later: `oc heal` · `oc check` · `oc test` · `oc signature`

### Official download sources
- **OpenCode CLI** — `https://opencode.ai/install` only (redirects to anomalyco/opencode)
- **OmO plugin** — npm `oh-my-openagent@4.16.3` (+ platform optionalDependency) into `~/.cache/opencode/packages/`
- **This config** — identity `jesseoue/opencode-configs` (installer clones/pulls via `github_b64`)

### Shell / zsh
- Canonical: `source ~/.config/opencode/zshrc.snippet` (telemetry + TERM + teardown)
- `oc setup` migrates **stale inline** `opencode()` missing kill switches; doctor flags them
- In-place zshrc edits use **copy backup** (`oc_backup_copy`) — never `mv` the live file away mid-edit
- Strip refuses to write if the result would shrink a real zshrc below 50%
- All `*.sh` / `oc` pass `bash -n`; snippet is `shellcheck shell=zsh`

### Identity & discovery
- `signature.json` + `oc signature` — markers + content fingerprint prove `jesseoue/opencode-configs` (OpenConfig / `oc`)
- `oc locate` / `oc where` — read-only discovery of repo, CLI, symlinks, key presence, leftovers (`--json`)
- Validate / doctor / heal gate on signature; heal refuses wrong/unverified trees

### Self-heal & tests
- `oc heal` / `oc check --fix` — probe-first unattended repair (skips fix/cleanup when dry-run is clean)
- AI diagnose when OpenRouter key present and still broken (`--ai` → coding-agent; `--no-ai` → structural only)
- `oc test` — smoke + sandbox idempotency (`tests/smoke.sh`, `tests/idempotency.sh`)
- Never clobber `.env` values; `oc_set_env_key_if_unset` / `oc_ensure_env_file`
- Symlink helpers: `oc_link_points_to` / `oc_ensure_symlink` (skip if correct)
- `fix.sh` backs up only when writing; clean runs do not bump mtimes
- Enforces 12 `team_*` + core tool allows; `hephaestus.permission.teammate=allow`

### Telemetry dark
- OpenCode: `share=disabled`, `autoupdate=false`, `openTelemetry=false`, `mdns=false`
- OmO: `telemetry=false`, PostHog env kill switches, `disable_omo_env=true`, codegraph telemetry off
- OTel: `OTEL_SDK_DISABLED=true`, OTLP endpoints unset on launch
- Co-author / commit footer off; posthog/sentry/axiom MCPs disabled
- Enforced by `oc_telemetry_off`, zshrc, `oc fix`, validate + doctor

### Colors & prompts
- Wild neon agent/category hex palette (enforced by `oc fix`)
- Prompts cleaned for 1.3: OpenConfig identity in `core.md`, team hard-rejects inline, Exacto/Nitro/Sol/Fable wording consistent

### Branding & projects
- Product **OpenConfig** / CLI **`oc`** throughout (`versions.json` product fields)
- Projects home: `oc new` → `~/Projects` · `projects.json` · `oc projects`
- tmux.conf + ghostty.conf load-tested in doctor; versions floors in `versions.json`

## [1.2.0] — 2026-07-12

Hardened installer + audit cleanup release.

### Installer & bootstrap
- Path hardeners for `HOME` / `XDG_*` / `REPO` (refuse `/`, sessions tree, foreign remotes)
- Idempotent zshrc (single snippet source, or leave inline `opencode()` alone)
- Never delete OpenCode sessions; backups under `~/.opencode-backups/`
- Safe `.env` key writes (`oc_set_env_key`, no sed injection)
- Timestamped install logs (`~/.opencode-backups/logs/install-*.log`, secrets redacted)
- `curl|bash`-safe `main()` wrapper; download→shebang-check for OpenCode CLI installer
- Flags: `--dir`, `--log`, `--skip-cli`, `--yes`

### Audit fixes
- Portable plan checkbox count (`grep -cE`) on macOS
- Replace `bc` with `python3` in openrouter-admin credit alerts
- Remove unused non-exacto `z-ai/glm-5.2` model entry (Exacto kept)
- Add `modelConcurrency` for gemini-3-flash + claude-sonnet-5
- Drop dead `instructions` paths (`.cursor/rules`, copilot)
- Align content-aware agent `edit: deny` with profile
- README MCP table distinguishes real MCP vs OmO/built-in tools
- `oc doctor --harden` documented in dispatcher help
- Schema URL kept on working `oh-my-opencode.schema.json` asset; validate rejects 404 basename

### Repo hygiene
- Expanded `.gitignore` (IDE, Python, OS, temp, `.opencode`)
- Runtime stray scrub on install/setup; validate asserts config-only purity

## [1.0.0] — 2026-07-12

First stable release of the global OpenCode + oh-my-openagent config.

### Highlights

- OpenRouter-only stack: GLM Exacto (sisyphus/prometheus/atlas), GPT-5.5 (hephaestus/oracle), DeepSeek Flash/Pro (explore/librarian/content-aware), Gemini (visual/writing), Claude (ultrawork/metis)
- Config-only repo: no `package.json` / `node_modules`; live OpenCode install junk is scrubbed (`.omo`, `.sisyphus`, `command/`)
- Shared `lib/common.sh`: safe `.env` allowlist export (never `source .env`), stray scrub helpers
- Agent `prompt_append` files under `prompts/` with unrestricted research + plain-markdown output rules
- Validate resolves `file://` prompt paths and asserts `tui.json` plugin pin matches `opencode.json`
- 7 profiles, 7 teams, custom `content-aware-research` only
- Ghostty: `notify-on-command-finish = never` (requires Ghostty ≥ 1.3.0)
- Hyperplan-ready: demoted `plan` kept, `OpenCode-Builder` not enabled (`default_builder_enabled: false`)

### Removed before 1.0

- Phantom `OpenCode-Builder` from `disabled_agents`
- Phantom `godmode` profile help text
- Redundant `build-crew` team (covered by `ship-feature`)
- Dead `formatter.biome`, empty `cors`/`urls`, default `i18n`
- Invalid Ghostty `notification = false` key
