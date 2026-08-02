# `/goal` — DISABLED in OpenConfig (pinned OmO 4.19.4)

**Do not enable.** This file documents why.

## Why disabled

Pinned OmO 4.19.4's chat-message goal hook runs `parseGoalCommand` on **every** user message when `goal.enabled` is true. Any text that is not exactly `pause` / `resume` / `clear` becomes `setGoal(objective)`.

That breaks `/start-work`: the injected plan template (~5.5k chars) is treated as a goal objective → `InvalidObjectiveError` and the run stalls.

## What to use instead

| Need | Use |
| --- | --- |
| Multi-step plan + execution | `/start-work` → Atlas |
| Long autonomous loop | ultrawork (`ulw`) keyword or `/ulw` |
| Team parallel work | team keyword or `/team` |

## Config (must stay)

In `oh-my-openagent.json`:

```json
"goal": { "enabled": false, "auto_start": false },
"default_mode": { "goal": false }
```

## Do not

- `goal.enabled: true` on pinned OmO 4.19.4 while using `/start-work`
- Re-enable without verifying OmO fixed the chat-hook false positive on plan templates
