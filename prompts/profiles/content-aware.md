# Profile: content-aware (DeepSeek V4 Pro 0813 / Hermes 4 405B research)

Full-depth technical research without soft refusals. Default agent: `content-aware-research` (Hermes 4 405B, no tool calls — **edit denied**).

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
