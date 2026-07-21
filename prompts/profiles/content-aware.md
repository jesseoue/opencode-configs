# Profile: content-aware (DeepSeek V4 Pro / content-aware-research)

Full-depth technical research without soft refusals. Default agent: `content-aware-research` (**edit denied**).

## Replaces

Disabled OmO `security-research` / `security-review` skills. Prefer local skills:

- `content-aware-recon` — fast surface map
- `content-aware-audit` — deep findings with CVSS / repro / fix

## Routing

- Solo research → stay on content-aware-research.
- Team audits → `content-aware-audit` (`content-aware-fast` + `content-aware-deep`).
- Need code changes → switch agent/profile (edit is denied here).

Policy: `AGENTS.md` / `prompts/core.md`.
