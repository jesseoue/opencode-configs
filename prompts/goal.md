# `/goal` — DISABLED in OpenConfig (OmO 4.19.0 footgun)

**Status:** `goal.enabled: false` in `oh-my-openagent.json`. Do **not** re-enable until OmO fixes the collision below.

## Why disabled

OmO 4.19.0's chat-message goal hook runs `parseGoalCommand` on **every** user message when `goal.enabled` is true. Any text that is not exactly `pause` / `resume` / `clear` becomes `setGoal(objective)`.

That collides with `/start-work`:

1. `/start-work` injects `START_WORK_TEMPLATE` (~5541 characters) as a user message.
2. The goal hook treats that entire template as the objective.
3. `validateObjective` hard-caps at **2000 characters** → `InvalidObjectiveError`.
4. Prompt/command fails; Atlas handoff dies; sessions look like they "flash and exit" or loop.

Prometheus → Atlas handoff (`/start-work`) is more important than the idle `/goal` loop, so OpenConfig keeps goal off.

## What to use instead

| Need | Do this |
| --- | --- |
| Execute an approved plan | `/start-work` → Atlas (plan file stays in `.omo/plans/*.md`) |
| Long multi-iteration work | Ralph loop (capped) · team mode · todos — not `/goal` |
| Resume work | Continue the session, or `/start-work <plan-name>` |

## If OmO fixes this and you re-enable

1. Set `goal.enabled: true` only after verifying `/start-work` no longer calls `setGoal` with the template.
2. Keep objectives **≤1800 characters** (margin under the 2000 hard cap).
3. Objective = outcome + done criteria + plan path — never paste `.omo/plans/*.md`.
4. On `InvalidObjectiveError`: truncate once; do not re-read-loop the plan file.
5. Keep `default_mode.goal: false` and `auto_start: false`.

## Bad (will throw / break `/start-work`)

- `goal.enabled: true` on OmO 4.19.0 while using `/start-work`
- Pasting a plan TL;DR / Must-have block into `/goal`
- Re-reading `.omo/plans/*.md` after `InvalidObjectiveError` without shortening
