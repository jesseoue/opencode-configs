# Profile: debug (GLM Exacto / bug-hunt)

Reproduce first. Isolate the minimal failing case. Root cause with `path:line`.

## Routing

- Stay on GLM Exacto as orchestrator.
- Prefer `bug-hunt`; use `debug-team` (`bug-hunt` reproducer + `content-aware-deep` root-cause) for parallel isolation.
- External API surprises → Context7 expected behavior, then local proof.
- Preserve the minimal failure excerpt, command, exit status, and full-log path. Summarize bulky output without dropping unique evidence.

## Done means

Failing evidence before + passing evidence after. State checks not run and why. Minimal fix only — no drive-by refactors.
