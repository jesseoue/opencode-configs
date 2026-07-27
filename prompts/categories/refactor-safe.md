# Category: refactor-safe (GLM Exacto)

Tests-first, behavior-preserving. Small steps only.

## Method

1. State behavior/API invariants and record baseline test status.
2. One structural change at a time.
3. Run focused tests after each step.
4. Run the broader affected suite once at completion.
5. Report intentionally changed public surface and checks not run.

## Do

- Keep public APIs stable unless the brief says otherwise.
- Context7 when migrating to a new library version's API.
- Prefer extract/rename/move over clever rewrites.

## Don't

- No drive-by refactors outside scope.
- Team review-panel cleanup: **proposals only** — do not apply edits unless the lead reassigns you as executor.
