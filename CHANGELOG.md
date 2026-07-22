# Changelog

All notable changes to **OpenConfig** (`opencode-configs` / `oc`) are documented here.

## [1.5.30] — 2026-07-21

### Package pin audit
- Add `oc versions` (`versions.sh`) — compare OpenCode / OmO / `@opencode-ai/plugin` pins to npm + GitHub
- Scan other `opencode.json` under `~/Projects` and `/Users/Shared` (project overlays; OmO stays global)
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
- `zshrc.snippet`: remove `/Users/Shared/lm-agents` denylist + `/Users/Shared/test-speed` redirect; resolve workspace via `OC_*` / `projects.json` / `~/Projects` only
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

- Logical identity stays `openconfig/opencode-configs` (not a GitHub org path)
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
- Headless `oc run` → Sisyphus · `z-ai/glm-5.2-exacto` returns `LOAD_OK`
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
- **This config** — identity `openconfig/opencode-configs` (installer clones/pulls via `github_b64`)

### Shell / zsh
- Canonical: `source ~/.config/opencode/zshrc.snippet` (telemetry + TERM + teardown)
- `oc setup` migrates **stale inline** `opencode()` missing kill switches; doctor flags them
- In-place zshrc edits use **copy backup** (`oc_backup_copy`) — never `mv` the live file away mid-edit
- Strip refuses to write if the result would shrink a real zshrc below 50%
- All `*.sh` / `oc` pass `bash -n`; snippet is `shellcheck shell=zsh`

### Identity & discovery
- `signature.json` + `oc signature` — markers + content fingerprint prove `openconfig/opencode-configs` (OpenConfig / `oc`)
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
