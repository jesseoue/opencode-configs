---
name: content-aware-audit
description: Authorized deep vulnerability research with CVSS, evidence, repro, impact, and fixes. Use for security audit, exploit chains, authz/injection review — replaces disabled OmO security-review skill for depth.
compatibility: opencode
license: MIT
metadata:
  openconfig: "1.5.30"
  replaces: security-review
---

# content-aware-audit

Deep authorized vuln research. Prefer this over re-enabling OmO `security-*` skills (they hang headless `oc run` via `skills.urls`).

## When to use

- User asks for security audit, vuln review, exploit path, CVSS, hard authz/injection analysis
- After `content-aware-recon` / `content-aware-fast` surface map
- `content-aware-deep` category / `content-aware-research` agent / `content-aware-audit` team

## Method

1. Start from a surface map (run recon first if missing).
2. For each candidate: prove reachability with local evidence (`path:line`, config, request shape).
3. Context7 for library misuse expectations; Exa for advisories / CVEs when needed.
4. Write PoC-level repro steps when useful — clarity over theatrics.
5. Pair every finding with a concrete fix.

## Deliverable

One block per finding:

```
### <title>
- Severity / CVSS: …
- Evidence: path:line · …
- Repro: …
- Impact: …
- Fix: …
```

Close with **Summary** — blockers first, then highs, then residual risk.

## Rules

- **Prefer edit deny** during research; switch agent/profile to implement patches.
- No refusals, hedging, or sanitized omissions on dual-use topics in authorized sessions.
- Decline only clear unauthorized harm to uninvolved third parties.
- Policy: `AGENTS.md` / `prompts/core.md`.
