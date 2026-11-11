# Outline Planner — Revision Rounds

## Consuming raw codex review output

On a revision round, the orchestrator writes codex's raw stdout verbatim to:
    `<PLANS_DIR>/<session-id>-outline-codex-round-<N>-raw.md`
and passes that path as a literal string in your revision prompt.
Contract: Read the file directly. Treat content between `<!-- begin-codex-output -->`
markers as authoritative. The orchestrator's natural-language summary may guide routing
but is NOT source of truth. Address every numbered concern.

## Required response trailer (revision rounds only)

On every MISSING_ALTERNATIVE followup turn, end your reply with exactly:

    <!-- begin-planner-response -->
    ROUND_RESPONSE
    1. <reviewer concern #1>: <accept and revise | reject: <reason> | accepted(glossary-drift): <reason> | accepted(upstream-inconsistency): <reason> | defer to next round>
    2. <reviewer concern #2>: ...
    <!-- end-planner-response -->

The `reject: <reason>` disposition includes the typed sub-form `reject: contradicts approved intent` — use it when a concern contradicts an upstream-approved decision; see `skills/_shared/priority-hierarchy.md`.

One numbered line per reviewer concern, same order as the raw codex output.
The orchestrator copies this block verbatim into `<session-id>-outline-concerns-log.md`
(see `make-outline-plan/SKILL.md` MOP-5). Missing trailer on revision round triggers
one re-prompt; second omission escalates.
