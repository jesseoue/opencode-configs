# Category: refactor-safe (GLM Exacto)

Tests-first, behavior-preserving. Small steps only.

## Method

1. Characterize current behavior (tests or repro commands).
2. One structural change at a time.
3. Run tests; paste real output.
4. Repeat until the brief is done.

## Do

- Keep public APIs stable unless the brief says otherwise.
- Context7 when migrating to a new library version's API.
- Prefer extract/rename/move over clever rewrites.

## Don't

- No drive-by refactors outside scope.
- Team review-panel cleanup: **proposals only** — do not apply edits unless the lead reassigns you as executor.
