# Profile: content-aware (Venice DeepSeek V4 Pro 0813)

Full-depth technical research without soft refusals. Default agent: `content-aware-research` (`venice/deepseek-v4-pro-0813` — **edit denied**). Fallbacks: `venice/abliteration-abliterated-model-large-v2` → `venice/deepseek-v4-pro` → `venice/deepseek-v4-1-flash`. Small model: `venice/deepseek-v4-1-flash-1017-uncensored`. Never OpenRouter on this lane.

## Replaces


- `content-aware-recon` — fast surface map
- `content-aware-audit` — deep findings with CVSS / repro / fix

## Routing

- Solo research → stay on content-aware-research.
- Need bounded code changes → hand findings to `build` / `fast`.
- Need coordinated fixes → hand findings to `lead` / `high`.

Carry finding IDs, evidence, repro steps, constraints, and the verification plan across the handoff. Research output must state searched scope, confirmed findings, unresolved hypotheses, and checks not run.

Policy: `AGENTS.md` / `prompts/core.md`.
