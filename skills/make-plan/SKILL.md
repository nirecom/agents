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
4. **Escalate to the user** if the loop reaches **2 revision rounds** without approval, or a research/malformed-retry cap is hit (see Research Escalation below). When escalating:
   1. **First give the full picture** — what the task is, what overall approach the planner has settled on so far, and where in the loop we are (which counter/cap was hit).
   2. **Then describe the specific blocking issue** — the unresolved concern or the pending research question.
5. Once the reviewer returns `APPROVED`, enter plan mode and present the final plan to the user for approval.

## Research Escalation

If the planner lacks external knowledge needed to produce a correct plan, it emits `NEEDS_RESEARCH` instead of a plan. The orchestrator detects this before invoking the reviewer, runs `deep-research`, and re-prompts the planner with verbatim findings.

### Protocol

The planner's entire reply must be:

```
NEEDS_RESEARCH
skill: deep-research
question: <one-line question>
reason: <one-line, non-empty — why this blocks planning>
```

**Detection:** If the first non-whitespace token of the planner's reply is `NEEDS_RESEARCH`, treat it as an escalation request. Occurrences inside prose or code blocks do not trigger this.

**Malformed:** `skill:` is not `deep-research`, or `question:` is empty, or `reason:` is empty/whitespace-only → malformed. Re-prompt the planner once with a one-line diagnostic naming the exact problem. A second malformed reply escalates to the user. Malformed retries do **not** consume `research_rounds`.

**v1:** Only `skill: deep-research` is supported.

### Round counters (per invocation, never reset)

| Counter | Cap | On cap |
|---|---|---|
| `revision_rounds` (reviewer `NEEDS_REVISION`) | 2 | Escalate to user |
| `research_rounds` (`NEEDS_RESEARCH` successfully executed) | 2 | Escalate to user |
| `malformed_retries` (malformed re-prompts) | 1 | Escalate to user |

- `NEEDS_RESEARCH` does **not** consume `revision_rounds`.
- `NEEDS_RESEARCH` is allowed at any planner turn — initial draft or any revision round.
- Malformed retries do **not** consume `research_rounds`.

### Re-prompt template

```
Research complete.
Findings:
<verbatim research output>

Original task: <original task prompt>
pending reviewer concerns (if any — empty on initial-draft turn): <forward verbatim or "(none)">

Incorporate findings under "## Research Findings (from this session)"
and cite with [research: <tag>] (tag format: [a-z0-9-]+).
Now produce the full plan.
```

**Verbatim rule:** The "orchestrator summarizes to user" rule applies only to user-facing chat. Subagent prompts may contain full verbatim research output.

**Workflow marker:** `deep-research` may emit `<<WORKFLOW_MARK_STEP_research_complete>>` again mid-plan. This is harmless — `markStep` is a pure overwrite (idempotent). Do not modify `deep-research/SKILL.md` to suppress it.

### Escalation messages

**Research budget exhausted — include:**
- Task summary and the plan's current overall approach
- Which budget was exhausted and how many times research was already run
- The specific pending question: [question]
- Ask: "Approve further research, provide the answer directly, or adjust scope?"

**`WORKFLOW_MARK_STEP_plan_complete`** is emitted only on approval. Do not emit it when escalating to the user for any reason.

## Skip Conditions

Skip the entire discussion loop when **both** of the following are true:
- The task is a single-file change
- No design decision is needed

In that case, draft the plan directly in the main conversation and present it for approval.

## Rules

- Read before planning — do not plan from assumptions
- Orchestrator (main Claude) only summarizes each discussion round to the user — do not dump full transcripts into the conversation
- Follow `rules/orthogonality.md` for cross-platform and naming consistency

## Completion

After completing this skill, run:
`echo "<<WORKFLOW_MARK_STEP_plan_complete>>"`
(This echo must be the ENTIRE Bash command — no pipes, no && chaining, no redirection.)
