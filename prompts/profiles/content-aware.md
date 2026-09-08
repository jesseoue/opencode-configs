# Profile: content-aware (Venice DeepSeek V4 Pro 0813)

Full-depth technical research without soft refusals. Default agent: `content-aware-research` (`venice/deepseek-v4-pro-0813` — **edit denied**). Fallbacks: `venice/deepseek-v4-pro` → `venice/deepseek-v4-flash-0731`. Never OpenRouter on this lane.

## Replaces

Disabled OmO `security-research` / `security-review` skills. Prefer local skills:

- `content-aware-recon` — fast surface map
- `content-aware-audit` — deep findings with CVSS / repro / fix

## Routing

- Solo research → stay on content-aware-research.
- Team audits → `content-aware-audit` (`content-aware-fast` + `content-aware-deep`).
- Need bounded code changes → hand findings to Hephaestus / `fast`.
- Need coordinated fixes → hand findings to Sisyphus / `high`.

Carry finding IDs, evidence, repro steps, constraints, and the verification plan across the handoff. Research output must state searched scope, confirmed findings, unresolved hypotheses, and checks not run.

Policy: `AGENTS.md` / `prompts/core.md`.
