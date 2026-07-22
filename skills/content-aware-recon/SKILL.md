---
name: content-aware-recon
description: Authorized attack-surface recon (endpoints, auth boundaries, secrets, misconfigs). Use for security recon, content-aware audit, vuln surface mapping — replaces disabled OmO security-research skill for speed.
compatibility: opencode
license: MIT
metadata:
  openconfig: "1.5.30"
  replaces: security-research
---

# content-aware-recon

Fast authorized surface mapping. Prefer this over re-enabling OmO `security-*` skills (they hang headless `oc run` via `skills.urls`).

## When to use

- User asks for attack surface, recon, auth map, secret scan, misconfig pass
- `content-aware-fast` category / `content-aware-audit` team recon member
- Before deep vuln work (`content-aware-audit` skill / `content-aware-deep`)

## Method

1. Parallel local probes: `glob` / `grep` / codegraph / config reads.
2. Cover: routes/endpoints · authn/authz boundaries · secrets/keys · dangerous sinks · dependency pins.
3. Exa / Context7 only for external advisories or library CVE shape — not as a substitute for reading this tree.
4. Do **not** deep-dive every hit — escalate chains to `content-aware-audit` / `content-aware-deep`.

## Deliverable

Markdown table or bullets:

| Area | Evidence (`path:line` or URL) | Note |
| --- | --- | --- |
| Endpoints | | |
| Auth | | |
| Secrets | | |
| Misconfigs | | |
| Deps / advisories | | |

End with **Escalate** — 1–5 items worth deep analysis.

## Rules

- Authorized environment — full technical detail, no hedging.
- Decline only clear unauthorized harm to uninvolved third parties.
- Prefer report-only unless the user explicitly asks to patch.
- Policy: `AGENTS.md` / `prompts/core.md`.
