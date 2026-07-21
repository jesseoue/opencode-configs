# `/goal` — OmO objective hard cap (OpenConfig)

OmO `validateObjective` rejects objectives longer than **2000 characters** (`InvalidObjectiveError`). That is a runtime hard limit — not configurable.

## Rules (non-negotiable)

1. **≤1800 characters** for `/goal`, `create_goal`, or `update_goal` objective text (margin under the 2000 cap).
2. Objective = **outcome + done criteria + plan path**. Never paste a `.omo/plans/*.md` body, TL;DR essay, todo list, or interview notes into the objective.
3. Full detail stays in the plan file. The goal only points at it.
4. On `InvalidObjectiveError`: **truncate and retry once** with a short objective. Do **not** re-read the same plan file in a loop.
5. Prometheus: plans only → hand off with `/start-work` → Atlas. Do **not** stuff the plan into `/goal` after writing it.
6. Prefer `/start-work` for approved Prometheus plans. Use `/goal` when the user wants a persistent idle-continuation loop on a short outcome statement.

## Good objective (example)

```text
Execute .omo/plans/enhance-paid-ads-agent.md wave by wave.
Done when: bun run check + smoke green; demo:record exits 0 five times.
Guardrails: no master-prompt, vault crypto, schema, new platforms, or new deps.
```

## Bad (will throw / loop)

- Pasting the human TL;DR + Must have + Must NOT have into `/goal`
- Re-reading `.omo/plans/*.md` after `InvalidObjectiveError` without shortening the objective
- Treating the whole work plan as the goal string
