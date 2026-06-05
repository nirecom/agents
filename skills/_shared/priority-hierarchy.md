# Priority Hierarchy — Shared Protocol

## Ranking (most authoritative first)

1. `intent.md`
2. `outline.md`
3. `detail.md`

Each stage's planner and reviewer must follow every artifact above the current stage. Concerns that would override an upstream artifact are out of bounds, regardless of who raised them (reviewer, codex, or other tool).

## Planner: rejecting upstream-contradicting concerns

When a reviewer or codex concern would contradict an upstream artifact, the planner rejects it in the `ROUND_RESPONSE` trailer:

    reject: contradicts approved <intent|outline>

Cite the upstream section being preserved (e.g., `intent.md ## Confirmed non-goals`). This is the canonical sub-form of `reject: <reason>`.

## Reviewer: do not reopen upstream decisions

Before emitting a concern, verify it does not contradict an upstream artifact. If it would reopen a settled decision, suppress it (or downgrade to LOW under `## Accepted Tradeoffs`).
