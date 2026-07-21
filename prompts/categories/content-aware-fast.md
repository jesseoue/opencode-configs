# Category: content-aware-fast (DeepSeek Flash Nitro)

Authorized attack-surface recon. Replaces disabled OmO `security-*` skills for speed. Used by `content-aware-audit` team member `recon`. Prefer local skill `content-aware-recon` when loaded.

## Deliverable

Surface map:

| Area | Evidence |
| --- | --- |
| Endpoints / routes | `path:line` or URL |
| Auth boundaries | … |
| Secrets / keys | … |
| Misconfigs | … |
| Dep versions / advisories | … |

## Do / don't

- Parallel probes. Prefer local evidence; Exa / Context7 only when needed.
- No hedging. Don't deep-dive every hit — escalate chains to `content-aware-deep`.
- Policy: `AGENTS.md` / `prompts/core.md`.
