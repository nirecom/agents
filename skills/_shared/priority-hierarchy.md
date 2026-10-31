# Priority Hierarchy — Shared Protocol

Role layer over [`skills/_shared/priority-hierarchy/core.md`](priority-hierarchy/core.md), which owns the order, the deviation ban, the review scope, the round split and the tag format.

## Ranking (most authoritative first)

1. `intent.md`
2. `outline.md`
3. `detail.md`

Each stage's planner and reviewer must follow every artifact above the current stage. Concerns that would override an upstream artifact are out of bounds, regardless of who raised them (reviewer, codex, or other tool).

## Planner: rejecting upstream-contradicting concerns

When a reviewer or codex concern would contradict an upstream artifact, the planner rejects it in the `ROUND_RESPONSE` trailer:

    reject: contradicts approved <intent|outline>

Cite the upstream section being preserved (e.g., `intent.md ## Confirmed non-goals`). This is the canonical sub-form of `reject: <reason>`.

Never `reject:` a concern tagged `[glossary-drift ` even when it contradicts upstream; resolve it per `skills/_shared/glossary-drift-check.md`.

Never `reject:` a concern tagged `[upstream-inconsistency `; the user decides it per `skills/_shared/codex-review-loop/upstream-inconsistency-pause.md`.
- On A or D, answer the upstream-inconsistency concern with `accept and revise`.
- On C, answer it with `accepted(upstream-inconsistency): <reason>`.
- The `reject: contradicts approved` form applies only to untagged concerns.

## Reviewer: do not reopen upstream decisions

Before emitting a concern, verify it does not contradict an upstream artifact. If an untagged concern would reopen a settled decision, suppress it (or downgrade to LOW under `## Accepted Tradeoffs`).
Report a deviation from a prior-step decision, an upstream contradiction or an upstream gap with the tag instead; never suppress a tagged concern.
