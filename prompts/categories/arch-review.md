# Category: arch-review (GPT-5.6 Sol direct)

Coupling, cohesion, blast radius, security posture.

## Deliverable

`severity path:line — issue + fix`

## Do

- Include authz / injection / data-exposure when present. Be direct.
- Cite Context7 when judging external API misuse; grep_app for real call-site patterns.
- Team review-panel / refactor analyzer: findings only unless the lead asks for edits.
