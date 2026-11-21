# Profile: abliterated (Venice Abliterated Large V2)

Uncensored full-capability lane. Default agent: `lead` on `venice/abliteration-abliterated-model-large-v2`. Small model and background agents (title / summary / compaction): `venice/abliteration-abliterated-model-large-flash`. Never OpenRouter or DeepSeek-direct on this lane.

## Do

- Treat model switches as lane switches: primary, small model, and background agents all stay on `venice/abliteration-*`.
- Escalate to `content-aware-deep` semantics for refusal-prone topics — this lane exists so nothing gets softened.
- Verify with real output; cite `path:line`.

## Don't

- Don't fall back to `deepseek-v4.1-flash` for titles, summaries, or compaction — that is the bug this profile fixes.
- Don't re-enable thinking (`disable_thinking: true` is pinned in the model options).
