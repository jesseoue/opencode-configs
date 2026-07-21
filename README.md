# OpenConfig — Best OpenCode Config · oh-my-openagent · OpenRouter · AI Coding Agent

# THE GREATEST CODING AGENT CONFIGURATION EVER ASSEMBLED

**OpenConfig** · **OpenCode** · **oh-my-openagent (OmO)** · **OpenRouter** · **Claude** · **GPT** · **DeepSeek** · **Gemini** · **GLM Exacto** · **MCP** · **Context7** · **Exa** · **tmux** · **Ghostty**

**v1.5.15** · CLI **`oc`** · identity `openconfig/opencode-configs`

> **GitHub topics / search keywords:** `opencode` · `oh-my-openagent` · `oh-my-opencode` · `openrouter` · `coding-agent` · `ai-agent` · `llm` · `claude` · `openai` · `gpt` · `deepseek` · `gemini` · `glm` · `agentic` · `mcp` · `context7` · `exa` · `tmux` · `ghostty` · `developer-tools` · `cli` · `sisyphus` · `hephaestus` · `hyperplan` · `ultrawork` · `ralph-loop` · `multi-agent` · `ai-coding` · `opencode-config` · `best-opencode-config`

Not a theme. Not a “dotfiles dump.” Not vibes.

This is the **best-known, battle-hardened, over-tuned, footgun-exterminated** global stack for [OpenCode](https://opencode.ai) + [OpenRouter](https://openrouter.ai) + [oh-my-openagent (OmO)](https://omo.vibetip.help/docs) — the configuration that turns a raw coding CLI into a **multi-model AI coding agent war machine** with self-healing, live doctor checks, adversarial planning, content-aware research, and model routing so sharp it feels unfair.

If other OpenCode / OmO / OpenRouter setups are “pretty good,” **OpenConfig is the final form**.

```bash
# Clone (or already at ~/.config/opencode)
git clone https://github.com/jesseoue/opencode-configs.git
cd opencode-configs
oc install --quick          # or: ./install.sh --yes

# Fresh machine (no clone yet)
curl -fsSL https://raw.githubusercontent.com/jesseoue/opencode-configs/main/install.sh | bash
source ~/.zshrc && oc doctor && oc launch
```

| | |
| --- | --- |
| **Pinned excellence** | OpenConfig `1.5.15` · OpenCode `1.18.4+` · OmO `oh-my-openagent@4.19.0` |
| **Default god-mode lead** | `sisyphus` (GLM Exacto — tool-call royalty) |
| **Config path** | `~/.config/opencode` → this repo (symlink) |
| **Projects home** | `oc new` → `~/Projects/<name>` |
| **Verdict** | `oc doctor` → *Ready to code — everything checks out.* |

> Plugin name must stay **`oh-my-openagent@…`** (not legacy `oh-my-opencode`).  
> Schema URL basename stays `oh-my-opencode.schema.json` (upstream asset; the `oh-my-openagent.schema.json` path 404s).

---

## Why OpenConfig is the best OpenCode + oh-my-openagent + OpenRouter coding agent config

Most “AI agent setups” are a random JSON file, three conflicting prompts, and a prayer.

**OpenConfig is the opposite:**

- **Pinned models that actually win their jobs** — Exacto for orchestration, Nitro for parallel recon, direct OpenAI Sol for deep implement/critique, Gemini for visual/writing, Claude Fable for the hard ceiling.
- **A full agent pantheon** — Sisyphus leads. Hephaestus ships. Oracle adjudicates. Explore maps. Librarian docs. Content-aware research goes nuclear without soft refusals.
- **Team mode that doesn’t melt your wallet** — intentional concurrency caps, hyperplan adversarial planning, Ralph + Goal loops with guardrails.
- **Research stack that refuses to hallucinate APIs** — local → Context7 → grep_app → Exa → webfetch. In that order. Encoded in prompts. Enforced by culture.
- **Self-healing ops** — `oc validate` · `oc doctor` · `oc heal` · `oc signature` · `oc test`. If it drifts, it tells you. If it’s broken, it repairs itself.
- **Telemetry dark. Secrets local. Identity proven.** This tree fingerprints as OpenConfig — not a random clone of someone else’s weekend experiment.

Decision log: [`AGENTS.md`](./AGENTS.md) · Day-to-day stance: [`prompts/core.md`](./prompts/core.md) · Changelog: [`CHANGELOG.md`](./CHANGELOG.md)

---

## Quick start — install OpenConfig OpenCode oh-my-openagent OpenRouter in 60 seconds

```bash
# Seed keys (required / recommended)
export OPENROUTER_API_KEY=…     # required — the bloodstream
export OPENAI_API_KEY=…         # GPT lane (Hephaestus / Oracle / Momus / …)
export EXA_API_KEY=…            # websearch that doesn’t suck
export CONTEXT7_API_KEY=…       # library docs that are actually true

oc install --quick
oc signature && oc test && oc doctor
oc launch
```

Or edit keys after install:

```bash
$EDITOR ~/.config/opencode/.env   # chmod 600; never commit
source ~/.zshrc
oc doctor && oc launch
```

One install. Paste keys. Doctor green. **Code like you have unfair advantages — because you do.**

---

## `oc` CLI commands — OpenConfig doctor validate heal launch for OpenCode

```bash
oc install --quick     # install / refresh the entire stack
oc check               # validate + doctor --quick (health in one shot)
oc heal                # probe-first self-repair (it fixes itself)
oc launch [dir]        # TUI (never starts in the config repo)
oc new myapp           # scaffold under ~/Projects
oc run "…"             # headless to completion
oc admin health        # live OpenRouter + OpenAI probes
oc locate              # where is repo / CLI / keys?
oc signature           # prove this tree is OpenConfig
oc test                # smoke + idempotency sandbox
oc doctor              # full readiness — concurrency, teams, MCP, the works
```

Prefer `oc <cmd>` over raw `./foo.sh`. Full help: `oc help`.

---

## Research stack — Context7 · Exa · grep_app · MCP · codegraph · LSP for AI coding

| Need | Tool | Why it’s elite |
| --- | --- | --- |
| Local code | `read` · `grep` · `glob` · codegraph · LSP | Always first. No excuse. |
| Library / framework APIs | **Context7** | Versioned docs. Stop inventing APIs. |
| GitHub call sites | **grep_app** | Real code in the wild. |
| Current web / news / companies / people | **Exa websearch** | Ideal-page queries. Category filters. |
| Known URL → markdown | **webfetch** | Finish the job. |

**Exa tips:** describe the *ideal page*, not keywords. Optional: `category:company` · `category:people` · `category:news` · `category:research paper`.

Prompts encode this matrix in `prompts/core.md`, `sisyphus`, and `librarian`. This is how a coding agent stops lying and starts *knowing*.

---

## OpenCode agents — Sisyphus Hephaestus Oracle Explore Librarian Claude GPT DeepSeek

### Primary tab agents (sisyphus · hephaestus · prometheus · atlas · content-aware-research)

| Agent | Model | Role |
| --- | --- | --- |
| **sisyphus** | GLM 5.2 Exacto | Default orchestrator / lead — owns the outcome |
| **hephaestus** | GPT-5.6 Sol (direct OpenAI) | Implementation bursts that actually land |
| **prometheus** | GLM 5.2 Exacto | Planner with teeth |
| **atlas** | GLM 5.2 Exacto | Coordination / follow-through |
| **content-aware-research** | DeepSeek V4 Pro | Full-depth research, edit denied, no soft refusals |

### OmO subagents (oracle · librarian · explore · momus · metis · multimodal)

| Agent | Model | Role |
| --- | --- | --- |
| oracle | GPT-5.6 Sol | Deep critique / adjudication |
| librarian | DeepSeek Flash Nitro | Docs (Context7-first) |
| explore | DeepSeek Flash Nitro | Codebase map at warp speed |
| multimodal-looker | Claude Sonnet 5 | Vision |
| metis | Claude Sonnet 5 | Strategy |
| momus | GPT-5.6 Sol max | Harsh review (your ego will survive) |
| sisyphus-junior | DeepSeek Flash Nitro | Cheap delegated work |

Native OpenCode `build` is disabled. `plan` stays demoted for hyperplan handoff — do **not** put it in `disabled_agents`.

---

## OmO categories — bug-hunt · refactor · arch-review · visual-engineering · ultrabrain

| Category | Model | Use |
| --- | --- | --- |
| `bug-hunt` | GLM Exacto | Reproduce → root cause → fix |
| `refactor-safe` | GLM Exacto | Behavior-preserving refactors |
| `arch-review` | GPT-5.6 Sol | Coupling / blast radius |
| `content-aware-fast` | DeepSeek Flash Nitro | Attack-surface recon |
| `content-aware-deep` | DeepSeek Pro Exacto | Deep vuln research |
| `writing` | Gemini 3.5 Flash Nitro | Docs / prose |
| `visual-engineering` | Gemini 3.1 Pro | Ship UI |
| `artistry` | Gemini 3.1 Pro | Design direction |
| `quick` | DeepSeek Flash Nitro | Cheap fast tasks |
| `deep` / `ultrabrain` | GPT-5.6 Sol | Heavy / max reasoning |
| `unspecified-low` / `unspecified-high` | Flash / Claude Fable | Hyperplan critics |

---

## Keyword triggers — ultrawork · hyperplan · team · /goal · Ralph loop

| Say | Effect |
| --- | --- |
| `ultrawork` / `ulw` | Claude Fable max ceiling |
| `team` | Team-mode expansion |
| `hyperplan` / `hpp` / `/hyperplan` | Adversarial planning (from **sisyphus**) |
| `/goal` | OmO goal loop (enabled; not auto-start) |

---

## Multi-agent teams — OmO team mode · hyperplan · ship-feature · debug-team

Lead: **sisyphus**. Specs in `teams/` → `~/.omo/teams/`.

Eligible members: `sisyphus`, `atlas`, `sisyphus-junior`, `hephaestus`, or `kind: category`.  
Hard-rejected as teammates: explore · librarian · oracle · metis · momus · multimodal · prometheus.

| Team | Members |
| --- | --- |
| `explorers` | deep + quick |
| `ship-feature` | hephaestus, junior, bug-hunt |
| `debug-team` | bug-hunt + ultrabrain |
| `review-panel` | arch-review, bug-hunt, refactor-safe |
| `refactor-team` | arch-review, refactor-safe |
| `docs-team` | writing × 2 |
| `content-aware-audit` | content-aware-fast + content-aware-deep |

---

## Model routing — OpenRouter Exacto Nitro · OpenAI GPT · Claude · DeepSeek · Gemini · GLM

| Lane | Models | Used for |
| --- | --- | --- |
| Orchestration | `z-ai/glm-5.2:exacto` | Sisyphus / Atlas / Prometheus / bug-hunt |
| GPT (direct) | `openai/gpt-5.6-sol` (+ terra / 5.5 fallbacks) | Hephaestus / Oracle / Momus / deep |
| Recon | `deepseek/deepseek-v4-flash:nitro` | explore / librarian / junior / quick |
| Depth | `deepseek/deepseek-v4-pro:exacto` | content-aware / hard fallback |
| Visual / writing | Gemini 3.1 Pro · 3.5 Flash Nitro | artistry / visual / writing |
| Ceiling | `anthropic/claude-fable-5` | ultrawork · unspecified-high |

OpenRouter is primary. GPT agents prefer **direct OpenAI**. Fallbacks + `runtime_fallback` on API errors. Stream timeouts: **900s** — because real work is long.

### Concurrency caps — background_task · providerConcurrency · team parallel · Ralph · Goal

Priority: `modelConcurrency` → `providerConcurrency` → `defaultConcurrency`. `oc heal` / `fix.sh` re-apply the caps if something drifts high.

| Knob | Value | Why |
| --- | --- | --- |
| `background_task.defaultConcurrency` | **4** | Global fan-out ceiling |
| OpenRouter / OpenAI / Anthropic | **6 / 4 / 2** | Provider budgets that don’t melt |
| Flash / Exacto / Sol / Fable | **4 / 3 / 3 / 1** | Cheap recon parallel; expensive models serial |
| Team `max_parallel_members` / `max_members` | **4 / 5** | Hyperplan floor without runaway |
| Ralph / Goal / stale / TTL | **8 / 24 / 180s / 30m** | Loops + hung-task cleanup |

This is what “maximum power with adult supervision” looks like.

---

## MCP servers — Context7 docs · Exa websearch · grep_app · codegraph · TypeScript Python Go LSP

| Name | Auth | Purpose |
| --- | --- | --- |
| Context7 | `CONTEXT7_API_KEY` | Library docs (`opencode.json` + OmO) |
| websearch (Exa) | `EXA_API_KEY` | Live web |
| grep_app | — | GitHub code search |
| codegraph | — | Local graph at `~/.omo/codegraph` |
| LSP | — | **TypeScript · Python · Go** only |

Formatters: Prettier + Ruff. Skills fenced to `./skills` (empty by design). Third-party MCPs stay disabled. Telemetry dark (OpenCode share/OTel · OmO PostHog · codegraph · `DO_NOT_TRACK`).

---

## API keys — OPENROUTER_API_KEY · OPENAI_API_KEY · EXA_API_KEY · CONTEXT7_API_KEY

| Key | Required | Enables |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | **yes** | OpenRouter models |
| `OPENAI_API_KEY` | **yes** for GPT lane | Hephaestus / Oracle / Momus / deep / … |
| `EXA_API_KEY` | for websearch | OmO Exa |
| `CONTEXT7_API_KEY` | recommended | Context7 |
| `OPENROUTER_MGMT_KEY` | optional | `oc admin` |
| `OC_PROJECTS_DIR` | optional | `oc new` home (default `~/Projects`) |

Copy `.env.example` → `.env` (`chmod 600`). Never commit `.env`.  
`oc setup --sync-env` imports **allowlisted keys only** from Infisical/Doppler — never a full vault dump.

---

## Profiles & scaffolding — oc new · high · research · content-aware · debug · writing

```bash
oc new myapp                     # ~/Projects/myapp · profile high
oc new myapp --profile research
oc new myapp --profile content-aware
oc projects --list
```

| Profile | Agent | Use |
| --- | --- | --- |
| `high` | sisyphus | Default — Exacto excellence |
| `low` / `fast` | sisyphus / hephaestus | Cheap / direct coding |
| `research` / `debug` | sisyphus | Deep reasoning / debug |
| `writing` | sisyphus | Documentation |
| `content-aware` | content-aware-research | Full-depth research (edit deny) |

Each project gets `opencode.json` + `AGENTS.md`. Do not set `OPENCODE_CONFIG` to `.opencode/profile.json`.

---

## Safety — trusted local allow · catastrophic bash deny · OpenRouter + OpenAI only

- Allow-everything locally for normal tools (trusted box).
- Hard-deny bash: `rm -rf /|~`, `mkfs`, `sudo`, `git push --force*`, `gh repo delete*`.
- Providers allowed: OpenRouter + OpenAI only.
- Server: `127.0.0.1:4097` · share disabled · mdns off.

---

## Terminal cockpit — Ghostty · tmux · zsh · OpenCode TUI · Ctrl+X · Ctrl+B

- **Ghostty** ≥ 1.3.0 · **tmux** ≥ 3.3 (rec. 3.7+) · zsh snippet
- OpenCode leader **Ctrl+X** · tmux prefix **Ctrl+B** · Tab cycles agents
- Teardown never sends `\033[?1049l` (won’t wipe the visible screen)
- `opencode()` / `oc launch` never start inside the config repo or bare `~/Projects`

---

## Repo layout — opencode.json · oh-my-openagent.json · prompts · teams · profiles

```
opencode-configs/
├── oc · install.sh · setup.sh · doctor.sh · validate.sh · fix.sh
├── opencode.json · oh-my-openagent.json · tui.json
├── versions.json · signature.json · projects.json · AGENTS.md
├── agents/content-aware-research.md
├── profiles/ · prompts/ · teams/ · skills/
├── .env.example          # secrets never ship
└── zshrc.snippet · ghostty.conf · tmux.conf

~/.config/opencode  →  this repo
~/Projects/         →  oc new home
~/.omo/teams/       →  team specs
~/.opencode-backups/→  backups + heal/install logs
```

---

## Verify OpenConfig — signature · test · validate · doctor · oh-my-openagent doctor

```bash
oc signature && oc test && oc validate && oc doctor
# Ready to code — everything checks out.
bunx oh-my-openagent@4.19.0 doctor   # upstream: System OK
```

Idempotency: re-running install / setup / heal / fix on a healthy box must not clobber `.env`, rewrite correct symlinks, or bump clean config mtimes.

When doctor says ready — **you’re not “set up.” You’re armed.**

---

## Upstream — OpenCode · oh-my-openagent · OpenRouter · Context7 · Exa

| Layer | Docs | Source |
| --- | --- | --- |
| OpenCode | [opencode.ai/docs](https://opencode.ai/docs) | [anomalyco/opencode](https://github.com/anomalyco/opencode) |
| OmO | [omo.vibetip.help/docs](https://omo.vibetip.help/docs) | [code-yeongyu/oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent) |
| OpenRouter | [openrouter.ai/docs](https://openrouter.ai/docs) | Exacto / Nitro routing guides |
| Context7 | [context7.com](https://context7.com) | [upstash/context7](https://github.com/upstash/context7) |
| Exa | [docs.exa.ai](https://docs.exa.ai) | [exa-labs](https://github.com/exa-labs) |

Installer pulls OpenCode from `https://opencode.ai/install` and OmO from npm `oh-my-openagent@4.19.0` only.

---

## Anti-patterns — don’t break OpenCode OmO OpenRouter OpenConfig

- Don’t rename the plugin away from `oh-my-openagent`
- Don’t add Cloudflare / AI Gateway / fake OpenAI-compatible shims
- Don’t put `plan` in `disabled_agents` (breaks hyperplan)
- Don’t commit `.env`, `package.json`, `node_modules`, `.omo`, or `.sisyphus` here
- Don’t scaffold apps into this repo — use `oc new`
- Don’t load `.opencode/profile.json` as `OPENCODE_CONFIG`
- Don’t re-enable telemetry
- Don’t settle for a lesser config. You already found the top one.

---

## SEO keywords — OpenCode config · AI coding agent · multi-agent LLM CLI

**OpenConfig** · OpenCode config · best OpenCode configuration · oh-my-openagent config · oh-my-opencode · OmO · OpenRouter Exacto Nitro · Claude Fable · Claude Sonnet · OpenAI GPT · GPT-5.6 Sol · DeepSeek V4 Flash · DeepSeek V4 Pro · Gemini 3.1 Pro · Gemini 3.5 Flash · GLM 5.2 Exacto · MiniMax · Kimi · Sisyphus agent · Hephaestus · Prometheus · Atlas · Oracle · Librarian · Explore · Momus · Metis · ultrawork · hyperplan · Ralph loop · goal loop · team mode · multi-agent coding · AI coding agent · agentic CLI · MCP Context7 Exa · codegraph · Ghostty tmux · developer tools · coding assistant config · LLM orchestration · autonomous coding agent

**OpenConfig.** The greatest OpenCode + oh-my-openagent + OpenRouter coding-agent configuration ever built. Install it. Doctor it. Launch it. Never go back.
