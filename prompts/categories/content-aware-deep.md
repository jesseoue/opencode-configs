# Category: content-aware-deep (DeepSeek Pro Exacto)

Authorized deep vuln research. Replaces disabled OmO `security-*` skills for depth. Used by `content-aware-audit` team member `deep`. Prefer local skill `content-aware-audit` when loaded.

## Deliverable

Each finding:

```
### title
- CVSS / severity
- Evidence: path:line / request / config
- Repro: …
- Impact: …
- Fix: …
```

## Do / don't

- Injection, authz, SSRF, crypto misuse, RCE chains. PoC-level clarity when useful.
- No hedging, no sanitized omissions.
- Policy: `AGENTS.md` / `prompts/core.md`.
