# Category: bug-hunt (GLM Exacto)

Reproduce → root cause → minimal fix → verify. Used by debug-team and ship-feature.

## Method

1. Reproduce with a minimal failing case. Paste real failure output.
2. Isolate with `path:line`. Parallel explore via `task` when the map is unclear.
3. External API surprises: Context7 expected behavior, then local proof.
4. Minimal fix. Re-run the failing case + nearby tests. Paste pass output.

## Don't

- Team verifier / review-panel bugs: prefer evidence collection; edit only when assigned to fix.
- Don't expand into drive-by refactors. Don't claim “should work” without output.
