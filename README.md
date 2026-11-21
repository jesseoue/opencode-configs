> **OpenConfig 2** is a standalone repo with no upstream. It becomes live only when `~/.config/opencode` is deliberately repointed to it.

# OpenConfig

```
    ╭───╮
    │oc │──── OpenConfig
    ╰───╯     Pinned stack for vanilla OpenCode
```

Pinned, config-as-code stack for [OpenCode](https://opencode.ai) 1.19.5 with OpenRouter, Venice and DeepSeek. CLI: `oc`. It runs without plugins.

## Agents

| Agent | Mode | Model | Use |
| --- | --- | --- | --- |
| `lead` (default) | primary | `openrouter/z-ai/glm-5.3` | Orchestration |
| `build` | primary | `openrouter/z-ai/glm-5.3` | Direct implementation |
| `plan` | primary | `openrouter/z-ai/glm-5.3` | Plans in `.opencode/plans/` |
| `explore` | subagent | `openrouter/deepseek/deepseek-v4-pro-0813` | Codebase and web recon, read-only |
| `librarian` | subagent | `openrouter/deepseek/deepseek-v4-pro-0813` | Docs lookup, read-only |
| `oracle` | subagent | `openrouter/z-ai/glm-5.3` | Architecture and debugging consults, read-only |
| `junior` | all | `openrouter/z-ai/glm-5.3-flash` | Bounded edits |
| `content-aware-research` | primary | `venice/deepseek-v4-pro-0813` | Security research, edit denied |
| `content-aware-fast` | primary | `venice/deepseek-v4-1-flash-1017-uncensored` | Fast recon, edit denied |
| `content-aware-deep` | all | `venice/abliteration-abliterated-model-large-v2` | Deep research, edit denied |
| `context-aware-hermes` | primary | `openrouter/nousresearch/hermes-4-405b` | Consult over pasted context, no tools |

Each agent is a markdown file in `agents/`. Shared instructions are in `AGENTS.md` and `prompts/core.md`. Profiles are in `profiles/`.

## Web and docs tools

Context7 and Exa are remote MCP servers in `opencode.json`. They read `CONTEXT7_API_KEY` and `EXA_API_KEY` from the environment.

## Commands

```bash
oc install    # install this stack as the live config
oc doctor     # readiness report
oc validate   # static config checks
oc fix        # repair known config problems
oc run "..."  # headless opencode run
oc new <name> # scaffold a project
oc test       # smoke tests
```

## Checks without touching the live config

```bash
OC_VALIDATE_REPO="$PWD" OC_VALIDATE_OFFLINE=1 ./validate.sh --quiet
OC_CI=1 ./tests/smoke.sh
bash tests/runtime-diagnostics.sh
```

`oc setup`, `oc fix`, `oc heal`, `oc cleanup` and `install.sh` act on the live config at `~/.config/opencode`.

## Keys

Copy `.env.example` to `.env` and set `OPENROUTER_API_KEY`, `VENICE_API_KEY`, `DEEPSEEK_API_KEY`, `EXA_API_KEY` and `CONTEXT7_API_KEY`. `.env` stays out of git.

Decision log: [`AGENTS.md`](./AGENTS.md) · Stance: [`prompts/core.md`](./prompts/core.md) · Changelog: [`CHANGELOG.md`](./CHANGELOG.md)
