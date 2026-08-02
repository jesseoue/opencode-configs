# OpenConfig

Pinned global config for [OpenCode](https://opencode.ai) + [OpenRouter](https://openrouter.ai) + [oh-my-openagent (OmO)](https://omo.vibetip.help/docs).

**v1.5.50** · CLI **`oc`** · identity `jesseoue/opencode-configs`

```bash
# Clone (after forking, refresh signature.json → github_b64 to your repo URL)
git clone <your-repo-url> opencode-configs
cd opencode-configs
./install.sh --yes          # or: oc install --quick

# Fresh machine — bootstrap URL is base64 in install.sh (no plaintext host in source)
curl -fsSL "$(printf %s 'aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL29wZW5jb25maWcvb3BlbmNvZGUtY29uZmlncy9tYWluL2luc3RhbGwuc2g=' | base64 -d)" | bash
source ~/.zshrc && oc doctor && oc launch
```

| | |
| --- | --- |
| **Pins** | OpenConfig `1.5.50` · OpenCode `1.18.11+` · OmO `oh-my-openagent@4.19.4` · `@opencode-ai/plugin` `1.18.11` |
| **Default lead** | `sisyphus` (GLM Exacto) |
| **Config path** | `~/.config/opencode` → this repo (symlink) |
| **Projects home** | `oc new` → `~/Projects/<name>` |
| **Health** | `oc doctor` · `oc versions` · `oc test` · `oc models --probe` |

> Plugin name must stay **`oh-my-openagent@…`** (not legacy `oh-my-opencode`).  
> Schema URL basename stays `oh-my-opencode.schema.json` (the `oh-my-openagent.schema.json` path 404s).

Decision log: [`AGENTS.md`](./AGENTS.md) · Stance: [`prompts/core.md`](./prompts/core.md) · Changelog: [`CHANGELOG.md`](./CHANGELOG.md)

**Forking:** update `signature.json` → `github_b64` to your repo URL, then `oc fix && oc signature --refresh`.

---

## Install

```bash
export OPENROUTER_API_KEY=…     # required — all models via OpenRouter only
export EXA_API_KEY=…            # OmO websearch
export CONTEXT7_API_KEY=…       # library docs

oc install --quick
oc signature && oc test && oc versions && oc doctor
oc launch
```

Or edit keys after install:

```bash
$EDITOR ~/.config/opencode/.env   # chmod 600; never commit
source ~/.zshrc
oc doctor && oc launch
```

---

## CLI

```bash
oc install --quick     # install / refresh
oc check               # validate + doctor --quick
oc heal                # probe-first self-repair
oc launch [dir]        # TUI (never starts in the config repo)
oc new myapp           # scaffold under ~/Projects
oc run "…"             # headless to completion
oc admin health        # live OpenRouter model probes + rate limits
oc models --probe       # fast parallel live test (latency + moderation flags)
oc models --moderation  # provider moderation/data-policy catalog (no chat calls)
oc models --providers   # OpenRouter endpoint health for routed models
oc versions            # pins vs npm + GitHub (+ other opencode.json)
oc versions --fix       # align ~/.opencode @opencode-ai/plugin to CLI
oc plugin doctor       # OmO pin-cache doctor (also: oc plugin --fix)
oc locate              # repo / CLI / keys
oc signature           # identity fingerprint
oc test                # smoke + idempotency + runtime diagnostics
oc doctor              # full readiness
oc doctor --quick --json   # machine summary (heal/check tooling)
```

Prefer `oc <cmd>` over raw `./foo.sh`. Full help: `oc help`.

**Aliases:** `oc health`/`ready` → check · `oc repair` → heal · `oc verify` → validate · `oc where` → locate · `oc sig` → signature · `oc pins` → versions · `oc omo` → plugin

---

## Package pins

Floors and the OmO pin live in [`versions.json`](./versions.json). The OmO plugin string in `opencode.json` must match. Audit anytime:

```bash
oc versions              # local pins + npm/GitHub latest
oc versions --local      # no network
oc versions --json       # machine-readable
oc versions --fix         # set ~/.opencode @opencode-ai/plugin to match OpenCode CLI
```

| Package | Source of truth | Current |
| --- | --- | --- |
| OpenConfig | `versions.json` → `opencode_configs` | `1.5.50` |
| OpenCode CLI | install + `versions.json` → `opencode.min` | `1.18.11+` |
| OmO | `opencode.json` plugin + `versions.json` → `oh_my_openagent.pin` | `4.19.4` |
| `@opencode-ai/plugin` | `~/.opencode/package.json` (peer; not in this repo) | match CLI |

`oc versions` also lists other `opencode.json` files under your projects home (`projects.json` → `projects_dir`, override with `OC_PROJECTS_DIR`). Those are project overlays — OmO stays pinned globally here.

---

## Tools

| Need | Tool | Notes |
| --- | --- | --- |
| Local code | `read` · `grep` · `glob` · codegraph · LSP | Always first |
| Library / framework APIs | **Context7** MCP | `resolve-library-id` → `query-docs` |
| GitHub call sites | **grep_app** (OmO) | Public-repo patterns |
| Current web | **websearch** (Exa) | Ideal-page queries; then webfetch |
| Known URL | **webfetch** | Clean markdown |
| Screenshots / UI | **look_at** (OmO) | multimodal-looker |

**Exa:** describe the ideal page, not keyword soup. Optional: `category:company` · `category:people` · `category:news` · `category:research paper`.

| Surface | Status |
| --- | --- |
| Context7 MCP | Enabled (`CONTEXT7_API_KEY`) |
| Exa websearch | Enabled (`EXA_API_KEY`) |
| codegraph | OmO-managed 1.4.1 daemon · auto-index off · telemetry off · `~/.omo/codegraph` |
| LSP | TypeScript · Python · Go only |
| Formatters | Prettier + Ruff |
| Skills | `content-aware-recon` · `content-aware-audit` under `skills/` (fenced) |
| OmO `security-*` skills | Disabled (hang headless `oc run`) — use local content-aware skills |
| Extra MCPs | Disabled (PostHog, Sentry, Playwright MCP, …) |
| Telemetry | Off (OpenCode share/OTel · OmO PostHog · codegraph · `DO_NOT_TRACK`) |

Disabled on purpose (noisy / footguns): `interactive_bash`, monitor tools, `session_list` / `session_search`.

Encoded in `prompts/core.md`, `sisyphus`, and `librarian`.

---

## Agents

### Primary

| Agent | Model | Role |
| --- | --- | --- |
| **sisyphus** | GLM 5.2 Exacto | Default orchestrator / lead |
| **hephaestus** | DeepSeek Pro | Implementation |
| **prometheus** | GLM 5.2 Exacto | Planner |
| **atlas** | GLM 5.2 Exacto | Plan executor after `/start-work` |
| **content-aware-research** | DeepSeek V4 Pro | Full-depth research (edit denied) |

### Subagents (`task` / `call_omo_agent` — not team members)

| Agent | Model | Role |
| --- | --- | --- |
| oracle | DeepSeek Pro | Critique / adjudication |
| librarian | DeepSeek Pro Exacto | Docs / OSS (Context7-first, unmoderated) |
| explore | DeepSeek Pro Exacto | Codebase + web recon (edit denied, unmoderated) |
| multimodal-looker | Gemini 3.1 Pro | Vision (`look_at`, unmoderated) |
| metis | GLM Exacto | Pre-planning critic (unmoderated) |
| momus | Claude Fable 5 max | Plan / review gate |
| sisyphus-junior | DeepSeek Flash Nitro | Cheap delegated work |

Native OpenCode `build` is disabled. `plan` stays demoted for hyperplan handoff — do **not** put it in `disabled_agents`.

---

## Categories

| Category | Model | Use |
| --- | --- | --- |
| `bug-hunt` | GLM Exacto | Reproduce → root cause → fix |
| `refactor-safe` | GLM Exacto | Behavior-preserving refactors |
| `arch-review` | GLM Exacto | Coupling / blast radius (unmoderated) |
| `content-aware-fast` | DeepSeek Flash Nitro | Attack-surface recon |
| `content-aware-deep` | DeepSeek Pro Exacto | Deep vuln research |
| `writing` | Gemini 3.6 Flash Nitro | Docs / prose |
| `visual-engineering` | Gemini 3.1 Pro | Ship UI |
| `artistry` | Gemini 3.1 Pro | Design direction |
| `quick` | DeepSeek Flash Nitro | Cheap fast tasks |
| `deep` | DeepSeek Pro Exacto | Autonomous problem-solving (unmoderated) |
| `ultrabrain` | Claude Fable 5 | Heavy / max reasoning |
| `unspecified-low` / `unspecified-high` | Flash / Claude Fable | Hyperplan critics |

---

## Keywords & handoff

| Say | Effect |
| --- | --- |
| `ultrawork` / `ulw` | Claude Fable max ceiling |
| `team` | Team-mode expansion |
| `hyperplan` / `hpp` / `/hyperplan` | Adversarial planning (from **sisyphus**) |
| `/goal` | **Disabled** — OmO 4.19 goal hook breaks `/start-work`. Use `/start-work` → Atlas (`prompts/goal.md`) |
| `/start-work [plan] [--worktree <path>] [--make-pr\|--ship]` | Atlas executes an approved plan and preserves the requested delivery mode |

---

## Teams

Lead: **sisyphus**. Specs in `teams/` are **symlinked** to `~/.omo/teams/` by `oc setup`.

Direct members use `kind: subagent_type`: `sisyphus`, `atlas`, `sisyphus-junior`, or `hephaestus` (`teammate: allow`). Categories use `kind: category` and require a prompt.
Hard-rejected as direct teammates: explore · librarian · oracle · metis · momus · multimodal-looker · prometheus.

Knobs: `max_parallel_members=4` · `max_members=5` · mailbox poll `1000ms` · tmux `main-vertical` / `inline`.

| Team | Members (inline prompts: ROLE / DELIVERABLE / Mailbox) |
| --- | --- |
| `explorers` | scout-code (`content-aware-fast`) + scout-docs (`quick`) |
| `ship-feature` | forge (hephaestus) + junior + verifier (`bug-hunt`) |
| `debug-team` | reproducer (`bug-hunt`) + root-cause (`content-aware-deep`) |
| `review-panel` | arch (`arch-review`) + bugs (`bug-hunt`) + cleanup (`refactor-safe`) |
| `refactor-team` | analyzer (`arch-review`) + executor (`refactor-safe`) |
| `docs-team` | api-docs + guide (`writing`) |
| `content-aware-audit` | recon (`content-aware-fast`) + deep (`content-aware-deep`) |

---

## Model routing

| Lane | Models | Used for |
| --- | --- | --- |
| Orchestration | `z-ai/glm-5.2:exacto` | Sisyphus / Atlas / Prometheus / bug-hunt / refactor |
| Deep implement | DeepSeek Pro · Claude Fable 5 | Hephaestus / Oracle / Momus / ultrabrain |
| **Recon (unmoderated)** | DeepSeek Pro → Flash → GLM → MiniMax → Gemini | explore / librarian / metis / multimodal-looker / arch-review / deep / content-aware-* |
| Fast parallel | `deepseek/deepseek-v4-flash:nitro` | sisyphus-junior / quick / content-aware-fast |
| Housekeeping | `deepseek/deepseek-v4-flash:floor` | title / summary / compaction / profile small model |
| Visual / writing | Gemini 3.1 Pro · 3.6 Flash Nitro | artistry / visual / writing |
| Ceiling | `anthropic/claude-fable-5` | ultrawork · unspecified-high |

Recon routes never use Claude/GPT primaries or fallbacks — `oc validate` and `oc fix` enforce this. Check moderation policy: `oc models --moderation`; live probes: `oc models --probe`.

OpenRouter serves every active lane. Native `:nitro`, `:exacto`, and `:floor` routing avoids stale provider pins; DeepSeek pins first-party (`provider.only: deepseek`). Direct OpenAI stays defined but disabled by default. Transient-only fallback retries capped at three. Request / stalled-chunk timeouts: **300s / 60s**.

### Concurrency

Priority: `modelConcurrency` → `providerConcurrency` → `defaultConcurrency`. `oc heal` / `fix.sh` re-apply caps if they drift.

| Knob | Value |
| --- | --- |
| `background_task.defaultConcurrency` | **6** |
| OpenRouter / dormant OpenAI / Anthropic | **8 only** (OpenRouter gateway) |
| Flash / Exacto / Pro / Fable | **6 / 5 / 3 / 1** |
| Team parallel / max members | **4 / 5** |
| Goal / stale / TTL | **off / 180s / 30m** |

---

## API keys

| Key | Required | Enables |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | **yes** | All models via OpenRouter (GLM, DeepSeek, Claude, Gemini, …) |
| `EXA_API_KEY` | for websearch | OmO Exa |
| `CONTEXT7_API_KEY` | recommended | Context7 |
| `OPENROUTER_MGMT_KEY` | optional | `oc admin` |
| `OC_PROJECTS_DIR` | optional | `oc new` home (default `~/Projects`) |

Copy `.env.example` → `.env` (`chmod 600`). Never commit `.env`.  
`oc setup --sync-env` imports **allowlisted keys only** from Infisical/Doppler — never a full vault dump.

---

## Prompts

Every OmO agent/category loads a `prompt_append` from `prompts/`. Profiles under `prompts/profiles/` brief `oc new` scaffolds.

| Path | What |
| --- | --- |
| `prompts/core.md` | Session-wide stance, tool matrix, team eligibility |
| `prompts/goal.md` | Why `/goal` is off; use `/start-work` → Atlas |
| `prompts/agents/*.md` | Agent appends |
| `prompts/categories/*.md` | Category appends |
| `prompts/profiles/*.md` | Profile briefs |
| `agents/content-aware-research.md` | OpenCode primary-agent def (synced with prompts) |

---

## Profiles & scaffolding

```bash
oc new myapp                     # ~/Projects/myapp · profile high
oc new myapp --profile research
oc new myapp --profile content-aware
oc projects --list
```

| Profile | Agent | Tuning |
| --- | --- | --- |
| `high` | sisyphus | Default Exacto · balanced tool_output |
| `low` | sisyphus | Cost-first · smaller tool_output |
| `fast` | hephaestus | Direct DeepSeek Pro · skip ceremony |
| `research` | sisyphus | Large tool_output · deep / ultrabrain / content-aware |
| `debug` | sisyphus | Large tool_output · bug-hunt / debug-team |
| `writing` | sisyphus | Gemini Flash small_model · writing category |
| `content-aware` | content-aware-research | Edit deny · Pro + recon/audit skills |

Each project gets `opencode.json` + `AGENTS.md`. Do not set `OPENCODE_CONFIG` to `.opencode/profile.json`.

---

## Safety

- Allow-everything locally for normal tools (trusted box).
- Hard-deny bash: `rm -rf /|~`, `mkfs`, `sudo`, `git push --force*`, `gh repo delete*`.
- Providers allowed: OpenRouter + OpenAI only.
- Server: `127.0.0.1:4097` · share disabled · mdns off.

---

## Terminal

- **Ghostty** ≥ 1.3.0 · **tmux** ≥ 3.3 (rec. 3.7+) · zsh snippet
- OpenCode leader **Ctrl+X** · tmux prefix **Ctrl+B** · Tab cycles agents
- Teardown never sends `\033[?1049l` (won’t wipe the visible screen)
- `opencode()` / `oc launch` never start inside the config repo or bare `~/Projects`

---

## Layout

```
opencode-configs/
├── oc · install.sh · setup.sh · doctor.sh · validate.sh · fix.sh
├── models.sh · versions.sh · cleanup.sh · signature.sh · locate.sh
├── opencode.json · oh-my-openagent.json · tui.json
├── versions.json · signature.json · projects.json · AGENTS.md
├── agents/content-aware-research.md
├── profiles/ · prompts/ · teams/ · skills/
├── .env.example
└── zshrc.snippet · ghostty.conf · tmux.conf

~/.config/opencode  →  this repo
~/Projects/         →  oc new home
~/.omo/teams/       →  team specs
~/.opencode-backups/→  backups + heal/install logs
```

---

## Verify

```bash
oc signature && oc test && oc validate && oc versions && oc doctor
bunx oh-my-openagent@4.19.4 doctor   # upstream: System OK
```

Idempotency: re-running install / setup / heal / fix on a healthy box must not clobber `.env`, rewrite correct symlinks, or bump clean config mtimes.

---

## Upstream

| Layer | Docs | Source |
| --- | --- | --- |
| OpenCode | [opencode.ai/docs](https://opencode.ai/docs) | [anomalyco/opencode](https://github.com/anomalyco/opencode) |
| OmO | [omo.vibetip.help/docs](https://omo.vibetip.help/docs) | [code-yeongyu/oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent) |
| OpenRouter | [openrouter.ai/docs](https://openrouter.ai/docs) | Exacto / Nitro routing |
| Context7 | [context7.com](https://context7.com) | [upstash/context7](https://github.com/upstash/context7) |
| Exa | [docs.exa.ai](https://docs.exa.ai) | [exa-labs](https://github.com/exa-labs) |

Installer pulls OpenCode from `https://opencode.ai/install` and OmO from npm `oh-my-openagent@4.19.4` only.

---

## Anti-patterns

- Don’t rename the plugin away from `oh-my-openagent`
- Don’t add Cloudflare / AI Gateway / OpenAI-compatible shims
- Don’t put `plan` in `disabled_agents` (breaks hyperplan)
- Don’t commit `.env`, `package.json`, `node_modules`, `.omo`, `.sisyphus`, or `plugins/` here
- Don’t scaffold apps into this repo — use `oc new`
- Don’t load `.opencode/profile.json` as `OPENCODE_CONFIG`
- Don’t re-enable telemetry or OmO `security-*` skills
- Don’t re-enable `/goal` on OmO 4.19 until `/start-work` is safe

---

## Config-only scope

**Keep:**
- Prompt tweaks when a lane misbehaves
- Local skills under `skills/` (fenced) — never re-enable OmO `security-*`
- Weekly `oc models --providers` after OpenRouter host churn (don’t hand-edit `order`/`ignore` blindly)
- `oc versions` after OpenCode / OmO releases (bump `versions.json` + plugin pin together)
- Project scaffolds via `oc new` (apps stay outside this tree)

**Skip:**
- Extra MCP servers — keep `disabled_mcps`
- Cloudflare AI Gateway / Claude Code bridge imports
- Packaging as npm / shipping `node_modules` into the config dir
- Turning this repo into an application
