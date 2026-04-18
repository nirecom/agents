---
name: make-plan
description: Produce an implementation plan via a planner/reviewer discussion loop, then get user approval.
model: opus
---

Produce an implementation plan via a planner/reviewer discussion loop.

## Procedure

1. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: planner`). Pass the full task context.
2. Pass the planner's draft to the **reviewer** subagent (`subagent_type: reviewer`).
3. If the reviewer returns `NEEDS_REVISION`, send the concerns back to the planner for revision, then re-review. Repeat.
4. **Escalate to the user** if the loop reaches **2 revision rounds** without approval, or a research/malformed-retry cap is hit (see Research Escalation). When escalating, message in this order:
   1. **Loop status** — which counter/cap was hit and how many rounds occurred.
   2. **The planner's current plan** — paste or closely summarize. The user cannot see subagent output, so this is their only way to understand what has been designed.
   3. **Blocking issues** — unresolved reviewer concerns or the pending research question.
5. Once the reviewer returns `APPROVED`, enter plan mode and present the final plan to the user for approval.

## Research Escalation

When the planner's reply starts with `NEEDS_RESEARCH` (first non-whitespace token), the orchestrator short-circuits before the reviewer and runs `/deep-research`. Format spec is in `planner.md`.

**Malformed** (missing/empty field, `skill:` ≠ `deep-research`): re-prompt once with a one-line diagnostic. Second malformed reply → escalate. Malformed retries do **not** consume `research_rounds`.

**Round counters** (per invocation, never reset):

| Counter | Cap |
|---|---|
| `revision_rounds` | 2 |
| `research_rounds` | 2 |
| `malformed_retries` | 1 |

`NEEDS_RESEARCH` does not consume `revision_rounds`. Allowed at any planner turn.

**Re-prompt template:**
```
Research complete.
Findings: <verbatim research output>

Original task: <original task prompt>
pending reviewer concerns (if any — empty on initial-draft turn): <forward verbatim or "(none)">

Incorporate findings under "## Research Findings (from this session)" and cite with [research: tag].
Now produce the full plan.
```

Subagent prompts may contain verbatim research (the "summarize to user" rule applies only to user-facing chat). Double-emit of `<<WORKFLOW_MARK_STEP_research_complete>>` is harmless (`markStep` is idempotent).

**On cap:** tell the user which budget was exhausted, how many times research ran, and the pending question. Ask: "Approve further research, provide the answer directly, or adjust scope?" Do not emit `WORKFLOW_MARK_STEP_plan_complete` on any escalation.

## Skip Conditions

Skip the entire discussion loop when **both** of the following are true:
- The task is a single-file change
- No design decision is needed

In that case, draft the plan directly in the main conversation and present it for approval.

## Skipping the Plan Step Entirely

The Skip Conditions above skip the planner/reviewer discussion loop but still
produce a plan. To skip the plan step itself (no plan at all), run:

`echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`

Use this only when the task is trivial enough that no written plan — not even
an informal one — is needed (e.g., a typo fix, a one-line config tweak).
Reason must be ≥3 non-space chars, not a placeholder, and contain no '>'.

Skipping research does NOT justify skipping the plan step.

## Rules

- Read before planning — do not plan from assumptions
- Orchestrator (main Claude) only summarizes each discussion round to the user — do not dump full transcripts into the conversation
- Follow `rules/orthogonality.md` for cross-platform and naming consistency

## Completion

After completing this skill, run:
`echo "<<WORKFLOW_MARK_STEP_plan_complete>>"`
(This echo must be the ENTIRE Bash command — no pipes, no && chaining, no redirection.)
